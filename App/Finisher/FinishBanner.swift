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

/// The server's `finish_shares` push: sent to an OWNER's phones when an
/// account signs up with an address one of their notes was shared with. On
/// iOS it is the one visible alert the note server sends ("Someone you invited
/// has joined Pingolin."), with mutable-content, so the notification extension
/// runs for it even when the app was swiped away. Like every tickle, the event
/// is in `kind`; `type` is "tickle".
enum FinishPush {
    static let kind = "finish_shares"

    static func isFinishShares(_ userInfo: [AnyHashable: Any]) -> Bool {
        (userInfo["kind"] as? String ?? userInfo["type"] as? String) == kind
    }
}

/// What the banner says once the phone has finished shares: who can open what.
/// Nothing finished: the server's words stay.
enum FinishBanner {
    /// The banner's new body, or nil to keep the server's. An address is shown
    /// only when it looks like one (the server's list is not the app's words),
    /// and not at all when notifications are set to generic.
    static func body(finished: [InvitationFinisher.UnfinishedShare], detail: String?) -> String? {
        guard !finished.isEmpty else { return nil }
        // Notes, not shares: one note shared with two people is still "the note".
        let notes = Set(finished.map { CanonicalId.of($0.itemId) ?? $0.itemId.lowercased() })
        let what = notes.count == 1 ? "the note" : "the notes"
        var addresses: [String] = []
        for row in finished where !addresses.contains(where: {
            $0.caseInsensitiveCompare(row.recipientEmail) == .orderedSame
        }) {
            addresses.append(row.recipientEmail)
        }
        guard detail != "generic", addresses.allSatisfy(showable) else {
            return addresses.count == 1
                ? "Someone you invited can now open \(what) you shared."
                : "\(addresses.count) people you invited can now open \(what) you shared."
        }
        switch addresses.count {
        case 1: return "\(addresses[0]) can now open \(what) you shared."
        case 2: return "\(addresses[0]) and \(addresses[1]) can now open \(what) you shared."
        default: return "\(addresses[0]) and \(addresses.count - 1) others can now open \(what) you shared."
        }
    }

    /// Plain ASCII of an address's shape, at most 254 characters: nothing a
    /// server could turn into another sentence.
    static func showable(_ address: String) -> Bool {
        guard address.utf8.count <= 254, EmailFormat.isPlausible(address), address == address.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return address.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static let allowed = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.!#$%&'*+/=?^_`{|}~-@")
}
