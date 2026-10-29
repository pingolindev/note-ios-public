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

/// The notices are a licence obligation, not decoration: a build that stops
/// bundling either inventory fails here instead of shipping an empty page.
final class OpenSourceLicensesTests: XCTestCase {
    func testBothInventoriesShipInTheAppBundle() throws {
        for inventory in OpenSourceLicensesView.inventories {
            let text = try XCTUnwrap(OpenSourceLicensesView.bundledText(inventory.resource),
                                     "\(inventory.resource).md is not in the app bundle")
            XCTAssertGreaterThan(text.count, 1_000, inventory.resource)
        }
    }

    func testEachInventoryIsTheOneItsTitleNames() throws {
        let app = try XCTUnwrap(OpenSourceLicensesView.bundledText("THIRD_PARTY_LICENSES"))
        XCTAssertTrue(app.contains("GRDB"), "this app's own inventory")
        XCTAssertTrue(app.contains("GNU General Public License"), "it names the app's licence")
        let sdk = try XCTUnwrap(OpenSourceLicensesView.bundledText("THIRD_PARTY_LICENSES-mobile-sdk"))
        XCTAssertTrue(sdk.contains("MIT License"), "the SDK's Rust crates")
        XCTAssertFalse(sdk.contains("GRDB"), "not a second copy of the app's inventory")
    }

    func testSourceCodeLinkIsThePublicRepository() {
        XCTAssertEqual(OpenSourceLicensesView.sourceCode.absoluteString,
                       "https://github.com/pingolindev/note-ios-public")
        XCTAssertEqual(OpenSourceLicensesView.editorSourceCode.absoluteString,
                       "https://github.com/pingolindev/note-web-public")
    }
}
