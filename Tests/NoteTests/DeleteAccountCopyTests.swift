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

/// Deleting the Pingolin account from Note deletes the circles it owns in
/// Track, for everyone in them, with their history: Track's account
/// deletion destroys owned circles outright, for whichever app asked.
/// Every delete screen says so before the button, in the same words.
final class DeleteAccountCopyTests: XCTestCase {

    func testTheSheetSaysOwnedCirclesGoForEveryoneInThem() throws {
        XCTAssertEqual(DeleteAccountSheet.ownedCirclesText,
                       "Circles you own in Pingolin Track are deleted for everyone in them, along with all the "
                       + "location history they hold. To keep a circle going, transfer its ownership in Track first.")
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let settings = try String(contentsOf: root.appendingPathComponent("App/Views/SettingsView.swift"),
                                  encoding: .utf8)
        // Right under what Note itself deletes, ahead of the password and the button.
        XCTAssertTrue(settings.contains("""
                        Text("Deleting your account permanently removes your notes, notebooks, attachments, shares and reminders. This cannot be undone.")
                            .font(.subheadline)
                        Text(Self.ownedCirclesText)
                            .font(.subheadline)
        """))
    }
}
