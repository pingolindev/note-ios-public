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

/// Sign-out ends the session on the server (`POST /auth/logout`) but never
/// waits long for it: `AuthManager.endServerSession` runs the call under
/// `withDeadline(seconds: 4)`. Without that call the session, which does
/// not expire on its own, would stay live.
final class SignOutTests: XCTestCase {

    private actor Flag {
        private(set) var isSet = false
        func set() { isSet = true }
    }

    func testAQuickServerCallIsWaitedFor() async {
        let done = Flag()
        await AuthManager.withDeadline(seconds: 5) { await done.set() }
        let finished = await done.isSet
        XCTAssertTrue(finished)
    }

    func testAServerCallThatDoesNotAnswerIsCutOffAtTheDeadline() async {
        let cancelled = Flag()
        let start = Date()
        await AuthManager.withDeadline(seconds: 0.2) {
            do {
                try await Task.sleep(for: .seconds(10))
            } catch {
                await cancelled.set()
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2, "a sign-out never waits long on the network")
        let wasCancelled = await cancelled.isSet
        XCTAssertTrue(wasCancelled, "the unanswered call is cancelled, not left running")
    }

    // MARK: - The refresh token names the session

    func testTheSignOutNamesTheSessionByItsRefreshToken() throws {
        let req = try APIService.logoutRequest(
            authBaseURL: "https://api-auth.pingolindev.com",
            accessToken: "expired-access-token",
            refreshToken: "the-refresh-token",
            encoder: APIService.makeWireEncoder()
        )
        XCTAssertEqual(req.url?.absoluteString, "https://api-auth.pingolindev.com/api/v1/auth/logout")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer expired-access-token",
                       "the bearer the app holds is always sent, expired or not")
        XCTAssertNil(req.value(forHTTPHeaderField: "Cookie"))
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(req.httpBody)) as? [String: String]
        XCTAssertEqual(body, ["refresh_token": "the-refresh-token"])
    }

    func testWithoutAnAccessTokenTheRefreshTokenAloneIsSent() throws {
        let req = try APIService.logoutRequest(
            authBaseURL: "https://api-auth.pingolindev.com", accessToken: nil, refreshToken: "rt",
            encoder: APIService.makeWireEncoder()
        )
        XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"))
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(req.httpBody)) as? [String: String]
        XCTAssertEqual(body, ["refresh_token": "rt"])
    }

    /// The API session this request goes through keeps no cookies, so auth's
    /// CSRF check (it runs whenever a Cookie header is present) never applies.
    func testTheApiSessionSendsNoCookies() {
        let configuration = APIService.makeSessionConfiguration()
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
    }
}
