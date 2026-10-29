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

/// Pins the note preview's block structure.
///
/// WHY THIS EXISTS
///   `AttributedString(markdown:)` silently does far less than a markdown
///   renderer. Handed joined lines, Apple's parser gives:
///
///     "- one\n- two"  →  "onetwo"     no bullets, and the line break GONE
///     "- [ ] milk"    →  "[ ] milk"   no checkbox, literal brackets
///     "1. first"      →  "first"      the number eaten
///
///   So the block layer belongs to `NoteMarkdown`, and Apple's parser is
///   left doing inline marks inside one block's text.
///
///   The three clients must agree on this structure.
final class NoteMarkdownTests: XCTestCase {

    // MARK: - Lists

    func testABulletListKeepsEveryItemSeparate() {
        // Apple's parser alone renders this as "onetwo".
        XCTAssertEqual(
            NoteMarkdown.blocks("- one\n- two"),
            [.bullet(text: "one"), .bullet(text: "two")])
    }

    func testEveryBulletMarkerIsAccepted() {
        for marker in ["-", "*", "+"] {
            XCTAssertEqual(
                NoteMarkdown.blocks("\(marker) item"), [.bullet(text: "item")],
                "'\(marker)' should open a bullet")
        }
    }

    func testABulletSurvivesUpToThreeSpacesOfIndentAndStopsAtFour() {
        for indent in 0...3 {
            XCTAssertEqual(
                NoteMarkdown.blocks("\(String(repeating: " ", count: indent))- item"),
                [.bullet(text: "item")],
                "indent \(indent) is still a bullet")
        }
        // Four spaces is a code indent in markdown, not a list.
        XCTAssertEqual(
            NoteMarkdown.blocks("    - item"), [.paragraph(text: "    - item")])
    }

    func testAnOrderedListKeepsTheAuthorsOwnNumbering() {
        // Not renumbered — the web and Android both leave the marker as typed.
        XCTAssertEqual(
            NoteMarkdown.blocks("3. third\n4. fourth"),
            [.ordered(marker: "3", text: "third"), .ordered(marker: "4", text: "fourth")])
    }

    func testABulletListWithBlankLinesAroundItKeepsAllThreeParts() {
        XCTAssertEqual(
            NoteMarkdown.blocks("intro\n\n- one\n- two\n\noutro"),
            [
                .paragraph(text: "intro"),
                .bullet(text: "one"),
                .bullet(text: "two"),
                .paragraph(text: "outro"),
            ])
    }

    func testAListDirectlyAgainstProseNeedsNoBlankLine() {
        XCTAssertEqual(
            NoteMarkdown.blocks("intro\n- one\noutro"),
            [.paragraph(text: "intro"), .bullet(text: "one"), .paragraph(text: "outro")])
    }

    // MARK: - Checklists

    func testAChecklistBecomesATaskWithItsState() {
        XCTAssertEqual(NoteMarkdown.blocks("- [ ] milk"), [.task(checked: false, text: "milk")])
        XCTAssertEqual(NoteMarkdown.blocks("- [x] eggs"), [.task(checked: true, text: "eggs")])
        XCTAssertEqual(NoteMarkdown.blocks("- [X] eggs"), [.task(checked: true, text: "eggs")])
    }

    func testAChecklistItemIsNeverJustABullet() {
        // Order matters: a task line is also a valid bullet, and the bullet's
        // content "[ ] …" would swallow the box. Same ordering as Android's.
        let blocks = NoteMarkdown.blocks("- [ ] milk")
        XCTAssertEqual(blocks.count, 1)
        if case .bullet = blocks[0] { XCTFail("a task must not fall through to .bullet") }
    }

    func testChecklistsAndBulletsMixInOneList() {
        XCTAssertEqual(
            NoteMarkdown.blocks("- plain\n- [ ] todo\n- [x] done"),
            [
                .bullet(text: "plain"),
                .task(checked: false, text: "todo"),
                .task(checked: true, text: "done"),
            ])
    }

    func testChecklistContentKeepsItsInlineMarkers() {
        // The block layer must not eat inline syntax — the renderer hands it to
        // AttributedString, which is what turns it into styling.
        XCTAssertEqual(
            NoteMarkdown.blocks("- [ ] buy **milk**"),
            [.task(checked: false, text: "buy **milk**")])
    }

    // MARK: - Headings

    func testEveryHeadingLevelParsesWithItsLevel() {
        for level in 1...6 {
            XCTAssertEqual(
                NoteMarkdown.blocks("\(String(repeating: "#", count: level)) Head"),
                [.heading(level: level, text: "Head")])
        }
    }

    func testAHashWithoutASpaceIsNotAHeading() {
        XCTAssertEqual(
            NoteMarkdown.blocks("#NotAHeading"), [.paragraph(text: "#NotAHeading")])
    }

    func testSevenHashesIsNotAHeading() {
        XCTAssertEqual(
            NoteMarkdown.blocks("####### too deep"), [.paragraph(text: "####### too deep")])
    }

    // MARK: - Quotes

    func testAQuoteIsOneBlockIncludingItsLazyContinuation() {
        XCTAssertEqual(
            NoteMarkdown.blocks("> first\ncontinued"),
            [.quote(text: "first\ncontinued")])
    }

    func testABlankLineEndsAQuote() {
        XCTAssertEqual(
            NoteMarkdown.blocks("> quoted\n\nafter"),
            [.quote(text: "quoted"), .paragraph(text: "after")])
    }

    func testAQuoteMarkerWithoutASpaceStillOpensAQuote() {
        XCTAssertEqual(NoteMarkdown.blocks(">tight"), [.quote(text: "tight")])
    }

    // MARK: - Fenced code

    func testAFencedBlockIsRawAndItsFencesAreDropped() {
        XCTAssertEqual(
            NoteMarkdown.blocks("```\n- not a bullet\n**not bold**\n```"),
            [.code(text: "- not a bullet\n**not bold**")])
    }

    func testAFenceWithALanguageStillOpensCode() {
        XCTAssertEqual(
            NoteMarkdown.blocks("```swift\nlet x = 1\n```"), [.code(text: "let x = 1")])
    }

    func testAnUnclosedFenceRunsToTheEndInsteadOfLosingTheText() {
        XCTAssertEqual(
            NoteMarkdown.blocks("```\nstill code"), [.code(text: "still code")])
    }

    // MARK: - Dividers and paragraphs

    func testADividerIsItsOwnBlock() {
        XCTAssertEqual(
            NoteMarkdown.blocks("above\n\n---\n\nbelow"),
            [.paragraph(text: "above"), .divider, .paragraph(text: "below")])
    }

    func testConsecutiveProseLinesStayOneBlockWithTheirBreaks() {
        // The other half of "onetwo": the joined text must keep its
        // newlines so the renderer's preserveBreaks has something to
        // preserve.
        XCTAssertEqual(
            NoteMarkdown.blocks("line one\nline two"),
            [.paragraph(text: "line one\nline two")])
    }

    func testSurroundingBlankLinesAreTrimmedNotRendered() {
        XCTAssertEqual(NoteMarkdown.blocks("\n\n  \nbody\n\n"), [.paragraph(text: "body")])
    }

    func testAnEmptyBodyProducesNoBlocks() {
        XCTAssertTrue(NoteMarkdown.blocks("").isEmpty)
        XCTAssertTrue(NoteMarkdown.blocks("\n\n").isEmpty)
    }

    // MARK: - Known gaps, pinned deliberately

    func testACalloutRendersAsAPlainQuote() {
        // The web renders `> [!NOTE]` as a themed callout; iOS does not. Pinned so
        // the difference is a decision on record rather than a surprise.
        XCTAssertEqual(
            NoteMarkdown.blocks("> [!NOTE] Heads up"),
            [.quote(text: "[!NOTE] Heads up")])
    }

    func testAMathBlockIsNotSpecialCased() {
        // The web renders `$$…$$` through KaTeX; here it is prose.
        XCTAssertEqual(
            NoteMarkdown.blocks("$$\nx^2\n$$"), [.paragraph(text: "$$\nx^2\n$$")])
    }
}
