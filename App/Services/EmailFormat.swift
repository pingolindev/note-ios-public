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

/// Is this string plausibly an email address?
///
/// WHY THIS EXISTS
///   Sent to the server as typed, a malformed address comes back as "Invalid
///   credentials" — the same words as a wrong password. The user would be told
///   the credentials are wrong when the real problem is a typo they can see,
///   and each attempt costs one of the limiter's slots. Both apps answer it
///   here, before any request.
///
/// DELIBERATELY PERMISSIVE
///   A typo catcher, not an RFC 5322 parser — every clever email regex ends up
///   rejecting somebody's real address, and the server remains the authority on
///   whether an account exists. Kept byte-for-byte identical to the Track iOS
///   app's `EmailFormat`: the two apps share an account system, and an address
///   one app refuses and the other accepts would be worse than either rule
///   alone. Separate repos, so it is duplicated rather than shared.
enum EmailFormat {
    static func isPlausible(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        guard !value.contains(where: { $0.isWhitespace }) else { return false }

        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let local = parts[0], domain = parts[1]
        guard !local.isEmpty, !domain.isEmpty else { return false }

        guard let dot = domain.firstIndex(of: "."), dot != domain.startIndex else { return false }
        guard domain.last != "." else { return false }
        guard !domain.contains("..") else { return false }
        return true
    }
}
