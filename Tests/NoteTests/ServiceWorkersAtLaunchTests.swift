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

import WebKit
import XCTest
@testable import Note

/// The shell keeps no service worker. The web editor registers none in it, and on a normal start removes
/// one that an older build registered. But a worker that is already installed serves its own document, so
/// the page's removal never runs in it, and its update fetch belongs to no page, so the editor's
/// leaked-key check never sees that fetch's server trust. So once per launch, before the first load, the
/// shell removes the registrations from its own store, and nothing else: that store also holds the edits
/// not synced yet.
final class ServiceWorkersAtLaunchTests: XCTestCase {

    private let origin = "https://note.pingolindev.com"

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    /// The removal leaves the page's own storage, where unsynced edits wait: a localStorage item written
    /// first is still there after it. Nothing can register a worker here (a page loaded from a string, a
    /// store kept in memory), so this shows what the removal leaves, not a worker removed.
    @MainActor
    func testTheRemovalLeavesThePagesOwnStorage() async throws {
        let dataStore = WKWebsiteDataStore.nonPersistent()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        let web = WKWebView(frame: .zero, configuration: config)
        let loaded = expectation(description: "loaded")
        let delegate = FinishDelegate { loaded.fulfill() }
        web.navigationDelegate = delegate
        web.loadHTMLString("<html><body>x</body></html>", baseURL: URL(string: origin + "/")!)
        await fulfillment(of: [loaded], timeout: 20)
        _ = try await web.evaluateJavaScript("localStorage.setItem('queued','edit'); 1")

        await WebShellModel.removeServiceWorkers(dataStore)
        let kept = try await web.evaluateJavaScript("localStorage.getItem('queued')") as? String
        XCTAssertEqual(kept, "edit", "the page's own storage stays")
        _ = delegate
    }

    /// The first load waits for the removal: the shell's first task removes the workers, then seeds the cookie, then
    /// loads. The removal is of the registrations only, from the shell's own store, once per launch.
    func testTheFirstLoadWaitsForTheRemoval() throws {
        let shell = try source("App/Views/WebShellView.swift")
        XCTAssertTrue(shell.contains("""
                Task { @MainActor [weak self] in
                    await self?.removeServiceWorkersOnce()
                    await self?.seedCookies()
                    self?.loadHome()
                }
        """), "removed before the first load")
        XCTAssertTrue(shell.contains("""
                guard !serviceWorkersRemoved else { return }
                await Self.removeServiceWorkers(WebShellDataStore.store())
                serviceWorkersRemoved = true
        """), "from the shell's own store, once")
        XCTAssertTrue(shell.contains(
            "removeData(ofTypes: [WKWebsiteDataTypeServiceWorkerRegistrations], modifiedSince: .distantPast)"
        ), "the registrations only")
    }
}

private final class FinishDelegate: NSObject, WKNavigationDelegate {
    private let done: () -> Void
    init(_ done: @escaping () -> Void) { self.done = done }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done() }
}
