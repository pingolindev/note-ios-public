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
import Security
@testable import Note

/// This account's id in its one form at the sign-in and at the launch: a
/// reply naming no UUID signs nobody in, on every path that saves an
/// account; a stored id in another spelling is written back; a stored one
/// that isn't a UUID is no account; a read that failed is never "none".
final class AccountIdTests: XCTestCase {

    private let me = "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"
    private let other = "1a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"

    // MARK: - The launch's read of the stored id

    func testTheStoredIdIsReadInItsOneForm() {
        XCTAssertEqual(AuthManager.storedAccount(.notFound), .none)
        XCTAssertEqual(AuthManager.storedAccount(.found(me)), .id(me, rewrite: false))
        for spelling in [me.uppercased(), me.replacingOccurrences(of: "-", with: ""), "{\(me)}", "urn:uuid:\(me)"] {
            XCTAssertEqual(AuthManager.storedAccount(.found(spelling)), .id(me, rewrite: true), spelling)
        }
        for bad in ["u1", "", " \(me)", "URN:UUID:\(me)"] {
            XCTAssertEqual(AuthManager.storedAccount(.found(bad)), .notAnId, bad)
        }
    }

    /// Before the first unlock the read fails: that is never "no stored id",
    /// so nothing is written back and nothing is merged.
    func testAReadThatFailedIsNeverNone() {
        XCTAssertEqual(AuthManager.storedAccount(.unreadable(errSecInteractionNotAllowed)), .unreadable)
        XCTAssertEqual(AuthManager.storedAccount(.unreadable(errSecDecode)), .unreadable)
    }

    // MARK: - The sign-in's account, on both paths that save one

    private func decodeStep2(user id: String?) throws -> SRPStep2Response {
        let user = id.map { #","user":{"id":"\#($0)","email":"a@b.c","status":"active"}"# } ?? ""
        let body = Data(#"{"success":true,"data":{"server_proof":"AAAA","access_token":"at","refresh_token":"rt"\#(user)}}"#.utf8)
        return try APIService.decodeSuccessBody(body, using: APIService.makeWireDecoder())
    }

    private func decodeTwoStep(user id: String) throws -> Login2FAResponse {
        let body = Data(#"""
        {"success":true,"data":{"user":{"id":"\#(id)","email":"a@b.c"},
         "kdf_params":{"salt":"73","memory_kib":65536,"iterations":2,"parallelism":1},
         "encrypted_keys":{"master_key":{"nonce":"bb","ciphertext":"aa"},
                           "sharing_private_key":{"nonce":"dd","ciphertext":"cc"},
                           "sharing_public_key":"ee"},
         "access_token":"at","refresh_token":"rt"}}
        """#.utf8)
        return try APIService.decodeSuccessBody(body, using: APIService.makeWireDecoder())
    }

    func testThePasswordStepsReplyNamesTheAccountInItsOneFormOrNobody() throws {
        XCTAssertEqual(AuthManager.signInAccount(try decodeStep2(user: me.uppercased()).user?.id), me)
        XCTAssertEqual(AuthManager.signInAccount(try decodeStep2(user: "urn:uuid:\(me)").user?.id), me)
        for bad in ["u1", "", " \(me)"] {
            XCTAssertNil(AuthManager.signInAccount(try decodeStep2(user: bad).user?.id), bad)
        }
        XCTAssertNil(AuthManager.signInAccount(try decodeStep2(user: nil).user?.id), "no user object")
    }

    func testTheTwoStepRepliesNameTheAccountInItsOneFormOrNobody() throws {
        XCTAssertEqual(AuthManager.signInAccount(try decodeTwoStep(user: "{\(me)}").user.id), me)
        for bad in ["u1", "", "{\(me.replacingOccurrences(of: "-", with: ""))}"] {
            XCTAssertNil(AuthManager.signInAccount(try decodeTwoStep(user: bad).user.id), bad)
        }
    }

    func testTheSwitchComparesInTheOneForm() {
        XCTAssertFalse(AuthManager.isAccountSwitch(prior: nil, incoming: me))
        XCTAssertFalse(AuthManager.isAccountSwitch(prior: me.uppercased(), incoming: me))
        XCTAssertFalse(AuthManager.isAccountSwitch(prior: "{\(me)}", incoming: me))
        XCTAssertTrue(AuthManager.isAccountSwitch(prior: other, incoming: me))
        XCTAssertTrue(AuthManager.isAccountSwitch(prior: "u1", incoming: me), "a stored id that isn't a UUID is another account")
    }

    func testMeMatchesTheStoredAccountInTheOneForm() {
        XCTAssertEqual(AuthManager.meMatches(stored: nil, me: me.uppercased()), me)
        XCTAssertEqual(AuthManager.meMatches(stored: me, me: me.uppercased()), me)
        XCTAssertNil(AuthManager.meMatches(stored: other, me: me))
        XCTAssertNil(AuthManager.meMatches(stored: me, me: "u1"), "a /me id that isn't a UUID matches nothing")
        XCTAssertNil(AuthManager.meMatches(stored: nil, me: "u1"))
    }

    // MARK: - Where the decisions are used (AuthManager's source)

    private func source() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("App/Managers/AuthManager.swift"), encoding: .utf8)
    }

    private func body(_ source: String, from start: String, to end: String) throws -> String {
        let s = try XCTUnwrap(source.range(of: start), start)
        let e = try XCTUnwrap(source.range(of: end, range: s.upperBound..<source.endIndex), end)
        return String(source[s.upperBound..<e.lowerBound])
    }

    /// Every path that saves an account goes through finishLogin, and it is the
    /// only place `.userId` is saved: its guard is the refusal for all of them.
    func testEveryPathThatSavesAnAccountRefusesAReplyNamingNoUUID() throws {
        let text = try source()
        let saves = try NSRegularExpression(pattern: #"\.save\([^)]*, for: \.userId\)"#)
            .numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
        XCTAssertEqual(saves, 2, "the sign-in's save and the launch's write-back, nothing else")
        let launch = try body(text, from: "func checkExistingSession() async {", to: "func login(email: String, password: String)")
        XCTAssertTrue(launch.contains("case .id(let id, let rewrite):\n            // Written back while the Keychain reads (the token just did).\n            if rewrite { try? keychain.save(id, for: .userId) }"))
        let finish = try body(text, from: "private func finishLogin(", to: "func verify2FA(code: String)")
        let guardRange = try XCTUnwrap(finish.range(of: "guard let id = Self.signInAccount(userId) else { throw AuthError.noAccessToken }"))
        let cleanup = try XCTUnwrap(finish.range(of: "await switchAccountCleanup()"))
        let save = try XCTUnwrap(finish.range(of: "try keychain.save(id, for: .userId)"))
        XCTAssertTrue(guardRange.upperBound <= cleanup.lowerBound && cleanup.upperBound <= save.lowerBound)
        let login = try body(text, from: "func login(email: String, password: String) async throws {", to: "private func finishLogin(")
        XCTAssertTrue(login.contains("try await finishLogin("))
        let twoStep = try body(text, from: "func verify2FA(code: String) async throws {", to: "func cancelTwoFactorChallenge()")
        XCTAssertTrue(twoStep.contains("try await finishLogin("))
    }

    /// The launch reads the stored id once, before anything binds to it; binds
    /// the stores only from a read that succeeded; merges other spellings only
    /// after one that found an id.
    func testTheLaunchReadsTheStoredIdOnceAndMergesOnlyAfterARead() throws {
        let launch = try body(try source(), from: "func checkExistingSession() async {", to: "func login(email: String, password: String)")
        XCTAssertEqual(launch.components(separatedBy: "keychain.read(.userId)").count - 1, 1)
        XCTAssertFalse(launch.contains("getString(for: .userId)"))
        let read = try XCTUnwrap(launch.range(of: "let storedAccount = Self.storedAccount(keychain.read(.userId))"))
        let bind = try XCTUnwrap(launch.range(of: "if storedAccount != .unreadable {\n            SenderKeyPinStore.shared.switchUser(storedId)"))
        let merge = try XCTUnwrap(launch.range(of: "if case .id = storedAccount {"))
        XCTAssertTrue(read.upperBound <= bind.lowerBound && bind.upperBound <= merge.lowerBound)
        let mergeBlock = String(launch[merge.upperBound...].prefix(600))
        XCTAssertTrue(mergeBlock.contains("SenderKeyPinStore.shared.adoptOtherSpellings()"))
        XCTAssertTrue(launch.contains("case .notAnId:\n            // A saved id that isn't a UUID is no account: the session ends like\n            // an expiry, and the next sign-in treats it as another account's.\n            expireSession()\n            return"))
        XCTAssertTrue(launch.contains("guard let meId = Self.meMatches(stored: storedId, me: me.id) else {\n                expireSession()"))
    }
}
