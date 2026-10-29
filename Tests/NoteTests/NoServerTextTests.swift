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
import PingolinNoteSDK
@testable import Note

/// No server `error` text ever reaches the screen. It can carry technical
/// wording, or whatever a hacked server wants a person to read. Nor does
/// the SDK's own error text (`MobileError.KeyNotFound(message: …)`):
/// wording about keys, and a network one can carry the server's words.
/// What a person reads is this app's words, or the system's.
final class NoServerTextTests: XCTestCase {

    private let raw = "Invalid membership statement: at_version is not this circle's current key version. Call 0800 555 0100"

    /// Every refusal gets a plain line by what kind of failure it is, and none
    /// carries the server's text.
    func testAnAPIErrorDescribesItselfInTheAppsWords() {
        let cases: [(code: String, status: Int?, line: String)] = [
            ("weird_thing", 400, APIError.failedText),
            ("http_400", 400, APIError.failedText),
            ("unspent_credit_balance", 409, APIError.failedText),
            ("http_404", 404, APIError.goneText),
            ("note_not_found", 400, APIError.goneText),
            ("http_403", 403, APIError.notAllowedText),
            ("auth_not_owner", 400, APIError.notAllowedText),
            ("auth_insufficient_permissions", 400, APIError.notAllowedText),
            ("http_429", 429, APIError.tooManyText),
            ("rate_limited", 400, APIError.tooManyText),
            ("http_500", 500, APIError.troubleText),
            // The status first: auth's rate limiter being down is trouble, not too many tries.
            ("rate_limiter_unavailable", 503, APIError.troubleText),
            ("server_unavailable", 409, APIError.troubleText),
            ("network_error", nil, APIError.unreachableText),
            ("http_402", 402, APIError.planLimitText),
            ("quota_notes_exceeded", 400, APIError.planLimitText),
            ("premium_required_sharing", 403, APIError.planLimitText),
        ]
        for c in cases {
            let error = APIError(code: c.code, message: raw, status: c.status)
            XCTAssertEqual(error.plainLine, c.line, c.code)
            XCTAssertEqual(error.localizedDescription, c.line, c.code)
            XCTAssertEqual((error as Error).plainText, c.line, c.code)
        }
        // A quota object alone is a plan limit, whatever the code.
        let gated = APIError(code: "http_400", message: raw, status: 400,
                             quota: try? JSONDecoder().decode(QuotaErrorInfo.self, from: Data("{}".utf8)))
        XCTAssertEqual(gated.plainLine, APIError.planLimitText)
        // The server's text is kept, for logs.
        XCTAssertEqual(APIError(code: "x", message: raw).message, raw)
    }

    /// The SDK's errors describe themselves with their case and message; what
    /// a person reads is a plain line. This app's own errors, and the system's,
    /// keep their words.
    func testTheSDKsErrorTextIsNeverShown() {
        let network = MobileError.NetworkError(message: "status: Unavailable, message: \"\(raw)\"")
        let key = MobileError.KeyNotFound(message: "no vault key for version 3")
        XCTAssertTrue(network.localizedDescription.contains("0800"), "the trap: what it would have shown")
        XCTAssertEqual((network as Error).plainText, APIError.unreachableText)
        XCTAssertEqual((key as Error).plainText, APIError.failedText)
        let offline = URLError(.notConnectedToInternet)
        XCTAssertEqual((offline as Error).plainText, offline.localizedDescription, "the system's words stay")
        XCTAssertEqual((AuthManager.AuthError.reauthWrongPassword as Error).plainText, "Invalid password")
        XCTAssertEqual((AuthManager.AuthError.reauthServerProofRejected as Error).plainText,
                       "Couldn't check your password just now.")
    }

    /// The App Store refusals, the credit question and the sign-in errors, in
    /// the app's words.
    func testRefusalsAreSaidInTheAppsWords() {
        let codes = ["apple_family_shared", "apple_transaction_revoked", "apple_wrong_account",
                     "apple_unattributable", "apple_already_expired", "apple_something_new"]
        for code in codes {
            let text = StoreKitManager.refusalText(APIError(code: code, message: raw, status: 409))
            XCTAssertFalse(text.contains("0800"), code)
            XCTAssertFalse(text.isEmpty, code)
        }
        XCTAssertEqual(StoreKitManager.refusalText(APIError(code: "apple_wrong_account", message: raw, status: 409)),
                       "This purchase belongs to a different account.")
        XCTAssertEqual(StoreKitManager.refusalText(APIError(code: "apple_something_new", message: raw, status: 409)),
                       "This purchase can't be used for a subscription.")
        XCTAssertTrue(DeleteAccountSheet.unspentCreditText.hasPrefix("Deleting your account destroys the credit on it"))
        XCTAssertEqual(AuthManager.AuthError.noAccessToken.errorDescription, "Couldn't sign in. Please try again.")
    }

    /// A wrong password at the step-up before deleting the account is said in
    /// this app's words; the step-up's other 401 (an expired handshake) is not
    /// a wrong password.
    func testTheStepUpsRefusalsAreSaidInTheAppsWords() {
        let wrong = AuthManager.reauthRefusal(APIError(code: "invalid_credentials", message: raw, status: 401))
        XCTAssertEqual(wrong as? AuthManager.AuthError, .reauthWrongPassword)
        XCTAssertEqual(wrong.plainText, "Invalid password")
        let stale = AuthManager.reauthRefusal(APIError(code: "reauth_session_expired", message: raw, status: 401))
        XCTAssertNil(stale as? AuthManager.AuthError)
        XCTAssertEqual(stale.plainText, APIError.failedText)
        let trouble = AuthManager.reauthRefusal(APIError(code: "http_503", message: raw, status: 503))
        XCTAssertEqual(trouble.plainText, APIError.troubleText)
    }

    /// The purchase eligibility answer: the server's `reason` is never shown.
    /// auth writes "on the web" whatever the other provider is.
    func testThePurchaseRefusalIsSaidInTheAppsWords() throws {
        let body = #"{"success":true,"data":{"can_purchase":false,"reason":"You already subscribe to Pingolin Note on the web. \#(raw)","existing_provider":"paddle"}}"#
        let answer: ApplePurchaseEligibility = try APIService.decodeSuccessBody(Data(body.utf8),
                                                                               using: APIService.makeWireDecoder())
        XCTAssertNotNil(answer.reason, "the trap: the server sends words of its own")
        let kept = PremiumSheet.kept(answer)
        XCTAssertFalse(kept.canPurchase)
        XCTAssertNil(kept.reason)
        XCTAssertEqual(kept.existingProvider, "paddle")
        XCTAssertEqual(PremiumSheet.notEligibleLine(kept), "You already have a subscription for this.")
        // This app's own reason, for a check that failed, is still said.
        let failed = ApplePurchaseEligibility(canPurchase: false,
                                              reason: "We could not check your subscription. Please try again in a moment.",
                                              existingProvider: nil)
        XCTAssertEqual(PremiumSheet.notEligibleLine(failed),
                       "We could not check your subscription. Please try again in a moment.")
    }

    /// Every Swift source of the app and its extensions.
    private func appSources() -> [URL] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var files: [URL] = []
        for dir in ["App", "NoteShareExt", "NoteWidgets", "Shared"] {
            guard let walk = FileManager.default.enumerator(at: root.appendingPathComponent(dir),
                                                            includingPropertiesForKeys: nil) else { continue }
            files += walk.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        }
        return files
    }

    private static let errorTextRead = #"\.(message|errorDescription|localizedDescription)\b"#

    /// Nothing decides anything on an error's text: no `==`, `contains`,
    /// `hasPrefix`, `hasSuffix` or `switch` over an error's `message`,
    /// `errorDescription` or `localizedDescription`. Decisions read a
    /// refusal's `code` or `status`. There are none, and this keeps it so.
    func testNothingDecidesOnAnErrorsText() throws {
        let read = Self.errorTextRead
        let ops = #"(==|!=|\.contains\(|\.hasPrefix\(|\.hasSuffix\(|\.range\(of|\.starts\(with)"#
        let decision = try NSRegularExpression(pattern: read + ".*" + ops + "|" + ops + ".*" + read + #"|\bswitch\b.*"# + read)
        let files = appSources()
        XCTAssertGreaterThan(files.count, 50)
        var found: [String] = []
        for file in files {
            for line in try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n") {
                let code = line.trimmingCharacters(in: .whitespaces)
                if code.hasPrefix("//") { continue }
                if decision.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                    found.append("\(file.lastPathComponent): \(code)")
                }
            }
        }
        XCTAssertEqual(found, [], "a decision on an error's text")
    }

    /// The sweep: no screen reads an error's `message`, `errorDescription` or
    /// `localizedDescription` except through this app's words (`plainText`,
    /// `plainLine`, `friendlyMessage`). What is left is logs, this app's or
    /// the system's words, and reads whose text is shown nowhere. A new read
    /// fails here until it is one of those; an allowed read that is gone
    /// fails too, so the list stays honest.
    func testNoServerTextReachesTheScreen() throws {
        let files = appSources()
        XCTAssertGreaterThan(files.count, 50)
        let read = try NSRegularExpression(pattern: Self.errorTextRead)
        let logs = ["print(", "privacy: .public"]
        let allowed: [String: [String]] = [
            // The system's words (LocalAuthentication), shown in Settings.
            "AppLockManager.swift": ["lastError = (error as NSError).localizedDescription"],
            // This app's words.
            "AuthManager.swift": ["signInNotice = AuthError.vaultKeyUnavailable.errorDescription"],
            "LoginView.swift": [
                "if let auth = error as? AuthManager.AuthError, let text = auth.errorDescription {",
                "if let limited = error as? AuthRateLimiter.AuthRateLimitError, let text = limited.errorDescription {",
            ],
            // RestoreOutcome.message: this app's lines, and refusalText's.
            "PremiumSheet.swift": ["restoreMessage = outcome.message"],
            // Stored in `lastError`, which nothing reads; an APIError there is its plain line.
            "PushNotificationManager.swift": [
                "lastError = \"Notifications request failed: \\(error.localizedDescription)\"",
                "lastError = \"Push registration failed: \\(error.localizedDescription)\"",
                "lastError = \"APNs registration failed: \\(error.localizedDescription)\"",
            ],
            // Shown nowhere: BackupRestore has no screen on iOS (tests only).
            "BackupRestore.swift": [
                "throw ReadError.unreadable((error as? LocalizedError)?.errorDescription ?? \"\\(error)\")",
                "throw ReadError.unreadable(error.localizedDescription)",
            ],
            // Shown nowhere: no screen reads the shares inbox's rows.
            "SharesInboxStore.swift": ["decryptError = error.localizedDescription"],
            // The page's own alert()/confirm() text (the web app's words).
            "WebShellView.swift": ["self.message = message", "model.jsDialog?.message ?? \"\","],
        ]
        var found: [String: [String]] = [:]
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for line in lines {
                let code = line.trimmingCharacters(in: .whitespaces)
                if code.hasPrefix("//") { continue }
                guard read.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil else { continue }
                if logs.contains(where: { line.contains($0) }) { continue }
                found[file.lastPathComponent, default: []].append(code)
            }
        }
        var unexpected: [String] = []
        for (file, lines) in found {
            var left = allowed[file] ?? []
            for line in lines {
                if let i = left.firstIndex(of: line) { left.remove(at: i) } else { unexpected.append("\(file): \(line)") }
            }
        }
        XCTAssertEqual(unexpected.sorted(), [], "server or SDK text read for the screen")
        var stale: [String] = []
        for (file, lines) in allowed {
            var left = found[file] ?? []
            for line in lines {
                if let i = left.firstIndex(of: line) { left.remove(at: i) } else { stale.append("\(file): \(line)") }
            }
        }
        XCTAssertEqual(stale.sorted(), [], "allowed reads that are gone (drop them here)")
    }
}
