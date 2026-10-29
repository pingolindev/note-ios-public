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

/// The User-Agent is how the server names a session's device, so its SHAPE
/// is a wire contract with the server's device-model parser, not a cosmetic
/// string.
///
/// Two parts of it matter. The prefix must be one the parser accepts — and
/// `PingolinNote/` is not a prefix of `PingolinNote-iOS/` — or every session
/// is stored as "Unknown Device". And the `(...)` comment is read as the
/// device model, so a build number there, as in `PingolinNote-iOS/1.0.0 (1)`,
/// would name every session "1".
final class UserAgentShapeTests: XCTestCase {

    private var ua: String { AppConfiguration.shared.userAgent }

    /// The prefix auth matches on. Must be one of "Track/", "Note/",
    /// "PingolinTrack/", "PingolinNote/" — and a hyphenated variant is not one.
    func testPrefixIsOneTheParserAccepts() {
        let accepted = ["Track/", "Note/", "PingolinTrack/", "PingolinNote/"]
        XCTAssertTrue(accepted.contains { ua.hasPrefix($0) }, "unmatched prefix in: \(ua)")
        XCTAssertTrue(ua.hasPrefix("Note/"), "this app identifies as Note/: \(ua)")
        XCTAssertFalse(ua.hasPrefix("PingolinNote-iOS/"),
                       "PingolinNote-iOS/ is not a prefix the parser accepts")
    }

    /// `Note/<ver> (<model>; iOS <release>) urlsession`.
    func testFullShapeMatchesTheContract() {
        let pattern = #"^Note/[0-9][0-9A-Za-z._-]* \([A-Za-z0-9 ._-]+; iOS [0-9][0-9.]*\) urlsession$"#
        XCTAssertNotNil(ua.range(of: pattern, options: .regularExpression),
                        "UA does not match the contract: \(ua)")
    }

    /// The comment is the device model. The server would store a bare
    /// build number there as the device's name, so an all-digits comment
    /// is what this guards against.
    func testTheModelCommentIsNotABuildNumber() {
        guard let open = ua.firstIndex(of: "("), let close = ua.firstIndex(of: ")") else {
            return XCTFail("no (...) comment in: \(ua)")
        }
        let comment = String(ua[ua.index(after: open)..<close])
        let model = comment.split(separator: ";").first.map(String.init) ?? comment
        XCTAssertFalse(model.allSatisfy(\.isNumber),
                       "the model comment is all digits — the server would name the device after the build number: \(ua)")
        XCTAssertFalse(model.isEmpty)
    }

    /// Nothing in the string may break the header or the parser: no control
    /// characters, no stray parentheses, and a bounded model token.
    func testTokenIsSafeForAHeader() {
        XCTAssertFalse(ua.contains(where: { $0.isNewline }))
        XCTAssertEqual(ua.filter { $0 == "(" }.count, 1)
        XCTAssertEqual(ua.filter { $0 == ")" }.count, 1)
        let model = ua.split(separator: "(")[1].split(separator: ";")[0]
        XCTAssertLessThanOrEqual(model.count, 60)
    }

    /// The build number is not in the UA, so prove it is still
    /// reachable — Settings renders "<version> (<build>)" from these
    /// two.
    func testVersionAndBuildAreStillAvailableToTheUI() {
        XCTAssertFalse(AppConfiguration.shared.appVersion.isEmpty)
        XCTAssertFalse(AppConfiguration.shared.buildNumber.isEmpty)
    }
}
