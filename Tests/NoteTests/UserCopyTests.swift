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

/// The rule for everything a person reads: no talk of keys, which means
/// nothing to most people. Say what happens instead. The product nouns
/// "recovery key" and "passkey" are the only exceptions. The sign-in
/// errors are the text this app shows itself (the notes UI is the web
/// page's).
final class UserCopyTests: XCTestCase {

    func testSignInMessagesDoNotTalkAboutKeys() throws {
        let banned = try NSRegularExpression(
            pattern: #"(?<!recovery )\bkeys?\b|\bwrap(s|ped)?\b|\bre-?key|\brotat|safety number"#,
            options: [.caseInsensitive]
        )
        let errors: [AuthManager.AuthError] = [
            .noAccessToken, .twoFactorChallengeExpired, .vaultKeyUnavailable, .twoFactorPasskeyOnly,
            .serverProofRejected, .reauthServerProofRejected, .reauthWrongPassword,
            .wrongTwoFactorCode, .twoFactorCodeJustUsed, .twoFactorAttemptOver, .twoFactorAttemptEnded,
            .emailNotVerified,
        ]
        for error in errors {
            let text = try XCTUnwrap(error.errorDescription)
            XCTAssertNil(banned.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                         "\(error): \(text)")
        }
        XCTAssertEqual(AuthManager.AuthError.vaultKeyUnavailable.errorDescription,
                       "Couldn't open your notes on this device. Please sign in again.")
    }

    /// The exact notice for an SDK key store that doesn't decode.
    func testTheKeyStoreNoticeIsExactAndDoesNotTalkAboutKeys() throws {
        let banned = try NSRegularExpression(
            pattern: #"(?<!recovery )\bkeys?\b|\bwrap(s|ped)?\b|\bre-?key|\brotat|safety number"#,
            options: [.caseInsensitive]
        )
        let text = KeyStoreRecovery.syncNoticeText
        XCTAssertEqual(text, "Sync error. Please sign in again.")
        XCTAssertNil(banned.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)))
    }
}
