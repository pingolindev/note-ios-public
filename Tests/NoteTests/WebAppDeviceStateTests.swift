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

/// The device snapshot the web Settings panel reads.
///
/// The shell injects `__pingolinDevice` alongside `__pingolinShellSettings`:
/// without it the web editor's `SettingsPanel.tsx` gets nothing from
/// `deviceRows()`, and the panel falls back to one valueless "App settings"
/// button that opens a whole second Settings screen. The Android app
/// provides the same rows contract; these tests pin this app's half of it.
final class WebAppDeviceStateTests: XCTestCase {

    private func device(
        push: PushDeliveryMode = .apns,
        lock: Bool = false,
        version: String = "1.0.0 (8)"
    ) -> WebAppDeviceState.Device {
        WebAppDeviceState.Device(pushMode: push, appLockEnabled: lock, appVersion: version)
    }

    // MARK: - Shape

    func testSnapshotCarriesTheRowsThePanelRenders() {
        let snap = WebAppDeviceState.snapshot(device())
        XCTAssertEqual(snap["platform"] as? String, "ios")
        let rows = snap["rows"] as? [[String: String]]
        XCTAssertEqual(rows?.count, 5)
        XCTAssertEqual(rows?.map { $0["id"] },
                       ["security", "push", "about", "diagnostics", "account"])
        // Every row needs all four keys: the panel reads r.label, r.value and
        // r.section, and a missing one renders as blank rather than failing.
        for row in rows ?? [] {
            for key in ["id", "label", "value", "section"] {
                XCTAssertNotNil(row[key], "row \(row["id"] ?? "?") is missing \(key)")
            }
        }
    }

    func testSectionIdsMatchAndroid() {
        // The page is SHARED. If these drift from note-android's
        // WebAppDeviceState the deep link opens nothing on one platform.
        XCTAssertEqual(WebAppDeviceState.sectionSecurity, "security")
        XCTAssertEqual(WebAppDeviceState.sectionNotifications, "notifications")
        XCTAssertEqual(WebAppDeviceState.sectionDiagnostics, "diagnostics")
        XCTAssertEqual(WebAppDeviceState.sectionAbout, "about")
        XCTAssertEqual(WebAppDeviceState.sectionAccount, "account")
        let sections = WebAppDeviceState.snapshot(device())["sections"] as? [String: String]
        XCTAssertEqual(sections?["security"], "security")
        XCTAssertEqual(sections?["notifications"], "notifications")
        XCTAssertEqual(sections?["diagnostics"], "diagnostics")
        XCTAssertEqual(sections?["about"], "about")
        XCTAssertEqual(sections?["account"], "account")
    }

    func testAccountDeletionIsTaggedAccountAndNotSomethingElse() {
        // `account` is the ONE section id the PAGE reads rather than echoes:
        // the web editor's SettingsPanel filters it out of the Device list
        // and renders it under the Account heading. Tag account deletion as
        // anything else and the page puts "delete your account" beneath
        // "These are set on this device", which describes app-lock
        // preferences. Asserting the exact string because a plausible-looking
        // near-miss ("accounts", "diagnostics") still renders a row, still
        // opens the right sheet, and is silently in the wrong place.
        let rows = WebAppDeviceState.snapshot(device())["rows"] as? [[String: String]]
        XCTAssertEqual(rows?.first(where: { $0["id"] == "account" })?["section"], "account")
    }

    // MARK: - Values

    func testPushRowNamesTheTransport() {
        func value(_ mode: PushDeliveryMode) -> String? {
            let rows = WebAppDeviceState.snapshot(device(push: mode))["rows"] as? [[String: String]]
            return rows?.first(where: { $0["id"] == "push" })?["value"]
        }
        XCTAssertEqual(value(.apns), "Apple Push Notifications")
        XCTAssertEqual(value(.polling), "Polling")
    }

    func testAboutRowReachesItsOwnSectionAndCarriesTheVersion() {
        // Without this row nothing ever sends section=about,
        // because SettingsPanel.tsx only ever deep-links a
        // section it was GIVEN. The app version would
        // then be reachable only from the offline retry view
        // -- and it is the first thing any support
        // conversation asks for. Asserting the section string
        // specifically: an "about" row pointing anywhere else
        // would still render in the panel and still open the
        // wrong group, or nothing.
        let rows = WebAppDeviceState.snapshot(device(version: "9.9.9 (42)"))["rows"]
            as? [[String: String]]
        let about = rows?.first(where: { $0["id"] == "about" })
        XCTAssertEqual(about?["section"], WebAppDeviceState.sectionAbout)
        XCTAssertEqual(about?["value"], "9.9.9 (42)")
        XCTAssertEqual(about?["label"], "About")
    }

    func testSecurityRowCarriesNoValue() {
        // Deliberate, and the same call Android made: a summary describes a
        // GROUP rather than one setting, and reads as noise beside a row that
        // names one thing.
        let rows = WebAppDeviceState.snapshot(device(lock: true))["rows"] as? [[String: String]]
        XCTAssertEqual(rows?.first(where: { $0["id"] == "security" })?["value"], "")
    }

    // MARK: - The origin guard

    func testScriptRefusesAnyOtherOrigin() {
        // decidePolicyFor and evaluateJavaScript both run against WHATEVER the
        // WebView has loaded, including the account portal. The guard must be
        // the first statement, before the assignment.
        let js = WebAppDeviceState.buildScript(
            device: device(), origin: "https://note.pingolindev.com", onLoad: true
        )
        XCTAssertTrue(
            js.contains("if(location.origin!==\"https://note.pingolindev.com\")return;"),
            "origin guard missing or not first: \(js.prefix(120))"
        )
        let guardIndex = js.range(of: "location.origin")?.lowerBound
        let assignIndex = js.range(of: "window.__pingolinDevice")?.lowerBound
        XCTAssertNotNil(guardIndex)
        XCTAssertNotNil(assignIndex)
        XCTAssertTrue(guardIndex! < assignIndex!, "the assignment runs before the guard")
    }

    func testOriginIsEscapedRatherThanInterpolatedRaw() {
        // A quote in the origin would otherwise close the string literal and
        // let the rest be read as code.
        let js = WebAppDeviceState.buildScript(
            device: device(), origin: "https://x\"+alert(1)+\"", onLoad: true
        )
        XCTAssertFalse(js.contains("\"+alert(1)+\""), "origin was interpolated unescaped: \(js)")
        XCTAssertTrue(js.contains("\\\""))
    }

    // MARK: - Refresh

    func testOnlyTheRefreshFiresTheChangeEvent() {
        // The document-start script assigns and returns; firing an event there
        // would be pointless (nothing is listening yet) and, worse, the panel
        // would re-read on every navigation.
        let load = WebAppDeviceState.buildScript(
            device: device(), origin: "https://n", onLoad: true
        )
        let refresh = WebAppDeviceState.buildScript(
            device: device(), origin: "https://n", onLoad: false
        )
        XCTAssertFalse(load.contains("pingolin-device-changed"))
        XCTAssertTrue(refresh.contains("pingolin-device-changed"))
    }

    func testRefreshReflectsAChangedValue() {
        // The whole point of the foreground re-push: change push mode on the
        // native screen, come back, and the row you left shows the new value.
        let before = WebAppDeviceState.buildScript(
            device: device(push: .apns), origin: "https://n", onLoad: false
        )
        let after = WebAppDeviceState.buildScript(
            device: device(push: .polling), origin: "https://n", onLoad: false
        )
        XCTAssertTrue(before.contains("Apple Push Notifications"))
        XCTAssertTrue(after.contains("Polling"))
        XCTAssertNotEqual(before, after)
    }

    func testScriptIsSelfContainedAndCannotThrowIntoThePage() {
        let js = WebAppDeviceState.buildScript(
            device: device(), origin: "https://n", onLoad: true
        )
        XCTAssertTrue(js.hasPrefix("(function(){"), "not an IIFE: \(js.prefix(40))")
        XCTAssertTrue(js.contains("try{"), "no try/catch — a throw here would break the page")
    }
}
