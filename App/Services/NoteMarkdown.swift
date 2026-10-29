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

/// Block structure for the note preview.
///
/// WHY THIS EXISTS
///   Apple's `AttributedString(markdown:)` cannot handle block structure, and
///   it fails silently — verified against the real parser:
///
///     "- one\n- two"  →  "onetwo"     no bullets, and the line break is GONE
///     "- [ ] milk"    →  "[ ] milk"   no checkbox, literal brackets
///     "1. first"      →  "first"      the number is eaten
///
///   Handed whole runs of joined lines, a two-item list would render as
///   run-together prose, and a checklist — which the Android app draws as ☐/☑
///   and the web draws as a real `<input type=checkbox>` — as square brackets.
///   This type does the block layer, and leaves Apple's parser doing only what
///   it is good at: INLINE marks (bold, italic, strike, code, links) inside one
///   block's text.
///
///   A type of its own so it can be tested.
///
/// SCOPE
///   The block set mirrors the web editor's renderer (its `markdown.ts`),
///   which is the richest of the three clients. Two gaps are deliberate and
///   called out in the tests: callout blocks (`> [!NOTE]`) render as plain
///   quotes, and math (`$$`) is not special-cased.
enum NoteMarkdown {

    enum Block: Equatable {
        case heading(level: Int, text: String)
        case bullet(text: String)
        /// `marker` keeps the author's own numbering ("1", "2", "10") rather than
        /// renumbering — the web and Android both leave it as typed.
        case ordered(marker: String, text: String)
        case task(checked: Bool, text: String)
        /// A quote is ONE block: the opener plus its lazy-continuation lines,
        /// joined. Matches the editor, where the ">" lives only on the opener.
        case quote(text: String)
        case code(text: String)
        case divider
        /// Consecutive plain lines, joined with newlines that the renderer
        /// preserves. Joining keeps "a\nb" from rendering as "ab".
        case paragraph(text: String)
    }

    private static let heading = /^(#{1,6})[ \t]+(\S.*)$/
    private static let task = /^[ ]{0,3}[-*+][ \t]+\[([ xX])\][ \t]+(\S.*)$/
    private static let bullet = /^[ ]{0,3}[-*+][ \t]+(\S.*)$/
    private static let ordered = /^[ ]{0,3}(\d{1,9})[.)][ \t]+(\S.*)$/
    private static let divider = /^ {0,3}(-{3,}|_{3,}|\*{3,})[ \t]*$/
    /// A line that opens a new block, and therefore ends the quote above it.
    /// `>` is deliberately absent — a `>` line continues the quote.
    private static let blockStart =
        /^ {0,3}(?:[-*+][ \t].*|\d+[.)][ \t].*|#{1,6}[ \t].*|```.*|\|.*|-{3,}[ \t]*|_{3,}[ \t]*|\*{3,}[ \t]*)$/

    static func blocks(_ text: String) -> [Block] {
        var out: [Block] = []
        var paragraph: [String] = []

        func flushParagraph() {
            while let f = paragraph.first, f.trimmingCharacters(in: .whitespaces).isEmpty {
                paragraph.removeFirst()
            }
            while let l = paragraph.last, l.trimmingCharacters(in: .whitespaces).isEmpty {
                paragraph.removeLast()
            }
            if !paragraph.isEmpty { out.append(.paragraph(text: paragraph.joined(separator: "\n"))) }
            paragraph.removeAll()
        }

        let lines = text.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i]

            // Fenced code first: nothing inside it is markdown.
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                flushParagraph()
                i += 1
                var body: [String] = []
                while i < lines.count,
                      !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    body.append(lines[i])
                    i += 1
                }
                if i < lines.count { i += 1 }        // consume the closing fence
                out.append(.code(text: body.joined(separator: "\n")))
                continue
            }

            if line.hasPrefix(">") {
                flushParagraph()
                var quote: [String] = []
                // A quote block runs to the first blank line OR to the first
                // line that OPENS A NEW BLOCK.
                //
                // Taking every non-blank line instead would let a quote
                // followed by a list item swallow the item — and the styler,
                // which does not swallow it, would draw the same line as a
                // checkbox, so iOS's two renderers would disagree about the
                // same note. CommonMark,
                // Obsidian and android all start a new block here.
                while i < lines.count,
                      !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    if !quote.isEmpty && !lines[i].hasPrefix(">")
                        && lines[i].wholeMatch(of: blockStart) != nil { break }
                    var l = lines[i]
                    if l.hasPrefix("> ") { l = String(l.dropFirst(2)) }
                    else if l.hasPrefix(">") { l = String(l.dropFirst(1)) }
                    quote.append(l)
                    i += 1
                }
                out.append(.quote(text: quote.joined(separator: "\n")))
                continue
            }

            if let m = line.wholeMatch(of: divider) {
                _ = m
                flushParagraph()
                out.append(.divider)
                i += 1
                continue
            }
            if let m = line.wholeMatch(of: heading) {
                flushParagraph()
                out.append(.heading(level: m.1.count, text: String(m.2)))
                i += 1
                continue
            }
            // TASK BEFORE BULLET: a task line is also a valid bullet, and whoever
            // matches first wins. The Android app orders these the same way and
            // says why — the bullet's content "[ ] …" would otherwise swallow the
            // box.
            if let m = line.wholeMatch(of: task) {
                flushParagraph()
                let mark = String(m.1)
                out.append(.task(checked: mark == "x" || mark == "X", text: String(m.2)))
                i += 1
                continue
            }
            if let m = line.wholeMatch(of: bullet) {
                flushParagraph()
                out.append(.bullet(text: String(m.1)))
                i += 1
                continue
            }
            if let m = line.wholeMatch(of: ordered) {
                flushParagraph()
                out.append(.ordered(marker: String(m.1), text: String(m.2)))
                i += 1
                continue
            }

            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flushParagraph()
            } else {
                paragraph.append(line)
            }
            i += 1
        }
        flushParagraph()
        return out
    }
}
