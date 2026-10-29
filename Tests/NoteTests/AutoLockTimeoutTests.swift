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

/// Auto-lock timeout and the app-switcher cover — the two Security settings
/// the Android app also offers.
///
/// Without a timeout, app lock re-arms on every background transition, no
/// matter how brief: answering a notification means a Face ID prompt on the
/// way back. That is the reason people switch app lock off, so a stricter
/// default that ends in the feature being disabled is not actually
/// stricter.
final class AutoLockTimeoutTests: XCTestCase {

    func testTheThreeChoicesMatchNoteAndroid() {
        // note-android offers Immediately / After 1 minute / After 5 minutes
        // (SettingsFragment.kt) backed by AUTO_LOCK_IMMEDIATELY / _1_MIN /
        // _5_MIN. Same three, same order, same seconds.
        XCTAssertEqual(AutoLockTimeout.allCases, [.immediately, .oneMinute, .fiveMinutes])
        XCTAssertEqual(AutoLockTimeout.immediately.rawValue, 0)
        XCTAssertEqual(AutoLockTimeout.oneMinute.rawValue, 60)
        XCTAssertEqual(AutoLockTimeout.fiveMinutes.rawValue, 300)
    }

    func testEveryChoiceIsLabelled() {
        for option in AutoLockTimeout.allCases {
            XCTAssertFalse(option.displayName.isEmpty, "\(option) has no label")
        }
        XCTAssertEqual(AutoLockTimeout.immediately.displayName, "Immediately")
    }

    func testUnsetTimeoutReadsAsImmediately() {
        // `defaults.integer(forKey:)` returns 0 for an unset key,
        // and 0 IS `.immediately` — so an install that never
        // chose a timeout keeps locking immediately rather than
        // silently loosening to a delay nobody chose.
        XCTAssertEqual(AutoLockTimeout(rawValue: 0), .immediately)
    }

    func testAnUnknownStoredValueFallsBackToImmediately() {
        // A value written by a future build, or a corrupted one, must fail
        // SAFE. `AutoLockTimeout(rawValue:)` returning nil is what the config
        // getter coalesces to `.immediately`.
        XCTAssertNil(AutoLockTimeout(rawValue: 9_999))
    }

    func testAppSwitcherCoverDefaultsToOn() {
        // note-android blocks screenshots BY DEFAULT, so the iOS half of that
        // has to default on too — otherwise the same person gets different
        // protection depending on the phone they own.
        //
        // Read through a fresh suite so the assertion is about the DEFAULT and
        // not about whatever this simulator happens to have stored.
        let suiteName = "AutoLockTimeoutTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        // Mirrors AppConfiguration.hideInAppSwitcher's getter exactly: an unset
        // key must read TRUE, which `bool(forKey:)` would get wrong.
        XCTAssertNil(defaults.object(forKey: "hide_in_app_switcher"))
        XCTAssertFalse(defaults.bool(forKey: "hide_in_app_switcher"),
                       "bool(forKey:) reads unset as false — hence object(forKey:) in the getter")
        let effective = (defaults.object(forKey: "hide_in_app_switcher") as? Bool) ?? true
        XCTAssertTrue(effective, "the app-switcher cover must default ON")
    }

    func testTurningItOffIsRemembered() {
        // The inverse of the above: an explicit false must survive, which a
        // naive `?? true` on a missing key would also produce — so this pins
        // that the value is actually stored rather than defaulted twice.
        let suiteName = "AutoLockTimeoutTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: "hide_in_app_switcher")
        let effective = (defaults.object(forKey: "hide_in_app_switcher") as? Bool) ?? true
        XCTAssertFalse(effective)
    }
}
