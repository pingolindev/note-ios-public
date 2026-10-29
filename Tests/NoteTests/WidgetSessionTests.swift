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

/// No widget, and no widget picker, reads a note while signed out, and the flag the
/// widgets read follows the session from AuthManager, the one place every path that
/// starts or ends one goes through (a 401's expireSession included). The Android app
/// applies the same rule.
///
/// The widget extension isn't in this test host; its three sites go through
/// SharedAppGroup.widgetState (Shared/, which is), and a scan pins that they do.
final class WidgetSessionTests: XCTestCase {

    private let snapshot = [
        NoteSnapshotEntry(id: "n1", title: "Groceries", updatedAt: Date(timeIntervalSince1970: 0), isPinned: false),
    ]

    func testSignedOutTheSnapshotIsNeverRead() {
        var reads = 0
        let state = SharedAppGroup.widgetState(signedIn: { false }, snapshot: { reads += 1; return self.snapshot })

        XCTAssertFalse(state.isSignedIn)
        XCTAssertTrue(state.notes.isEmpty, "signed out, no note reaches a widget")
        XCTAssertEqual(reads, 0, "signed out, the snapshot isn't read at all")
    }

    func testSignedInTheWidgetsReadTheSnapshot() {
        var reads = 0
        let state = SharedAppGroup.widgetState(signedIn: { true }, snapshot: { reads += 1; return self.snapshot })

        XCTAssertTrue(state.isSignedIn)
        XCTAssertEqual(state.notes.map(\.id), ["n1"])
        XCTAssertEqual(reads, 1)
    }

    func testTheFlagIsReadOnce() {
        var flagReads = 0
        _ = SharedAppGroup.widgetState(signedIn: { flagReads += 1; return true }, snapshot: { [] })
        XCTAssertEqual(flagReads, 1, "one read, so the flag and the notes can't disagree")
    }

    @MainActor
    func testTheSessionPublishesTheFlag() {
        let before = SharedAppGroup.isSignedIn
        defer { SharedAppGroup.isSignedIn = before }

        AuthManager.publishSignedIn(true)
        XCTAssertTrue(SharedAppGroup.isSignedIn)
        AuthManager.publishSignedIn(false)
        XCTAssertFalse(SharedAppGroup.isSignedIn)
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// Every widget site reads through widgetState, and AuthManager publishes the flag.
    func testEveryWidgetSiteAsksTheSession() throws {
        let list = try source("NoteWidgets/NotesListWidget.swift")
        XCTAssertTrue(list.contains("let state = SharedAppGroup.widgetState()"), "the list's entry")
        XCTAssertTrue(list.contains("if !entry.isSignedIn || entry.entries.isEmpty {"), "the list's view")
        XCTAssertFalse(list.contains("SharedAppGroup.readSnapshot()"))

        let single = try source("NoteWidgets/SingleNoteWidget.swift")
        XCTAssertTrue(single.contains(
            "        let state = SharedAppGroup.widgetState()\n" +
                "        guard state.isSignedIn else {\n" +
                "            return SingleNoteEntry(date: Date(), note: nil, needsConfiguration: false, isSignedIn: false)\n" +
                "        }\n"
        ), "the single note's entry, before any read")
        XCTAssertTrue(single.contains("        if !entry.isSignedIn {\n"), "the single note's view, first")
        XCTAssertFalse(single.contains("SharedAppGroup.readSnapshot()"))

        let picker = try source("NoteWidgets/SingleNoteIntent.swift")
        XCTAssertEqual(picker.components(separatedBy: "SharedAppGroup.widgetState().notes").count - 1, 2, "both picker queries")
        XCTAssertFalse(picker.contains("SharedAppGroup.readSnapshot()"))

        let auth = try source("App/Managers/AuthManager.swift")
        // Every set, not only a change: a launch that finds no session sets
        // false over the initial false, and still clears a flag left true.
        XCTAssertTrue(auth.contains("        didSet { Self.publishSignedIn(isAuthenticated) }\n"),
                      "every set of the session publishes the flag")
        XCTAssertTrue(auth.contains(
            "    static func publishSignedIn(_ signedIn: Bool) {\n" +
                "        SharedAppGroup.isSignedIn = signedIn\n" +
                "        WidgetCenter.shared.reloadAllTimelines()\n" +
                "    }\n"
        ))
    }
}
