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

/// Per-item content-key rollback floor.
///
/// For every shared item we persist the HIGHEST content-key generation we've
/// ever accepted from a pin-verified wrap — keyed on the generation the
/// signature ACTUALLY verified under (`WrapVerifyResult.effectiveGeneration`),
/// never the server-claimed one. A pin-verified wrap whose generation is BELOW
/// the floor is a rollback: the blind server replaying an older wrapped content
/// key (e.g. a stale key a since-removed member still holds). Legitimate
/// generations are monotonic (rotate-shares only ever bumps), so a lower one
/// from a pinned sender is an attack, not reordering — the reader drops it.
///
/// The floor only advances, and only on shares we KEEP (pin-verified). Storage
/// is local `UserDefaults`, NAMESPACED by the local owner's user_id
/// (`note_gen_floor.<userId>`) so a shared device keeps each account's floors
/// isolated — account B must never inherit account A's anti-rollback state.
/// `switchUser(_:)` rebinds the namespace on login / session-restore and
/// `reset()` wipes it on logout, exactly mirroring the sibling
/// `SenderKeyPinStore`. The E2EE server can't tamper with any of it; a wipe
/// just re-baselines at first use (TOFU). Mirrors note-web's
/// `pingolin_note_gen_floor` localStorage map and note-android's
/// `NoteGenFloorStore`.
///
/// Keyed by the item id's one form (`CanonicalId`): another spelling of a
/// floored item finds its floor. A map that can't be read — no account bound,
/// or a value that isn't a map — throws `StoreUnreadable`: it is never "floor
/// 0" and nothing is written over it.
///
/// ITEM OWNERS: beside the floors, under their own key
/// (`note_item_owners.<userId>`), each shared item's owner — the sender of the
/// first share of it this account accepted. Only an item's owner can write a
/// share of it, so the inbox refuses anyone else's share of a bound item. A
/// separate key, never inside the floor map: an older build would drop a value
/// it doesn't know at its next write. A binding is never replaced or removed
/// here; only an erasure removes one.
final class NoteGenFloorStore {
    static let shared = NoteGenFloorStore()

    private let defaults: UserDefaults
    /// Base persistence key. The live key is NAMESPACED by the local owner's
    /// user_id (`note_gen_floor.<userId>`) via `effectiveKey()` so a shared
    /// device isolates each account's floors. `currentUserId == nil`
    /// (pre-login / pre-switch) falls back to this base key. Mirrors
    /// `SenderKeyPinStore`'s `storageKey`.
    private let storageKey = "note_gen_floor"
    /// Base key of the item owners, namespaced like the floors.
    private let ownersKey = "note_item_owners"
    /// Two stored spellings of one item bound to two owners: nobody's, every
    /// share of it refused.
    static let ownerConflict = "conflict"
    private let lock = NSLock()
    /// Local owner's user_id, namespacing the persisted map so a shared device
    /// isolates each account's floors. `nil` pre-login falls back to the base
    /// `storageKey`. Only ever touched under `lock`. Mirrors the web editor's
    /// `pinStorageUserId` and `SenderKeyPinStore.currentUserId`.
    private var currentUserId: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// `UserDefaults` key for the current owner's floor map: the base
    /// `storageKey` namespaced by `currentUserId` (falls back to the base key
    /// pre-login). MUST be called under `lock` — it reads `currentUserId`.
    /// Mirrors `SenderKeyPinStore.effectiveKey()`.
    private func effectiveKey() -> String {
        currentUserId.map { "\(storageKey).\($0)" } ?? storageKey
    }

    /// The bound account's floors, by the item id's one form. MUST be called
    /// under `lock`. Throws `StoreUnreadable` with no account bound (fail
    /// closed) or a stored value that isn't a map.
    private func readFloors() throws -> [String: Int64] {
        guard let id = currentUserId else { throw StoreUnreadable(store: "floors") }
        guard let value = defaults.object(forKey: "\(storageKey).\(id)") else { return [:] }
        guard let map = value as? [String: NSNumber] else { throw StoreUnreadable(store: "floors") }
        return Self.fold([map]).floors
    }

    /// The bound account's item owners (`foldOwners`). MUST be called under
    /// `lock`. Throws like `readFloors`.
    private func readOwners() throws -> [String: String] {
        guard let id = currentUserId else { throw StoreUnreadable(store: "item owners") }
        guard let value = defaults.object(forKey: "\(ownersKey).\(id)") else { return [:] }
        guard let map = value as? [String: String] else { throw StoreUnreadable(store: "item owners") }
        return Self.foldOwners(map)
    }

    /// `itemId`'s one form, or `NotAnId`.
    private static func key(_ itemId: String) throws -> String {
        guard let key = CanonicalId.of(itemId) else { throw NotAnId(raw: itemId) }
        return key
    }

    /// Read the bound account's floors and item owners now: `StoreUnreadable`
    /// when either can't be read. The inbox refresh calls this before it
    /// fetches anything.
    func ensureReadable() throws {
        lock.lock(); defer { lock.unlock() }
        _ = try readFloors()
        _ = try readOwners()
    }

    /// Highest accepted generation for `itemId`, or 0 if none seen yet. Throws
    /// `NotAnId` for an item id that isn't a UUID and `StoreUnreadable` for a
    /// map that can't be read or no account bound — never 0.
    func floor(_ itemId: String) throws -> Int64 {
        let key = try Self.key(itemId)
        lock.lock(); defer { lock.unlock() }
        return try readFloors()[key] ?? 0
    }

    /// The owner `itemId` is bound to: the canonical id of the sender of
    /// the first share of it this account accepted, `ownerConflict` when two
    /// stored spellings of it named two owners, or nil while it is unbound.
    /// Throws like `floor`.
    func owner(_ itemId: String) throws -> String? {
        let key = try Self.key(itemId)
        lock.lock(); defer { lock.unlock() }
        return try readOwners()[key]
    }

    /// Record an accepted share of `itemId`: bind the item to `ownerId`
    /// while it is unbound, and raise its floor to `generation` when that is
    /// higher (a positive generation, from a pin-verified wrap). A binding is
    /// never replaced. Both maps are written before the call returns, the floor
    /// last, so a floor is never saved without its binding.
    func accept(_ itemId: String, owner ownerId: String, generation: Int64 = 0) throws {
        let key = try Self.key(itemId)
        guard let owner = CanonicalId.of(ownerId) else { throw NotAnId(raw: ownerId) }
        lock.lock(); defer { lock.unlock() }
        guard let id = currentUserId else { throw StoreUnreadable(store: "floors") }
        var floors = try readFloors()
        var owners = try readOwners()
        if owners[key] == nil {
            owners[key] = owner
            defaults.set(owners, forKey: "\(ownersKey).\(id)")
        }
        if generation > 0, generation > floors[key] ?? 0 {
            floors[key] = generation
            defaults.set(floors.mapValues { NSNumber(value: $0) }, forKey: "\(storageKey).\(id)")
        }
    }

    /// Rebind the persistence namespace to `userId` on login / session-restore
    /// so subsequent reads and writes hit THIS account's floor map. A no-op
    /// when the user is unchanged. Unlike `SenderKeyPinStore`, the map lives
    /// entirely in `UserDefaults` with no in-memory cache to drop, so switching
    /// the namespace is all that's needed. Mirrors `SenderKeyPinStore.switchUser(_:)`.
    /// The namespace is the id's one form (CanonicalId); an id that isn't a
    /// UUID binds none.
    func switchUser(_ userId: String?) {
        let id = CanonicalId.of(userId)
        lock.lock(); defer { lock.unlock() }
        guard id != currentUserId else { return }
        currentUserId = id
    }

    /// Fold into the bound account's map every map an older build kept under
    /// another spelling of its id: per item, by its one form, the highest
    /// generation (a floor only moves up); an item key that isn't a UUID, or a
    /// generation that isn't positive, is dropped. The merged map is written
    /// and read back before any map it came from is removed. The caller runs
    /// this only when this app's data can be read: before the first unlock
    /// `UserDefaults` reads as empty, which is never "no floors".
    func adoptOtherSpellings() {
        lock.lock(); defer { lock.unlock() }
        guard let id = currentUserId else { return }
        let key = "\(storageKey).\(id)"
        let others = defaults.dictionaryRepresentation().keys.filter { k in
            k.hasPrefix("\(storageKey).") && k != key
                && CanonicalId.of(String(k.dropFirst(storageKey.count + 1))) == id
        }.sorted()
        var maps: [[String: NSNumber]] = []
        for k in others + [key] {
            guard let value = defaults.object(forKey: k) else { continue }
            // One that doesn't read as a map is left as it is, and so is everything it would join.
            guard let map = value as? [String: NSNumber] else { return }
            maps.append(map)
        }
        let folded = Self.fold(maps)
        guard !others.isEmpty || folded.changed else { return }
        defaults.set(folded.floors.mapValues { NSNumber(value: $0) }, forKey: key)
        guard let back = defaults.dictionary(forKey: key) as? [String: NSNumber],
              back.mapValues({ $0.int64Value }) == folded.floors else { return }
        for k in others { defaults.removeObject(forKey: k) }
    }

    /// A stored owners map by the ids' one form: an entry whose item or owner
    /// isn't a UUID is dropped, and two spellings of one item bound to
    /// different owners fold to `ownerConflict`.
    static func foldOwners(_ map: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        for (raw, value) in map.sorted(by: { $0.key < $1.key }) {
            guard let id = CanonicalId.of(raw) else { continue }
            guard let owner = value == ownerConflict ? ownerConflict : CanonicalId.of(value) else { continue }
            if let held = out[id], held != owner {
                out[id] = ownerConflict
            } else {
                out[id] = owner
            }
        }
        return out
    }

    /// Maps by item id's one form, the highest generation per item; keys that
    /// aren't UUIDs and generations that aren't positive are dropped.
    static func fold(_ maps: [[String: NSNumber]]) -> (floors: [String: Int64], changed: Bool) {
        var out: [String: Int64] = [:]
        var changed = maps.count > 1
        for map in maps {
            for (raw, number) in map {
                let generation = number.int64Value
                guard let id = CanonicalId.of(raw), generation > 0 else {
                    changed = true
                    continue
                }
                if id != raw { changed = true }
                if let held = out[id] {
                    changed = true
                    out[id] = max(held, generation)
                } else {
                    out[id] = generation
                }
            }
        }
        return (out, changed)
    }

    /// Logout wipe. Drop the base-namespace fallback blob only; the current
    /// account's per-account namespaced floor map is deliberately RETAINED so a
    /// same-account re-login re-reads its own anti-rollback floors, and a
    /// same-account logout→login opens no rollback window: a malicious server
    /// could otherwise replay an older wrapped content key past a reset-to-0
    /// floor. Cross-account isolation is guaranteed by per-account namespacing,
    /// not by this wipe. Mirrors note-android `NoteGenFloorStore.wipe()`.
    func reset() {
        lock.lock(); defer { lock.unlock() }
        defaults.removeObject(forKey: storageKey)
        currentUserId = nil
    }
}
