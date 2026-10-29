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

/// The two-step sign-in in this app's words: the server keeps an attempt
/// until its 5th wrong code, so a wrong code or one just used is typed again
/// on the same attempt; too many wrong codes, an ended attempt and an
/// address never verified mean signing in again. The lines are the Track
/// iOS app's. No server text is ever shown on the sign-in screens.
final class TwoFactorRefusalTests: XCTestCase {

    /// What a server might say. None of it is ever on screen.
    private let raw = "Invalid membership statement: at_version is not this circle's current key version. Call 0800 555 0100"

    private func refused(_ status: Int, _ errorCode: String? = nil) -> APIError {
        APIError(code: errorCode ?? "http_\(status)", message: raw, status: status)
    }

    func testEachRefusalIsSaidInTheAppsWordsAndKeepsOrEndsTheAttempt() throws {
        let cases: [(error: APIError, refusal: AuthManager.AuthError, keeps: Bool)] = [
            // "Invalid 2FA code": the attempt survives until its 5th.
            (refused(401), .wrongTwoFactorCode, true),
            // "Code already used. Please wait for a new code."
            (refused(400, "totp_replay"), .twoFactorCodeJustUsed, true),
            // The attempt's 5th wrong code, or the account's limit.
            (refused(429, "rate_limited"), .twoFactorAttemptOver, false),
            // "Invalid or expired 2FA token": it expired, or was already used.
            (refused(400), .twoFactorAttemptEnded, false),
            // After the code was taken: the address was never verified.
            (refused(403, "email_not_verified"), .emailNotVerified, false),
            // After the code was taken: the attempt is spent.
            (refused(403, "account_suspended"), .twoFactorAttemptEnded, false),
        ]
        for c in cases {
            let refusal = try XCTUnwrap(AuthManager.twoFactorRefusal(c.error), "\(c.error.status ?? 0) \(c.error.code)")
            XCTAssertEqual(refusal, c.refusal, c.error.code)
            XCTAssertEqual(refusal.keepsTheTwoFactorAttempt, c.keeps, c.error.code)
            let shown = LoginView.friendlyMessage(for: refusal)
            XCTAssertEqual(shown, refusal.errorDescription, c.error.code)
            XCTAssertFalse(shown.contains("0800"), "the server's words reached the screen: \(shown)")
        }
        // Anything else is said as any other failure, and keeps the attempt.
        XCTAssertNil(AuthManager.twoFactorRefusal(refused(503, "rate_limiter_unavailable")))
        XCTAssertNil(AuthManager.twoFactorRefusal(URLError(.timedOut)))
    }

    func testTheLinesAreTrackIosWords() {
        XCTAssertEqual(AuthManager.AuthError.wrongTwoFactorCode.errorDescription,
                       "That code isn't right. Please try again.")
        XCTAssertEqual(AuthManager.AuthError.twoFactorCodeJustUsed.errorDescription,
                       "That code was just used. Wait for the next one and try again.")
        XCTAssertEqual(AuthManager.AuthError.twoFactorAttemptOver.errorDescription,
                       "Too many wrong codes. Please wait a while, then sign in again.")
        XCTAssertEqual(AuthManager.AuthError.twoFactorAttemptEnded.errorDescription,
                       "That sign-in has ended. Please sign in again.")
        XCTAssertEqual(AuthManager.AuthError.emailNotVerified.errorDescription,
                       "Please verify your email address first. Open the link we sent you, then sign in again.")
    }

    /// The sign-in screen (and the code sheet) never shows the server's text:
    /// a refusal is the credentials, too many tries or trouble; a network
    /// failure is said in the Track iOS app's words; the SDK's text never
    /// shows.
    func testTheSignInScreensNeverShowTheServersText() {
        let cases: [(Error, String)] = [
            (refused(401), "Email or password is incorrect."),
            (refused(403, "account_suspended"), "Email or password is incorrect."),
            (refused(429, "rate_limited"), "Too many sign-in attempts. Try again in a moment."),
            (refused(429), "Too many sign-in attempts. Try again in a moment."),
            (refused(503, "rate_limiter_unavailable"), "The sign-in service is having trouble. Try again in a moment."),
            (refused(500), "The sign-in service is having trouble. Try again in a moment."),
            (refused(400), "Couldn't sign in. Please try again."),
            (refused(404), "Couldn't sign in. Please try again."),
            (URLError(.notConnectedToInternet), "You're offline. Check your connection and try again."),
            (URLError(.timedOut), "Couldn't reach the server. Try again in a moment."),
            (URLError(.badServerResponse), "Network error. Check your connection and try again."),
            (MobileError.InvalidInput(message: "bcrypt salt is not base64: \(raw)"), "Couldn't sign in. Please try again."),
            (AuthManager.AuthError.emailNotVerified,
             "Please verify your email address first. Open the link we sent you, then sign in again."),
            (AuthManager.AuthError.serverProofRejected, "Couldn't sign in. Please try again."),
        ]
        for (error, line) in cases {
            let shown = LoginView.friendlyMessage(for: error)
            XCTAssertEqual(shown, line, "\(error)")
            XCTAssertFalse(shown.contains("0800"), "the server's words reached the screen: \(shown)")
        }
        let limited = AuthRateLimiter.AuthRateLimitError.tooManyAttempts(retryAfter: 29.2)
        XCTAssertEqual(LoginView.friendlyMessage(for: limited), "Too many failed attempts. Try again in 30s.")
    }
}

/// The 12-character backup code at the code sheet: sent whole, as the
/// account portal sends it (the Track iOS app's `codeToSend`).
final class TwoFactorBackupCodeTests: XCTestCase {

    func testABackupCodeIsSentWholeWithoutItsSpacesAndDashes() {
        XCTAssertEqual(TwoFactorView.codeToSend("abcd-efgh-2345"), "abcdefgh2345", "the case is left alone")
        XCTAssertEqual(TwoFactorView.codeToSend(" ABCD EFGH 2345 "), "ABCDEFGH2345")
        XCTAssertEqual(TwoFactorView.codeToSend("ABCDEFGH2345XY"), "ABCDEFGH2345XY", "nothing is cut short")
        XCTAssertEqual(TwoFactorView.codeToSend("123 456"), "123456")
        XCTAssertEqual(TwoFactorView.codeToSend(" - "), "", "nothing to send: Verify stays off")
    }
}
