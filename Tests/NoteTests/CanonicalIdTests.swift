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

/// An id as this app keeps it: a UUID's bytes, lower-case, hyphenated.
/// The same cases as the Android app's AccountIdsTest.
final class CanonicalIdTests: XCTestCase {

    private let canonical = "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"
    private var hex: String { canonical.replacingOccurrences(of: "-", with: "") }

    /// Every spelling the SDK's parser (uuid 1.x) takes.
    private var spellings: [String] {
        [canonical, canonical.uppercased(), "0A1b2C3d-4E5f-4A6b-8C7d-9E0f1A2b3C4d",
         hex, hex.uppercased(),
         "{\(canonical)}", "{\(canonical.uppercased())}",
         "urn:uuid:\(canonical)", "urn:uuid:\(canonical.uppercased())"]
    }

    /// No UUID in any spelling the SDK takes.
    private var others: [String?] {
        [nil, "", "me", "user-dana",
         " \(canonical)", "\(canonical) ", "\(canonical)\n", "\t\(canonical)",
         canonical.replacingOccurrences(of: "-", with: "_"), String(canonical.dropLast()), canonical + "0",
         canonical.replacingOccurrences(of: "4e5f", with: "4e5g"),
         "0a1b2c3d4e5f-4a6b-8c7d-9e0f1a2b3c4d", "0a1b2c3d-4e5f4a6b-8c7d-9e0f1a2b3c4d", hex + "0",
         "0a1b2c3-d4e5f-4a6b-8c7d-9e0f1a2b3c4d",
         "{\(hex)}", "{\(canonical)", "\(canonical)}", "[\(canonical)]", "{ \(canonical)}", "{{\(canonical)}}",
         "URN:UUID:\(canonical)", "Urn:Uuid:\(canonical)", "urn:uuid:\(hex)", "urn:uuid:{\(canonical)}",
         "urn:uuid: \(canonical)", "uuid:\(canonical)",
         // Digits that aren't ASCII: Arabic-Indic zero and a fullwidth one.
         canonical.replacingOccurrences(of: "0a1b", with: "\u{0660}a1b"),
         canonical.replacingOccurrences(of: "9e0f1a2b3c4d", with: "9e0f\u{FF11}a2b3c4d")]
    }

    func testEverySpellingTheSDKTakesIsItsCanonicalForm() {
        for spelling in spellings {
            XCTAssertEqual(CanonicalId.of(spelling), canonical, spelling)
        }
    }

    func testAnythingElseIsNoId() {
        for other in others {
            XCTAssertNil(CanonicalId.of(other), String(describing: other))
        }
    }

    func testTheNarrowerRuleTakesOnlyTheHyphenatedForm() {
        for spelling in spellings.prefix(3) {
            XCTAssertEqual(CanonicalId.strict(spelling), canonical, spelling)
        }
        for other in Array(spellings.dropFirst(3)).map(Optional.some) + others {
            XCTAssertNil(CanonicalId.strict(other), String(describing: other))
        }
    }

    func testTwoSpellingsAreTheSameIdOnlyWithTheSameBytes() {
        XCTAssertTrue(CanonicalId.same(canonical.uppercased(), hex))
        XCTAssertTrue(CanonicalId.same("{\(canonical)}", "urn:uuid:\(canonical.uppercased())"))
        XCTAssertFalse(CanonicalId.same(canonical, "1a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"))
        XCTAssertFalse(CanonicalId.same("me", "me"), "no id is nobody's")
        XCTAssertFalse(CanonicalId.same(nil, canonical))
        XCTAssertFalse(CanonicalId.same(canonical, nil))
    }
}
