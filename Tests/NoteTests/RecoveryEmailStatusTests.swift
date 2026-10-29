// Copyright (c) 2026 Pingolin LLC
//
// This file is part of Pingolin Note.
//
// Pingolin Note is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// Pingolin Note is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Pingolin Note. If not, see <https://www.gnu.org/licenses/>.

import XCTest
@testable import Note

/// The recovery-address entry points added to Settings and the sign-in screen.
///
/// WHAT IS ACTUALLY AT RISK HERE
///   The UI is two link-outs and a label, so the failure modes are not visual —
///   they are (a) decoding the wrong key, which makes the row report "Checking…"
///   forever no matter what the account really has, (b) collapsing the
///   "haven't asked yet" state into "you don't have one", which tells a user
///   with a working recovery address that they have none, and (c) a portal URL
///   that points at the wrong environment, which sends a production user to a
///   dev host to type their password into. All three are silent. Hence tests
///   for a screen with almost no logic in it.
final class RecoveryEmailStatusTests: XCTestCase {

    // MARK: - State resolution

    func testNilVerifiedFlagIsUnknownNotMissing() {
        // The `User` built from the SRP step2 response at login, and the one
        // rebuilt from the keychain on an offline launch, carry neither field.
        // Reporting "Not set up" there would tell someone who HAS a recovery
        // address that they do not — and the fix they would reach for is to
        // replace a working one while locked out of the inbox that verifies it.
        XCTAssertEqual(RecoveryEmailStatus.resolve(address: nil, verified: nil), .unknown)
        XCTAssertEqual(
            RecoveryEmailStatus.resolve(address: "backup@example.com", verified: nil),
            .unknown)
    }

    func testServerSaidNoRecoveryAddress() {
        // The real wire shape for an account with none: auth
        // omits `recovery_email` and sends
        // `recovery_email_verified: false`.
        XCTAssertEqual(RecoveryEmailStatus.resolve(address: nil, verified: false), .notSet)
    }

    func testEmptyAddressCountsAsNotSet() {
        XCTAssertEqual(RecoveryEmailStatus.resolve(address: "", verified: false), .notSet)
        XCTAssertEqual(RecoveryEmailStatus.resolve(address: "   ", verified: false), .notSet)
    }

    func testUnverifiedAddressIsPending() {
        XCTAssertEqual(
            RecoveryEmailStatus.resolve(address: "backup@example.com", verified: false),
            .pendingVerification(address: "backup@example.com"))
    }

    func testVerifiedAddress() {
        XCTAssertEqual(
            RecoveryEmailStatus.resolve(address: "backup@example.com", verified: true),
            .verified(address: "backup@example.com"))
    }

    /// The two states the user has to do something about are exactly the two
    /// that cannot receive a reset link. An unverified address is not a
    /// half-working one: the auth server only looks an account up by a
    /// verified recovery address, so it matches nothing at all.
    func testOnlyActionableStatesAreFlagged() {
        XCTAssertTrue(RecoveryEmailStatus.notSet.needsAttention)
        XCTAssertTrue(RecoveryEmailStatus.pendingVerification(address: "a@b.c").needsAttention)
        XCTAssertFalse(RecoveryEmailStatus.verified(address: "a@b.c").needsAttention)
        // Unknown is NOT flagged: an orange warning for a state that only means
        // "the app hasn't looked yet" is an alarm that fires on every cold
        // launch, and an alarm that always fires gets ignored when it matters.
        XCTAssertFalse(RecoveryEmailStatus.unknown.needsAttention)
    }

    func testDetailNamesTheAddressWhenThereIsOne() {
        XCTAssertTrue(
            RecoveryEmailStatus.verified(address: "backup@example.com")
                .detail.contains("backup@example.com"))
        XCTAssertTrue(
            RecoveryEmailStatus.pendingVerification(address: "backup@example.com")
                .detail.contains("backup@example.com"))
    }

    /// The one promise that must not drift: recovery gets the ACCOUNT back,
    /// not the notes. The server holds no key that could decrypt them, so copy
    /// implying otherwise would have someone reset their password expecting
    /// their notes to come back with it.
    func testScopeCopyDoesNotPromiseDataRecovery() {
        XCTAssertTrue(RecoveryCopy.scope.contains("recovery key"),
                      "Must point at the recovery key as what unlocks data")
        XCTAssertTrue(RecoveryCopy.scope.lowercased().contains("does not unlock"),
                      "Must say plainly that a recovery address does not unlock data")
    }

    // MARK: - Decoding the /auth/me fields

    private func decodeMe(_ json: String) throws -> MeResponse {
        let decoder = JSONDecoder()
        // The key strategy is the one that matters and matches APIService's
        // exactly — it is what maps `recovery_email_verified`.
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(MeResponse.self, from: Data(json.utf8))
    }

    private func meJSON(extra: String) -> String {
        """
        {"id":"11111111-1111-1111-1111-111111111111",
         "email":"user@example.com",
         "display_name":"User"
         \(extra)}
        """
    }

    /// Pins the snake_case → camelCase mapping. Get either key name wrong and
    /// the decode still succeeds (both fields are optional) — the row just
    /// reports `.unknown` forever, on every account, which looks like a
    /// backend that never populates the field rather than a client typo.
    func testRecoveryFieldsDecodeFromMeResponse() throws {
        let me = try decodeMe(meJSON(
            extra: #", "recovery_email":"backup@example.com", "recovery_email_verified":true"#))
        XCTAssertEqual(me.recoveryEmail, "backup@example.com")
        XCTAssertEqual(me.recoveryEmailVerified, true)
        XCTAssertEqual(
            RecoveryEmailStatus.resolve(address: me.recoveryEmail,
                                        verified: me.recoveryEmailVerified),
            .verified(address: "backup@example.com"))
    }

    func testAccountWithNoRecoveryAddressDecodesToNotSet() throws {
        // auth omits `recovery_email` entirely in this case.
        let me = try decodeMe(meJSON(extra: #", "recovery_email_verified":false"#))
        XCTAssertNil(me.recoveryEmail)
        XCTAssertEqual(me.recoveryEmailVerified, false)
        XCTAssertEqual(
            RecoveryEmailStatus.resolve(address: me.recoveryEmail,
                                        verified: me.recoveryEmailVerified),
            .notSet)
    }

    /// A response without the recovery fields must not break the decode —
    /// `MeResponse` is what `checkExistingSession` hangs the whole
    /// authenticated launch off, so a throw here is a failed session
    /// restore, not one missing row.
    func testMeStillDecodesWithoutTheRecoveryFields() throws {
        let me = try decodeMe(meJSON(extra: ""))
        XCTAssertNil(me.recoveryEmail)
        XCTAssertNil(me.recoveryEmailVerified)
        XCTAssertEqual(
            RecoveryEmailStatus.resolve(address: me.recoveryEmail,
                                        verified: me.recoveryEmailVerified),
            .unknown)
    }

    /// Call sites that build a `User` without the two recovery
    /// fields must still compile and must still mean "unknown".
    func testUserDefaultsToUnknown() {
        let user = User(id: "u1", email: "user@example.com", displayName: "User")
        XCTAssertEqual(
            RecoveryEmailStatus.resolve(address: user.recoveryEmail,
                                        verified: user.recoveryEmailVerified),
            .unknown)
    }

    // MARK: - Portal URLs

    /// Both deep links must follow the build's environment. A hardcoded dev
    /// host in a production build would walk a user to a host that is not ours
    /// to type an account password into.
    func testPortalURLsFollowTheEnvironment() {
        let original = AppConfiguration.shared.environment
        defer { AppConfiguration.shared.environment = original }

        for env in AppEnvironment.allCases {
            AppConfiguration.shared.environment = env
            XCTAssertEqual(
                AppConfiguration.shared.forgotPasswordURL?.absoluteString,
                env.accountBaseURL + "/forgot-password",
                "forgot-password URL for \(env.rawValue)")
            XCTAssertEqual(
                AppConfiguration.shared.recoverySettingsURL?.absoluteString,
                env.accountBaseURL + "/settings",
                "recovery settings URL for \(env.rawValue)")
        }
    }

    /// One account means one portal: these values must not drift from
    /// the Track iOS app's `AppEnvironment.accountBaseURL` or from either
    /// Android app's `BuildConfig.ACCOUNT_BASE_URL`.
    func testPortalHostsMatchTheOtherClients() {
        XCTAssertEqual(AppEnvironment.development.accountBaseURL,
                       "https://account.pingolindev.com")
        XCTAssertEqual(AppEnvironment.production.accountBaseURL,
                       "https://account.pingolin.com")
    }

    /// The account portal is a DIFFERENT host from note-web. Deriving the
    /// recovery links from `webBaseURL` would send people to note.pingolin.com,
    /// which has no reset flow on it at all.
    func testAccountPortalIsNotTheNoteWebHost() {
        for env in AppEnvironment.allCases {
            XCTAssertNotEqual(env.accountBaseURL, env.webBaseURL,
                              "account portal must not be note-web (\(env.rawValue))")
        }
    }

    /// No `//` between base and path — the portal's router treats
    /// `//forgot-password` as a different route, and it would land on the
    /// dashboard's auth gate instead of the reset form.
    func testNoDoubleSlashInPortalPaths() {
        let original = AppConfiguration.shared.environment
        defer { AppConfiguration.shared.environment = original }

        for env in AppEnvironment.allCases {
            AppConfiguration.shared.environment = env
            for url in [AppConfiguration.shared.forgotPasswordURL,
                        AppConfiguration.shared.recoverySettingsURL] {
                let path = url?.path ?? ""
                XCTAssertFalse(path.hasPrefix("//"), "\(env.rawValue): \(path)")
            }
        }
    }
}
