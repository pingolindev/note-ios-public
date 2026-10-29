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

import Foundation

/// The device-local settings snapshot handed to the web Settings panel.
///
/// A port of note-android's `WebAppDeviceState`, deliberately close to it: the
/// page reads one shape (`window.__pingolinDevice`) and must not be able to
/// tell the two shells apart.
///
/// ## Why the page needs this at all
///
/// App lock, push transport and notification detail cannot live inside the
/// page — they need the Keychain, LocalAuthentication and the APNs registrar.
/// So they live on the native settings screen, and the panel shows them as
/// real rows with their values, not one "App settings" button that says
/// nothing about what is behind it. That takes the whole contract:
/// `__pingolinShellSettings` without `__pingolinDevice` silently sends the
/// panel down its fallback branch.
///
/// ## What this must never become
///
/// A **push, never a pull**. No `WKScriptMessageHandler` is added for it, so
/// the page has nothing to call; the shell writes the object and returns,
/// behind the same single-origin guard every injected script here uses — the
/// account portal and every other origin the WebView visits never receive it.
///
/// It is also **read-only state, never a control surface**. Every write still
/// happens on the native screen behind the biometric prompt it already uses.
/// That matters because `decidePolicyFor` fires for ANY origin loaded in this
/// WebView, so a scheme that could switch app lock off would be a capability
/// handed to every page the WebView ever shows. The deep link can only ever
/// OPEN a screen.
///
/// Values are display-ready strings built here rather than in the page: the
/// page has no business knowing what `.apns` means, and duplicating the
/// mapping in TypeScript is how the two drift apart.
enum WebAppDeviceState {

    /// Section ids the page may deep-link to; mirrored by `SettingsView`.
    /// The same FIVE strings note-android uses — the page is shared, so these
    /// are a cross-platform contract, not an iOS detail.
    static let sectionSecurity = "security"
    static let sectionNotifications = "notifications"
    static let sectionDiagnostics = "diagnostics"
    /// Version and build. Separate from `diagnostics` rather than folded into
    /// it: they are different questions ("what am I running" vs "what is
    /// wrong"), and the sheet has to be able to title each correctly.
    static let sectionAbout = "about"
    /// Account-wide actions — deletion. The ONLY section id the page itself
    /// interprets: the page's Settings panel filters `section === 'account'`
    /// out of the Device list and renders it under the page's Account heading
    /// instead, because "delete your account" under "These are set on this
    /// device" would be describing app-lock preferences. So this string is a
    /// real contract with the page, not just with the other shell.
    ///
    /// WHERE THE ROW APPEARS depends on the deployed page, and BOTH placements
    /// are expected — do not "fix" either from this side:
    ///  - page WITH that filter: under the panel's Account heading. Correct.
    ///  - page WITHOUT it: under Device, above "These are set on this
    ///    device." Wrong group, but still reachable, which beats the row not
    ///    existing at all.
    /// The shell cannot influence the choice beyond this string, so an Account
    /// row under Device means the page has not caught up, not that this is
    /// wrong.
    static let sectionAccount = "account"

    /// The device values, lifted off configuration so the snapshot itself is
    /// pure. Same reason Android does it: a builder that takes a live manager
    /// can only be tested with a mock, which tests the mock.
    struct Device {
        let pushMode: PushDeliveryMode
        let appLockEnabled: Bool
        /// Display-ready "version (build)". Carried here rather than read in
        /// `snapshot` so the snapshot stays pure and testable.
        let appVersion: String
    }

    static func from(_ config: AppConfiguration) -> Device {
        Device(
            pushMode: config.pushDeliveryMode,
            appLockEnabled: config.appLockEnabled,
            appVersion: "\(config.appVersion) (\(config.buildNumber))"
        )
    }

    /// The snapshot itself — pure, so the unit test reads it directly.
    static func snapshot(_ device: Device) -> [String: Any] {
        let push: String
        switch device.pushMode {
        case .apns: push = "Apple Push Notifications"
        case .polling: push = "Polling"
        }

        // rows: [{id, label, value, section}] — the page renders them in this
        // order and interprets exactly one thing: `section === 'account'`,
        // which it pulls out of the Device list. Every other section id it
        // echoes straight back to the shell.
        //
        // Security carries NO value, matching Android: a summary like
        // "Face ID · Device integrity" describes a group rather than one
        // setting, and reads as noise next to a row like
        // "Push delivery · Apple Push Notifications" that names one thing.
        //
        // Notification detail is deliberately NOT a row: it sits inside the
        // screen Push delivery opens, so listing it separately would give the
        // panel two rows leading to the same place.
        //
        // The last three rows are what makes those sections reachable. The page
        // always calls `openDeviceSettings(r.section)` with a section, and its
        // no-section fallback renders only when there are no rows at all — so
        // `focus` is never nil on a working shell. Without these rows,
        // everything SettingsView gates on `focus == nil` or on
        // `shows(sectionDiagnostics)` could only be opened from the offline
        // retry view: the app version and build (the first thing any support
        // conversation asks for), the device id, and Delete Account — including
        // its warning that an App Store subscription must be cancelled by the
        // customer, which exists nowhere else.
        //
        // The About row carries the version as its VALUE so the panel shows it
        // inline, which answers the common case without opening anything. The
        // other two carry none: a summary describes a GROUP rather than one
        // setting, which is the same call the Security row already makes.
        //
        // `account` is the one id the PAGE reads rather than echoes — see
        // sectionAccount. Sending account deletion under any other section
        // renders it beneath "These are set on this device", which is wrong
        // about what the button does.
        // Five rows, matching the Android app's `WebAppDeviceState` contract
        // exactly. Only the VALUES differ, because only the values are platform
        // facts.
        let rows: [[String: String]] = [
            row(id: "security", label: "Security", value: "", section: sectionSecurity),
            row(id: "push", label: "Push delivery", value: push, section: sectionNotifications),
            row(id: "about", label: "About", value: device.appVersion, section: sectionAbout),
            row(id: "diagnostics", label: "Diagnostics", value: "", section: sectionDiagnostics),
            row(id: "account", label: "Account", value: "", section: sectionAccount),
        ]

        return [
            "platform": "ios",
            "rows": rows,
            "sections": [
                "security": sectionSecurity,
                "notifications": sectionNotifications,
                "diagnostics": sectionDiagnostics,
                "about": sectionAbout,
                "account": sectionAccount,
            ],
        ]
    }

    /// The JS that assigns `window.__pingolinDevice`.
    ///
    /// - Parameter onLoad: true for the document-start registration (assign
    ///   only), false for the in-place foreground refresh, which also fires
    ///   `pingolin-device-changed` so an open Settings panel re-reads a value
    ///   the person just changed natively.
    ///
    /// The origin guard is the FIRST statement, as every injected script here
    /// must be: the document-start path goes through a `WKUserScript` on this
    /// shell's own content controller, but the refresh path goes through
    /// `evaluateJavaScript`, which has no allowlist of its own.
    static func buildScript(device: Device, origin: String, onLoad: Bool) -> String {
        let json = jsonString(snapshot(device))
        let notify = onLoad
            ? ""
            : "window.dispatchEvent(new CustomEvent('pingolin-device-changed'));"
        return "(function(){try{if(location.origin!==\(quote(origin)))return;"
            + "window.__pingolinDevice=\(json);\(notify)}catch(e){}})();"
    }

    // MARK: - Encoding

    private static func row(id: String, label: String, value: String, section: String)
        -> [String: String] {
        ["id": id, "label": label, "value": value, "section": section]
    }

    /// Serialised with `JSONSerialization` and `.sortedKeys` so the output is
    /// deterministic — an assertion on a whole snapshot string is otherwise at
    /// the mercy of dictionary ordering.
    static func jsonString(_ object: [String: Any]) -> String {
        guard
            let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        else {
            // A snapshot that cannot encode must not take the page down with
            // it: an empty rows array puts the panel back on its fallback
            // button.
            return #"{"platform":"ios","rows":[]}"#
        }
        return text
    }

    /// JS string literal. `JSONSerialization` on a bare string would need
    /// `.fragmentsAllowed`; this is the same escaping Android's `quote` does.
    /// Also used by `IdentityRecheck.pageEventScript`.
    static func quote(_ value: String) -> String {
        var out = "\""
        for character in value.unicodeScalars {
            switch character {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            default:
                if character.value < 0x20 {
                    out += String(format: "\\u%04x", character.value)
                } else {
                    out.unicodeScalars.append(character)
                }
            }
        }
        return out + "\""
    }
}
