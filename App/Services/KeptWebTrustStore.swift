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
import UIKit

/// Kept trust in the shell.
///
/// The page keeps three stores that outlive a sign-out: its pins, its rollback
/// floors and its item owners (`pingolin_note_pinned_keys`, `_gen_floor`,
/// `_item_owner`, per account). A browser keeps them in localStorage, but the
/// shell's sign-out empties every website store, so without this every sign-in
/// in the shell would start from a first contact for everyone. The page
/// therefore hands the three blobs to the shell after every change (the
/// bridge's `keepTrust`) and asks for them back (`keptTrust`) when the same
/// account signs in again, before anything reads them. The folds that take
/// them in are the page's, and they only add.
///
/// Here they wait outside WebKit: the app's own `UserDefaults` (not the app
/// group), one entry per account in its one form, holding the page's strings
/// as given. All three are public data: ids, public keys, generations.
///  - Only this account's copy is ever served or written: the bridge checks
///    the message's account against the signed-in one before it gets here,
///    and every entry is keyed by `CanonicalId`.
///  - A copy that can't be read is `.unreadable`, never `.none`: the page
///    sends keeps only after a real answer, so a copy it never folded in is
///    never overwritten with less. Before the first unlock `UserDefaults`
///    reads as empty, which is never "nothing kept".
///  - An account's copy goes when that account is erased on this device.
@MainActor
final class KeptWebTrustStore {
    static let shared = KeptWebTrustStore()

    /// The shell keeps no blob over this (UTF-8 bytes), as the page and note-android.
    nonisolated static let maxBlobBytes = 1024 * 1024
    /// The blobs a message carries, by field name.
    nonisolated static let blobNames = ["pins", "floors", "owners"]

    enum Kept: Equatable {
        case copy(pins: String?, floors: String?, owners: String?)
        case none
        case unreadable
    }

    private let defaults: UserDefaults
    private let dataReadable: @MainActor () -> Bool
    private let prefix = "note_kept_web_trust."

    init(defaults: UserDefaults = .standard,
         dataReadable: @escaping @MainActor () -> Bool = { UIApplication.shared.isProtectedDataAvailable }) {
        self.defaults = defaults
        self.dataReadable = dataReadable
    }

    /// This account's copy; `.none` only when the store reads and holds nothing for it.
    func get(_ account: String) -> Kept {
        guard let id = CanonicalId.of(account), dataReadable() else { return .unreadable }
        guard let value = defaults.object(forKey: prefix + id) else { return .none }
        guard let map = value as? [String: String], !map.isEmpty,
              Set(map.keys).isSubset(of: Set(Self.blobNames))
        else { return .unreadable }
        return .copy(pins: map["pins"], floors: map["floors"], owners: map["owners"])
    }

    /// Keep the page's three blobs for this account (a nil drops its blob);
    /// true when they are stored as given. Nothing over `maxBlobBytes`.
    func keep(_ account: String, pins: String?, floors: String?, owners: String?) -> Bool {
        guard let id = CanonicalId.of(account), dataReadable() else { return false }
        var map: [String: String] = [:]
        for (name, blob) in zip(Self.blobNames, [pins, floors, owners]) {
            guard let blob else { continue }
            guard blob.utf8.count <= Self.maxBlobBytes else { return false }
            map[name] = blob
        }
        let key = prefix + id
        if map.isEmpty {
            defaults.removeObject(forKey: key)
            return defaults.object(forKey: key) == nil
        }
        defaults.set(map, forKey: key)
        return (defaults.dictionary(forKey: key) as? [String: String]) == map
    }

    /// Erasure: this account's copy, under every spelling of its id; nobody else's.
    func forget(_ account: String) {
        guard let id = CanonicalId.of(account) else { return }
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix(prefix) && CanonicalId.of(String(key.dropFirst(prefix.count))) == id {
            defaults.removeObject(forKey: key)
        }
    }
}
