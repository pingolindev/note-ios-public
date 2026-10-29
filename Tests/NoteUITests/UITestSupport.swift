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

/// Helpers shared by the XCUITest classes in this bundle.
extension XCTestCase {

    /// Assert that the tap just made opened a web page INSIDE the app
    /// (Safari's view controller) on `host`, then close it with the
    /// browser's own button.
    ///
    /// Note's account links open in the app (`InAppSafari`): App Review
    /// can reject sending sign-up to the Safari app (Guideline 4). On iOS
    /// 26.4 the browser publishes a `TopBrowserBar` holding a "Close"
    /// button and a "URL" button whose value is the page's host. Earlier
    /// iOS calls the close button "Done".
    @MainActor
    func assertInAppBrowser(
        showing host: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let address = app.buttons["URL"]
        let opened = address.waitForExistence(timeout: 10)
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        if safari.state == .runningForeground {
            // Leave the simulator on the app for the tests that follow.
            app.activate()
            XCTFail("the link switched to the Safari app", file: file, line: line)
            return
        }
        XCTAssertTrue(opened, "no in-app browser opened:\n\(app.debugDescription)", file: file, line: line)
        guard opened else { return }
        XCTAssertEqual(app.state, .runningForeground, file: file, line: line)
        XCTAssertTrue(String(describing: address.value ?? "").contains(host),
                      "the in-app browser shows \(String(describing: address.value)), not \(host)",
                      file: file, line: line)

        let close = app.buttons.matching(
            NSPredicate(format: "identifier IN %@", ["Close", "Done"])
        ).firstMatch
        XCTAssertTrue(close.exists, "the in-app browser needs its way back:\n\(app.debugDescription)",
                      file: file, line: line)
        // A touch at the button's centre, as a finger would. The element's own
        // `tap()` does nothing on this button: the browser's controls belong to
        // another process (SafariViewService); on iOS 26.4 two element taps in
        // a row left the page open while one coordinate tap closed it.
        close.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(address.waitForNonExistence(timeout: 10), "the in-app browser did not close",
                      file: file, line: line)
    }
}
