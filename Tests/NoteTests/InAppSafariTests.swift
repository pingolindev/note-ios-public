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

import UIKit
import XCTest
@testable import Note

/// Which links open inside the app (`InAppSafari`), and how they are marked.
///
/// App Review can reject a Sign Up link that opens the Safari app, and the
/// sign-in screen has such links, so every account page must qualify for
/// the in-app browser, in every environment. Only account pages may: the
/// browser cannot be steered, and the account site hides its billing pages
/// only in a tab that arrived marked `in_app=1`. Nothing
/// SFSafariViewController refuses may reach it either: it raises on any
/// scheme but http(s), which would crash on a tap.
final class InAppSafariTests: XCTestCase {

    private var original: AppEnvironment!

    override func setUp() {
        super.setUp()
        original = AppConfiguration.shared.environment
    }

    override func tearDown() {
        AppConfiguration.shared.environment = original
        super.tearDown()
    }

    private func accountPages() -> [(String, URL?)] {
        let config = AppConfiguration.shared
        return [
            ("register", config.registerURL),
            ("forgot password", config.forgotPasswordURL),
            ("recovery settings", config.recoverySettingsURL),
        ]
    }

    func testEveryAccountPageOpensInTheApp() {
        for env in AppEnvironment.allCases {
            AppConfiguration.shared.environment = env
            for (name, url) in accountPages() {
                guard let url else {
                    XCTFail("\(env.rawValue): no \(name) URL")
                    continue
                }
                XCTAssertTrue(InAppSafari.opensInApp(url), "\(env.rawValue): \(name) \(url)")
            }
        }
    }

    /// Every account page goes out marked, and keeps its path and fragment.
    func testEveryAccountPageIsMarked() throws {
        for env in AppEnvironment.allCases {
            AppConfiguration.shared.environment = env
            for (name, url) in accountPages() {
                let url = try XCTUnwrap(url, "\(env.rawValue): no \(name) URL")
                let marked = try XCTUnwrap(URLComponents(url: InAppSafari.marked(url), resolvingAgainstBaseURL: false))
                XCTAssertEqual(marked.queryItems, [URLQueryItem(name: "in_app", value: "1")], "\(env.rawValue): \(name)")
                XCTAssertEqual(marked.path, url.path, "\(env.rawValue): \(name)")
                XCTAssertEqual(marked.fragment, url.fragment, "\(env.rawValue): \(name)")
                XCTAssertEqual(marked.host, url.host, "\(env.rawValue): \(name)")
            }
        }
    }

    func testMarkingKeepsOtherQueryItemsAndHappensOnce() {
        let url = URL(string: "https://account.pingolin.com/login?redirect=%2Fsecurity#top")!
        let marked = InAppSafari.marked(url)
        XCTAssertEqual(marked.absoluteString, "https://account.pingolin.com/login?redirect=%2Fsecurity&in_app=1#top")
        XCTAssertEqual(InAppSafari.marked(marked), marked, "already marked: unchanged")
    }

    /// The website's pages link to the account site without the marker, so a
    /// legal page opened in here would be a way to the unmarked billing pages.
    func testOtherWebPagesGoToTheSystem() {
        AppConfiguration.shared.environment = .production
        for url in [
            StoreKitManager.Legal.terms,
            StoreKitManager.Legal.privacy,
            URL(string: "https://pingolin.com/pricing")!,
            URL(string: "https://note.pingolin.com/")!,
            URL(string: "https://account.pingolin.com.example.net/register")!,
            URL(string: "https://account.pingolindev.com/register")!,
            URL(string: "https://account.pingolin.com:8443/register")!,
        ] {
            XCTAssertFalse(InAppSafari.opensInApp(url), url.absoluteString)
        }
    }

    func testOtherSchemesGoToTheSystem() {
        for raw in [
            "mailto:help@support.pingolin.com",
            "message://",
            UIApplication.openSettingsURLString,
            "tel:+15555550100",
            "file:///settings",
        ] {
            let url = URL(string: raw)!
            XCTAssertFalse(InAppSafari.opensInApp(url), raw)
        }
    }

    /// A scheme alone is not a page: `https:` with no host would load nothing.
    func testWebSchemeWithoutHostGoesToTheSystem() {
        XCTAssertFalse(InAppSafari.opensInApp(URL(string: "https:")!))
    }

    func testSchemeAndHostAreCaseInsensitive() {
        AppConfiguration.shared.environment = .production
        XCTAssertTrue(InAppSafari.opensInApp(URL(string: "HTTPS://Account.Pingolin.com/register")!))
    }
}
