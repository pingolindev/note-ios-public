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

/// Each bundle that ships carries its own privacy manifest at its root,
/// declaring the required-reason APIs its code calls, for the reasons it calls
/// them. XcodeGen ignores a target-level `resources:` key, which is how the
/// app's manifest once never shipped at all; these read the built bundles.
final class PrivacyManifestTests: XCTestCase {

    /// The app reads its own UserDefaults and the app group's, file metadata
    /// inside its container (the SDK's tile cache), and the system uptime to
    /// time its own waits.
    func testTheAppCarriesItsManifest() throws {
        let declared = try Self.declared(at: Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        XCTAssertEqual(declared, [
            "NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1", "1C8F.1"],
            "NSPrivacyAccessedAPICategoryFileTimestamp": ["C617.1"],
            "NSPrivacyAccessedAPICategoryDiskSpace": ["E174.1"],
            "NSPrivacyAccessedAPICategorySystemBootTime": ["35F9.1"],
        ])
    }

    /// The share extension and the widgets read the app group's UserDefaults
    /// (`SharedAppGroup`), and nothing else on Apple's list.
    func testEachExtensionCarriesItsOwn() throws {
        for appex in ["NoteShareExt.appex", "NoteWidgets.appex"] {
            let bundle = try XCTUnwrap(Bundle.main.builtInPlugInsURL?.appendingPathComponent(appex))
            let declared = try Self.declared(at: bundle.appendingPathComponent("PrivacyInfo.xcprivacy"))
            XCTAssertEqual(declared, ["NSPrivacyAccessedAPICategoryUserDefaults": ["1C8F.1"]], appex)
        }
    }

    /// Each declared API category with its reasons. Every manifest says the
    /// bundle does no tracking.
    private static func declared(at url: URL?) throws -> [String: Set<String>] {
        let url = try XCTUnwrap(url, "no PrivacyInfo.xcprivacy in the bundle")
        let data = try Data(contentsOf: url)
        let object = try PropertyListSerialization.propertyList(from: data, format: nil)
        let manifest = try XCTUnwrap(object as? [String: Any], "\(url.path) is not a dictionary")
        XCTAssertEqual(manifest["NSPrivacyTracking"] as? Bool, false, url.path)
        let entries = try XCTUnwrap(manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]], url.path)
        var out: [String: Set<String>] = [:]
        for entry in entries {
            let category = try XCTUnwrap(entry["NSPrivacyAccessedAPIType"] as? String, url.path)
            let reasons = try XCTUnwrap(entry["NSPrivacyAccessedAPITypeReasons"] as? [String], url.path)
            out[category, default: []].formUnion(reasons)
        }
        return out
    }
}
