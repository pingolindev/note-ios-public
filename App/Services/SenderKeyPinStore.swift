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

/// TOFU (trust-on-first-use) pin store for share counterparties' identity keys. iOS parallel of
/// note-android's `SenderKeyPinStore.kt` and note-web's `pinnedKeys` map + `pinUserKeys` /
/// `getPinnedUserKeys` (its crypto.ts).
///
/// Keyed by the OTHER party's user_id (the sender when we're the recipient of a share), in its one form
/// (`CanonicalId`): another spelling of a pinned sender finds the pin, and an id that isn't a UUID is an
/// error. Once a sender's signing key is observed on the first successful content-key unwrap, we pin it here
/// and verify every later share-wrap signature against the PINNED key — never against a key the server hands
/// us at verify time. A malicious/compromised server can return an attacker signing key together with a
/// signature made by that same attacker key, which would "verify" against the server-supplied key; pinning
/// defeats that because verification uses the key we observed on first use.
///
/// Persisted in `UserDefaults.standard` — the same app-sandboxed store this app already uses for
/// android-`SharedPreferences`-parity state (`AuthRateLimiter`). A pin is PUBLIC key material: its integrity
/// matters, not its secrecy, so it does NOT belong in the Keychain. The blob is NAMESPACED by the local
/// owner's user_id (`note_sender_pins.<userId>`) so a shared device keeps each account's pins isolated —
/// account B must never inherit account A's TOFU trust decisions. `switchUser(_:)` rebinds the namespace on
/// login / session-restore; `reset()` wipes it on logout (a pin is account-scoped identity state, so a wiped
/// store simply re-baselines at first use — TOFU). This mirrors note-web's `pinStorageUserId` /
/// `pinStorageKey()` + `clearKeys()` pin sweep and note-android's namespaced `note_sender_pins` file +
/// `wipe()`. The map is serialized as one JSON blob keyed by the owner user_id's one form.
///
/// A pin is NEVER silently overwritten: `pin(...)` reports a `.changed*` state when the presented key differs
/// from what's stored but leaves the stored pin intact, so the caller can raise a key-change alarm.
/// Re-pinning after a legitimate rotation needs an out-of-band (safety-number) confirmation, which this store
/// does not do by itself (see `SharesInboxStore.afterOpening`, which computes the safety number).
final class SenderKeyPinStore {
    static let shared = SenderKeyPinStore()

    /// One pinned counterparty. `sharingPubHex` is optional because the
    /// signing key is the load-bearing one for wrap-signature verification;
    /// we pin the sharing key too when the directory returns it.
    struct PinRecord: Codable, Equatable {
        let signingPubHex: String
        let sharingPubHex: String?
        /// Unix seconds of the first (TOFU) pin.
        let pinnedAt: Int
    }

    /// Outcome of a `pin(...)` call. Mirrors note-android's `PinState` and
    /// note-web's `PinState`.
    enum PinState {
        case newPinning
        case matched
        case changedSharing
        case changedSigning
        case changedBoth
    }

    private let defaults: UserDefaults
    private let storageKey = "note_sender_pins"

    /// In-memory cache, loaded lazily from `defaults` on first access (mirrors
    /// note-web's `pinsLoaded` guard / note-android's `loaded`). All access is
    /// serialized on `queue` so the store is safe to touch from any isolation
    /// domain, matching note-android's `@Synchronized`.
    private let queue = DispatchQueue(label: "com.pingolin.note.senderpins")
    private var loaded = false
    private var pins: [String: PinRecord] = [:]
    /// Local owner's user_id, namespacing the persisted blob so a shared
    /// device isolates each account's pins. `nil` pre-login falls back to the
    /// base `storageKey`. Only ever touched on `queue`. Mirrors note-web's
    /// `pinStorageUserId`.
    private var currentUserId: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// `UserDefaults` key for the current owner's pin blob: the base
    /// `storageKey` namespaced by `currentUserId` (falls back to the base key
    /// pre-login). MUST be called on `queue` — it reads `currentUserId`.
    /// Mirrors note-web's `pinStorageKey()`.
    private func effectiveKey() -> String {
        currentUserId.map { "\(storageKey).\($0)" } ?? storageKey
    }

    /// Load the bound account's pins, their entries by their one form (`fold`).
    /// A store that can't be read — no account bound, or a blob that doesn't
    /// decode — throws `StoreUnreadable` and stays unloaded, so its next use
    /// reads again; it is never "no pins", and nothing is written over it.
    /// MUST be called on `queue`.
    private func ensureLoaded() throws {
        if loaded { return }
        guard currentUserId != nil else { throw StoreUnreadable(store: "pins") }
        guard let value = defaults.object(forKey: effectiveKey()) else {
            pins = [:]
            loaded = true
            return
        }
        guard let data = value as? Data,
              let blob = try? JSONDecoder().decode([String: PinRecord].self, from: data) else {
            throw StoreUnreadable(store: "pins")
        }
        pins = Self.fold([blob]).pins
        loaded = true
    }

    /// Read the bound account's pins now: `StoreUnreadable` when they can't be
    /// read. The inbox refresh calls this before it fetches anything.
    func ensureReadable() throws {
        try queue.sync { try ensureLoaded() }
    }

    /// `ownerId`'s one form, or `NotAnId`: an id that isn't a UUID is an error,
    /// never "not pinned".
    private static func key(_ ownerId: String) throws -> String {
        guard let key = CanonicalId.of(ownerId) else { throw NotAnId(raw: ownerId) }
        return key
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(pins)
            defaults.set(data, forKey: effectiveKey())
        } catch {
            #if DEBUG
            print("[Note] SenderKeyPinStore: failed to persist sender pins: \(error)")
            #endif
        }
    }

    /// Read a pin (nil if this counterparty is unpinned), by the id's one form.
    /// Throws `NotAnId` for an id that isn't a UUID and `StoreUnreadable` for a
    /// store that can't be read — never "unpinned".
    func getPinned(_ ownerId: String) throws -> PinRecord? {
        let key = try Self.key(ownerId)
        return try queue.sync {
            try ensureLoaded()
            return pins[key]
        }
    }

    /// Pin (or compare against an existing pin for) a counterparty's signing
    /// (and, when available, sharing) public key. Case-insensitive hex
    /// compare; the map is keyed by the lowercased `ownerId`.
    ///
    /// - No existing pin → stores it and returns `.newPinning`.
    /// - Everything matches → `.matched` (no write).
    /// - Signing key differs → `.changedSigning` / `.changedBoth` and the
    ///   stored pin is left INTACT (never silently overwritten) so the caller
    ///   can alarm and gate on out-of-band confirmation.
    /// - Only the sharing key differs → `.changedSharing` (also no overwrite).
    @discardableResult
    func pin(ownerId: String, signingPubHex: String, sharingPubHex: String?) throws -> PinState {
        let key = try Self.key(ownerId)
        return try queue.sync {
            try ensureLoaded()
            let signingLower = signingPubHex.lowercased()
            let sharingLower = sharingPubHex?.lowercased()
            guard let existing = pins[key] else {
                pins[key] = PinRecord(
                    signingPubHex: signingLower,
                    sharingPubHex: sharingLower,
                    pinnedAt: Int(Date().timeIntervalSince1970)
                )
                persist()
                return .newPinning
            }
            let signingMatch = existing.signingPubHex == signingLower
            // Can't compare the sharing key when either side is absent — treat
            // as a match so a missing sharing key never masquerades as a change.
            let sharingMatch: Bool
            if sharingLower == nil || existing.sharingPubHex == nil {
                sharingMatch = true
            } else {
                sharingMatch = existing.sharingPubHex == sharingLower
            }
            // NEVER overwrite on a change — a rotated key must be confirmed
            // out-of-band before re-pinning. We only report the state.
            switch (signingMatch, sharingMatch) {
            case (true, true): return .matched
            case (true, false): return .changedSharing
            case (false, true): return .changedSigning
            case (false, false): return .changedBoth
            }
        }
    }

    /// Overwrite a pin after the user confirmed the counterparty's rotated
    /// keys out-of-band (a safety-number match). The ONLY path that replaces
    /// a stored pin — `pin(...)` never overwrites a change, so without this a
    /// legitimate sender key rotation is unrecoverable in-app. Mirrors
    /// note-android's `approve` / note-web's `approveUserKeyChange`.
    func approve(ownerId: String, newSigningPubHex: String, newSharingPubHex: String?) throws {
        let key = try Self.key(ownerId)
        try queue.sync {
            try ensureLoaded()
            let existing = pins[key]
            pins[key] = PinRecord(
                signingPubHex: newSigningPubHex.lowercased(),
                sharingPubHex: newSharingPubHex?.lowercased(),
                pinnedAt: existing?.pinnedAt ?? Int(Date().timeIntervalSince1970)
            )
            persist()
        }
    }

    /// Rebind the persistence namespace to `userId` on login / session-restore
    /// so subsequent reads and writes hit THIS account's blob. A no-op when the
    /// user is unchanged; otherwise drops the in-memory cache (`loaded = false`,
    /// empty `pins`) so the next access lazy-loads the correct namespace.
    /// Mirrors note-web's `loadPinnedKeysFromStorage(userId)` namespace switch.
    /// The namespace is the id's one form (CanonicalId); an id that isn't a
    /// UUID binds none.
    func switchUser(_ userId: String?) {
        let id = CanonicalId.of(userId)
        queue.sync {
            guard id != currentUserId else { return }
            loaded = false
            pins = [:]
            currentUserId = id
        }
    }

    /// Fold into the bound account's blob every blob an older build kept under
    /// another spelling of its id, and re-key its own entries by their one
    /// form: the pin-merge rule (`Self.fold`). The merged blob is written and
    /// read back before any blob it came from is removed. The caller runs this
    /// only when this app's data can be read (a Keychain read just succeeded):
    /// before the first unlock `UserDefaults` reads as empty, which is never
    /// "no pins".
    func adoptOtherSpellings() {
        queue.sync {
            guard let id = currentUserId else { return }
            let key = "\(storageKey).\(id)"
            let others = defaults.dictionaryRepresentation().keys.filter { k in
                k.hasPrefix("\(storageKey).") && k != key
                    && CanonicalId.of(String(k.dropFirst(storageKey.count + 1))) == id
            }.sorted()
            var sources: [[String: PinRecord]] = []
            for k in others + [key] {
                guard let data = defaults.data(forKey: k) else { continue }
                guard let blob = try? JSONDecoder().decode([String: PinRecord].self, from: data) else {
                    // One that doesn't decode is left as it is, and so is everything it would join.
                    return
                }
                sources.append(blob)
            }
            let folded = Self.fold(sources)
            guard !others.isEmpty || folded.changed else { return }
            guard let data = try? JSONEncoder().encode(folded.pins) else { return }
            defaults.set(data, forKey: key)
            guard let back = defaults.data(forKey: key),
                  let reread = try? JSONDecoder().decode([String: PinRecord].self, from: back),
                  reread == folded.pins else { return }
            for k in others { defaults.removeObject(forKey: k) }
            loaded = false
            pins = [:]
        }
    }

    /// The keys a conflict holds: no real key is all zero, so an older build
    /// reading the store sees a changed key too (the sentinel the web and
    /// Android use).
    static let conflictKeyHex = String(repeating: "0", count: 64)

    /// Blobs' entries by their one form (CanonicalId), by the pin-merge rule
    /// (the web editor's pinMerge.ts): an entry keyed by no UUID is dropped;
    /// two entries for one account with the same keys are one, with the
    /// earliest first pin (a sharing key one lacks is no difference, as in
    /// `pin`); with different keys they are a conflict (`conflictKeyHex` for
    /// both), which reads as changed until the person approves one.
    static func fold(_ blobs: [[String: PinRecord]]) -> (pins: [String: PinRecord], changed: Bool) {
        var out: [String: PinRecord] = [:]
        var changed = blobs.count > 1
        for blob in blobs {
            for (raw, record) in blob.sorted(by: { $0.key < $1.key }) {
                guard let id = CanonicalId.of(raw), !record.signingPubHex.isEmpty else {
                    changed = true
                    continue
                }
                if id != raw { changed = true }
                guard let held = out[id] else {
                    out[id] = record
                    continue
                }
                changed = true
                let first = [held.pinnedAt, record.pinnedAt].filter { $0 > 0 }.min() ?? 0
                let sameSigning = held.signingPubHex != conflictKeyHex && record.signingPubHex != conflictKeyHex
                    && held.signingPubHex.lowercased() == record.signingPubHex.lowercased()
                let sameSharing = held.sharingPubHex == nil || record.sharingPubHex == nil
                    || held.sharingPubHex?.lowercased() == record.sharingPubHex?.lowercased()
                out[id] = sameSigning && sameSharing
                    ? PinRecord(signingPubHex: held.signingPubHex, sharingPubHex: held.sharingPubHex ?? record.sharingPubHex, pinnedAt: first)
                    : PinRecord(signingPubHex: conflictKeyHex, sharingPubHex: conflictKeyHex, pinnedAt: first)
            }
        }
        return (out, changed)
    }

    /// Logout wipe. Drop the in-memory cache and sweep the base-namespace
    /// fallback blob only; the current account's per-account namespaced pin blob
    /// is deliberately RETAINED so a same-account re-login re-reads its own TOFU
    /// pins, and a same-account logout→login opens no key-substitution window (a
    /// malicious server could otherwise re-TOFU a substituted signing key with no
    /// key-change alarm). Cross-account isolation is guaranteed by per-account
    /// namespacing, not by this wipe. `loaded = false` so the next access (after
    /// `switchUser` rebinds the namespace) lazy-loads the correct account's blob.
    /// Mirrors note-android `SenderKeyPinStore.wipe()`.
    func reset() {
        queue.sync {
            pins = [:]
            defaults.removeObject(forKey: storageKey)
            currentUserId = nil
            loaded = false
        }
    }
}
