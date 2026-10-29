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

/// Where a backslash goes to stop a typed block marker becoming markup.
///
/// A free function with no UIKit dependency so it can be tested directly —
/// the positional rule below IS the correctness argument for the whole
/// "Interpret markdown: off" feature, so it needs to be cheap to test.
///
/// Kept in step with the web editor's `blockEscape.ts` and the Android app's
/// `BlockEscape.kt`: the same note typed on any of the three has to come out
/// with the same bytes.
///
/// INLINE MARKS ARE DELIBERATELY ABSENT. `*emphasis*` becoming italic is
/// behaviour people who don't write markdown still tend to want, and escaping
/// every `*` would litter a note with backslashes for a `2 * 3`.
enum BlockEscape {

    /// (pattern, which capture group's end marks the escape point).
    /// Group 1 is always the leading indent where a rule allows one, so the
    /// backslash lands on the marker rather than in front of the whitespace.
    private static let rules: [(NSRegularExpression, (NSTextCheckingResult) -> Int)] = [
        // `# ` … `###### ` — escape the first hash.
        (re("^(#{1,6}) "), { _ in 0 }),
        // `- `, `* `, `+ ` — escape the marker, not the indent.
        (re("^( {0,3})([-*+]) "), { m in m.range(at: 1).length }),
        // `1. ` / `1) ` — CommonMark escapes the DELIMITER, not the digits.
        (re("^( {0,3})([0-9]{1,9})([.)]) "), { m in m.range(at: 1).length + m.range(at: 2).length }),
        // `> ` — escape the angle bracket.
        (re("^( {0,3})> "), { m in m.range(at: 1).length }),
        // A thematic break: three or more of - _ * alone on the line.
        (re("^( {0,3})(-{3,}|_{3,}|\\*{3,})[ \t]*$"), { m in m.range(at: 1).length }),
        // A fence.
        (re("^( {0,3})(```|~~~)"), { m in m.range(at: 1).length }),
    ]

    private static func re(_ p: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p)
    }

    /// The offset within `line` that needs a backslash, or nil if none does.
    static func offset(in line: String) -> Int? {
        let ns = line as NSString
        let full = NSRange(location: 0, length: ns.length)
        for (regex, at) in rules {
            if let m = regex.firstMatch(in: line, range: full) { return at(m) }
        }
        return nil
    }
}
