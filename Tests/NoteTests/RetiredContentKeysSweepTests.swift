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

/// The retired content keys an earlier version kept in UserDefaults leave the
/// device: every spelling of every account's, at sign-out and at a launch that
/// restores a session. Nothing else is touched.
final class RetiredContentKeysSweepTests: XCTestCase {

    private let me = "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"

    func testTheSweepRemovesEverySpellingAndNothingElse() throws {
        let suite = "RetiredContentKeysSweepTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let retired = [
            "note_retired_content_keys",
            "note_retired_content_keys.\(me)",
            "note_retired_content_keys.\(me.uppercased())",
            "note_retired_content_keys.urn:uuid:\(me)",
            "note_retired_content_keys.1a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d",
        ]
        for key in retired {
            defaults.set(Data("wrapped".utf8), forKey: key)
        }
        defaults.set(Data("{}".utf8), forKey: "note_sender_pins.\(me)")
        defaults.set(["i": 2], forKey: "note_gen_floor.\(me)")

        AuthManager.dropRetiredContentKeys(from: defaults)

        for key in retired {
            XCTAssertNil(defaults.object(forKey: key), key)
        }
        XCTAssertNotNil(defaults.object(forKey: "note_sender_pins.\(me)"), "another store's key stays")
        XCTAssertNotNil(defaults.object(forKey: "note_gen_floor.\(me)"), "another store's key stays")
    }

    /// It runs where the store's reset ran at sign-out, and at a launch that
    /// restores a session, after the Keychain read that proves UserDefaults
    /// can be read.
    func testItRunsAtSignOutAndAtLaunch() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let auth = try String(contentsOf: root.appendingPathComponent("App/Managers/AuthManager.swift"), encoding: .utf8)
        let cleanup = try XCTUnwrap(auth.range(of: "    private func switchAccountCleanup() async {\n"))
        let cleanupEnd = try XCTUnwrap(auth.range(of: "\n    }\n", range: cleanup.upperBound..<auth.endIndex))
        XCTAssertTrue(auth[cleanup.upperBound..<cleanupEnd.lowerBound].contains("Self.dropRetiredContentKeys()"))
        let launch = try XCTUnwrap(auth.range(of: "        if case .id = storedAccount {\n"))
        let launchEnd = try XCTUnwrap(auth.range(of: "\n        }\n", range: launch.upperBound..<auth.endIndex))
        XCTAssertTrue(auth[launch.upperBound..<launchEnd.lowerBound].contains("Self.dropRetiredContentKeys()"))
    }
}
