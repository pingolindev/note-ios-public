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

/// Sign Up and Forgot password open inside Note, not in the Safari app.
///
/// App Review can reject these links when they open the Safari app
/// (Guideline 4). Each opens the account site in Safari's view
/// controller inside the app, and closing it comes back to sign-in.
final class AccountPagesInAppTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor func testSignUpOpensInsideTheApp() throws {
        assertOpensInsideTheApp("login-sign-up")
    }

    @MainActor func testForgotPasswordOpensInsideTheApp() throws {
        assertOpensInsideTheApp("login-forgot-password")
    }

    @MainActor
    private func assertOpensInsideTheApp(_ identifier: String, line: UInt = #line) {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestCleanState"]
        app.launch()

        let link = app.buttons[identifier]
        XCTAssertTrue(link.waitForExistence(timeout: 20), "\(identifier) missing from the sign-in screen")
        link.tap()
        assertInAppBrowser(showing: "account.pingolin", in: app, line: line)
        XCTAssertTrue(app.textFields["Email"].waitForExistence(timeout: 10),
                      "closing the browser should return to the sign-in form")
    }
}
