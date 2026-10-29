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

/// Which typed characters get a backslash when "Interpret markdown" is off.
///
/// The rule that matters is POSITIONAL: a marker is escaped only where it
/// would actually create a block. Escaping on sight turns "C# is a language"
/// into "C\# is a language" — wrong, and visible as noise in the other two
/// modes, which show raw source.
///
/// Offsets are asserted rather than a boolean, because CommonMark escapes a
/// specific character: `1\. ` and not `\1. `. Mirrors the web's
/// blockEscape.test.ts and android's BlockEscapeTest case for case — the same
/// note typed on any client has to come out with the same bytes.
final class BlockEscapeTests: XCTestCase {

    private func at(_ line: String) -> Int? { BlockEscape.offset(in: line) }

    func testEscapesWhereABlockWouldForm() {
        XCTAssertEqual(at("# H"), 0)
        XCTAssertEqual(at("###### H"), 0)
        XCTAssertEqual(at("- x"), 0)
        XCTAssertEqual(at("* x"), 0)
        XCTAssertEqual(at("+ x"), 0)
        XCTAssertEqual(at("> x"), 0)
        XCTAssertEqual(at("```"), 0)
        XCTAssertEqual(at("~~~"), 0)
    }

    func testIndentedBulletEscapesTheMarkerNotTheIndent() {
        XCTAssertEqual(at("   - x"), 3)
    }

    func testOrderedItemEscapesTheDelimiter() {
        // CommonMark escapes `1\. `, not `\1. `.
        XCTAssertEqual(at("1. x"), 1)
        XCTAssertEqual(at("10) x"), 2)
    }

    func testThematicBreakOfAnyOfTheThreeCharacters() {
        XCTAssertEqual(at("---"), 0)
        XCTAssertEqual(at("___"), 0)
        XCTAssertEqual(at("***"), 0)
        XCTAssertEqual(at("----"), 0)
    }

    func testLeavesAloneWhatWouldNotFormABlock() {
        XCTAssertNil(at("C# is a language"))
        XCTAssertNil(at("issue #42"))
        XCTAssertNil(at("#hashtag"))
        XCTAssertNil(at("-"))
        XCTAssertNil(at("--"))
        XCTAssertNil(at("-notalist"))
        XCTAssertNil(at("2 * 3 = 6"))
        XCTAssertNil(at("a > b"))
        XCTAssertNil(at("e.g. 1. one"))
        XCTAssertNil(at(""))
    }

    func testInlineMarksAreNeverEscaped() {
        // `*emphasis*` becoming italic is behaviour people who do not write
        // markdown still want, and escaping every `*` would litter a note.
        XCTAssertNil(at("some *emphasis* here"))
        XCTAssertNil(at("__bold__ and `code`"))
    }
}
