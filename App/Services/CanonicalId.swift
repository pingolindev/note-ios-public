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

/// An account's or an item's id in its one form: the 36 characters of a
/// hyphenated UUID, lower-cased. This app, the page and the SDK must agree
/// on who is who: an id spelt another way would miss this device's pins and
/// floors for that person or note, or take this account itself for a
/// stranger. The same parser as the Track iOS app's.
enum CanonicalId {
    /// Every spelling of a UUID the SDK parses (uuid 1.x: 36 hyphenated
    /// characters in any case, 32 bare hex digits, braced, "urn:uuid:"), in
    /// the one form; nil for anything that isn't a UUID — an error for the
    /// caller, never another id and never "not found".
    static func of(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let bytes = Array(raw.utf8)
        let hyphenated: String
        switch bytes.count {
        case 32:
            guard bytes.allSatisfy(isHex) else { return nil }
            let groups = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { String(decoding: bytes[$0], as: UTF8.self) }
            hyphenated = groups.joined(separator: "-")
        case 36:
            hyphenated = raw
        case 38 where bytes.first == UInt8(ascii: "{") && bytes.last == UInt8(ascii: "}"):
            hyphenated = String(decoding: bytes[1..<37], as: UTF8.self)
        case 45 where raw.hasPrefix("urn:uuid:"):
            hyphenated = String(decoding: bytes[9...], as: UTF8.self)
        default:
            return nil
        }
        return strict(hyphenated)
    }

    /// Only the 36 hyphenated characters, in any case, in the one form.
    static func strict(_ raw: String?) -> String? {
        guard let raw, raw.utf8.count == 36, raw.utf8.allSatisfy({ isHex($0) || $0 == UInt8(ascii: "-") }),
              let uuid = UUID(uuidString: raw) else { return nil }
        return uuid.uuidString.lowercased()
    }

    /// Whether `a` and `b` spell the same id: both UUIDs, with the same bytes.
    static func same(_ a: String?, _ b: String?) -> Bool {
        guard let one = of(a) else { return false }
        return one == of(b)
    }

    private static func isHex(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
            || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
            || (UInt8(ascii: "A")...UInt8(ascii: "F")).contains(byte)
    }
}
