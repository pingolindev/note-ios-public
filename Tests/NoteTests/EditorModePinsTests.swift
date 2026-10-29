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

/// The pin/un-pin rule, which is the whole of this feature that can be wrong
/// quietly. Mirrors the web's `editorModeOverrides.test.ts` and android's
/// `EditorModePinsTest.kt` case for case — the map is ONE blob shared by three
/// clients, so a disagreement about what a key means is a user watching a note
/// change mode when they open it elsewhere.
final class EditorModePinsTests: XCTestCase {

    private let a = "note-a"
    private let b = "note-b"

    // MARK: - resolve

    func testFallsBackToGlobalWithNoPin() {
        XCTAssertEqual(EditorModePins.resolve([:], noteId: a, global: "preview"), "preview")
    }

    func testPrefersThePin() {
        XCTAssertEqual(EditorModePins.resolve([a: "markdown"], noteId: a, global: "preview"), "markdown")
    }

    func testAPinAppliesOnlyToItsOwnNote() {
        XCTAssertEqual(EditorModePins.resolve([a: "markdown"], noteId: b, global: "preview"), "preview")
    }

    func testUsesGlobalForANoteWithNoIdYet() {
        // A note being composed has no server id to key a pin on.
        XCTAssertEqual(EditorModePins.resolve([a: "markdown"], noteId: nil, global: "hybrid"), "hybrid")
    }

    // MARK: - withMode

    func testPinsWhenTheModeDiffersFromTheGlobal() {
        XCTAssertEqual(EditorModePins.withMode([:], noteId: a, mode: "markdown", global: "preview"),
                       [a: "markdown"])
    }

    func testUnPinsWhenTheModeIsTheGlobal() {
        XCTAssertEqual(
            EditorModePins.withMode([a: "markdown"], noteId: a, mode: "preview", global: "preview"),
            [:])
    }

    func testChangesAnExistingPinInPlace() {
        XCTAssertEqual(
            EditorModePins.withMode([a: "markdown"], noteId: a, mode: "hybrid", global: "preview"),
            [a: "hybrid"])
    }

    func testLeavesOtherNotesAlone() {
        XCTAssertEqual(
            EditorModePins.withMode([a: "markdown", b: "hybrid"], noteId: a, mode: "preview", global: "preview"),
            [b: "hybrid"])
    }

    func testReturnsNilWhenNothingChangedSoNoNeedlessWrite() {
        // The map shares a blob with notebooks and label colours; saving an
        // identical one would bump its version and race another device free.
        XCTAssertNil(EditorModePins.withMode([a: "markdown"], noteId: a, mode: "markdown", global: "preview"))
        XCTAssertNil(EditorModePins.withMode([:], noteId: a, mode: "preview", global: "preview"))
    }

    func testAPinSurvivesTheGlobalMovingToMatchIt() {
        // Pin A to markdown, then make markdown the global. The pin is now
        // invisible, but it is still the user's explicit choice for that note,
        // so moving the global away again must bring it back.
        let pins = EditorModePins.withMode([:], noteId: a, mode: "markdown", global: "preview")!
        XCTAssertEqual(EditorModePins.resolve(pins, noteId: a, global: "markdown"), "markdown")
        XCTAssertEqual(EditorModePins.resolve(pins, noteId: a, global: "hybrid"), "markdown")
    }

    // MARK: - isPinned

    func testPinnedOnlyWhenItDiffersFromTheCurrentGlobal() {
        XCTAssertTrue(EditorModePins.isPinned([a: "markdown"], noteId: a, global: "preview"))
        XCTAssertFalse(EditorModePins.isPinned([:], noteId: a, global: "preview"))
        XCTAssertFalse(EditorModePins.isPinned([a: "markdown"], noteId: a, global: "markdown"))
        XCTAssertFalse(EditorModePins.isPinned([a: "markdown"], noteId: nil, global: "preview"))
    }

    // MARK: - gc

    func testDropsPinsForNotesThatNoLongerExist() {
        XCTAssertEqual(EditorModePins.gc([a: "markdown", b: "hybrid"], liveIds: [a]), [a: "markdown"])
    }

    func testKeepsEverythingWhenEveryNoteIsLive() {
        XCTAssertNil(EditorModePins.gc([a: "markdown", b: "hybrid"], liveIds: [a, b]))
    }

    func testNothingToCollect() {
        XCTAssertNil(EditorModePins.gc([:], liveIds: []))
    }

    func testCollectsEverythingWhenNoNotesAreLive() {
        XCTAssertEqual(EditorModePins.gc([a: "markdown"], liveIds: []), [:])
    }

    // MARK: - sanitize

    func testKeepsKnownModes() {
        XCTAssertEqual(EditorModePins.sanitize([a: "markdown", b: "preview"]),
                       [a: "markdown", b: "preview"])
    }

    func testDropsValuesThatAreNotModes() {
        XCTAssertEqual(EditorModePins.sanitize([a: "zoomed", b: 42, "c": NSNull()]), [:])
    }

    func testSurvivesAMissingOrBrokenMap() {
        XCTAssertEqual(EditorModePins.sanitize(nil), [:])
        XCTAssertEqual(EditorModePins.sanitize("nope"), [:])
        XCTAssertEqual(EditorModePins.sanitize([1, 2, 3]), [:])
    }
}

/// Unknown keys in the shared metadata blob must survive this client's saves.
///
/// One blob per user, every client rewrites all of it — so a `Codable` struct
/// that emits only its own properties DELETES whatever a newer client wrote,
/// silently, on the next notebook rename. android is safe because it mutates
/// a parsed JSON object in place; a `Codable` struct is not.
final class MetadataExtrasTests: XCTestCase {

    func testKeepsAFieldThisBuildHasNeverHeardOf() {
        XCTAssertEqual(
            NotebookMetadataStore.extrasFrom(["notebooks": [], "somethingNewer": 1]).keys.sorted(),
            ["somethingNewer"])
    }

    func testDoesNotEchoBackFieldsWeModel() {
        // They are re-derived from the struct; echoing them would let a stale
        // copy win over the encoder's.
        let raw: [String: Any] = [
            "notebooks": [], "labelColors": [:], "notebookShares": [:], "editorModes": [:],
        ]
        XCTAssertTrue(NotebookMetadataStore.extrasFrom(raw).isEmpty)
    }

    func testPreservesFalsyValuesRatherThanDroppingThem() {
        // The case a naive truthiness guard drops. A newer client's `false`,
        // `0`, `null` or `""` is data, and losing it is the same data loss as
        // losing the key — just harder to notice.
        let raw: [String: Any] = [
            "flagOff": false, "count": 0, "blank": "", "absent": NSNull(),
        ]
        let extras = NotebookMetadataStore.extrasFrom(raw)
        XCTAssertEqual(extras.count, 4)
        XCTAssertEqual(extras["flagOff"] as? Bool, false)
        XCTAssertEqual(extras["count"] as? Int, 0)
        XCTAssertEqual(extras["blank"] as? String, "")
        XCTAssertTrue(extras["absent"] is NSNull)
    }
}
