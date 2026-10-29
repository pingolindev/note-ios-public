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

/// Encrypted user-metadata item (item_type=10). The web client writes
/// it; note-android reads + writes it (NotebookShareWriter). Shape:
///
/// ```
/// {
///   "notebooks":      [{id, name}, ...],
///   "labelColors":    { "label-1": "#aabbcc", ... },
///   "notebookShares": { "<notebook-id>": [{email, permission, publicKey?}, ...] }
/// }
/// ```
///
/// The blob is encrypted directly under the vault key (the web
/// implementation uses `encryptNote` rather than the per-content-key
/// path), so we use the legacy NoteCrypto.encrypt/decrypt pair instead
/// of the wrapped variant.
struct NotebookMetadata: Codable {
    var notebooks: [NotebookEntry]
    var labelColors: [String: String]
    var notebookShares: [String: [ShareRecipientEntry]]
    /// noteId -> the editor mode that note is pinned to. Absent means the note
    /// follows the global setting. Optional because clients that predate it
    /// simply do not write the key.
    var editorModes: [String: String]?
    /// Notebook ids this user has accepted an invitation to.
    ///
    /// Being added to a shared notebook is being enrolled in a place its owner
    /// keeps putting notes in, so it is offered rather than imposed. The
    /// decision is this user's view of their own account — not the owner's
    /// business and not a server column — and living here is what stops the
    /// same question being asked again on every device.
    ///
    /// Optional because clients that predate it simply do not write the key.
    /// Same name and shape web uses.
    var acceptedNotebooks: [String]?

    static let empty = NotebookMetadata(
        notebooks: [],
        labelColors: [:],
        notebookShares: [:],
        editorModes: nil,
        acceptedNotebooks: nil
    )
}

struct NotebookEntry: Codable, Hashable {
    var id: String
    var name: String
}

struct ShareRecipientEntry: Codable, Hashable {
    var email: String
    var permission: String
    var publicKey: String?
    var userId: String?
}

/// Pulls + persists the metadata item. The server keeps it as a
/// regular Item with `itemType == 10`; on first write we POST, on
/// subsequent writes we PUT with the right `expectedVersion` so we
/// don't clobber updates from another device.
enum NotebookMetadataStore {
    static let itemTypeMetadata = 10

    /// Keys this client owns in the metadata blob. Anything else that arrives
    /// is another client's field and must survive our next save — see `extras`.
    ///
    /// Kept in sync with the encode site in `save`, which serialises
    /// `NotebookMetadata`'s stored properties. A property added there but
    /// missing here would be captured as an extra AND emitted by the encoder,
    /// so the merge below prefers the encoded copy rather than writing both.
    private static let knownKeys: Set<String> = [
        "notebooks", "labelColors", "notebookShares", "editorModes",
    ]

    /// Everything the last-read blob carried that this build does not model,
    /// kept verbatim.
    ///
    /// There is ONE metadata item per user and every client rewrites the whole
    /// of it, so encoding a fixed-property struct DELETES any field a newer
    /// client wrote — silently, on the next notebook rename. android is safe
    /// because it mutates a parsed JSON object in place; `Codable` is not,
    /// because it emits exactly its own properties and nothing else, and cannot
    /// even report the keys it ignored. The note CONTENT json has the same
    /// problem one level down, which the web handles with `extrasFrom`.
    private static var extras: [String: Any] = [:]

    /// Everything in the decrypted blob that isn't ours. Membership test, never
    /// truthiness: a `false`, `0` or `null` a newer client wrote is data, and
    /// filtering on the VALUE would silently drop it.
    static func extrasFrom(_ raw: [String: Any]) -> [String: Any] {
        raw.filter { !knownKeys.contains($0.key) }
    }

    private static var cachedItem: Item?

    /// Serialises the read-modify-write of the ONE metadata row.
    ///
    /// `save` POSTs whenever `fetch` handed it nil, so two writes that OVERLAP
    /// both see "no row" and both create one. `cachedItem` cannot help there —
    /// it is only set once a POST has RETURNED, which by definition has not
    /// happened yet while the other write is still in its fetch: two
    /// concurrent `setPin` calls on a fresh account would produce two rows,
    /// both version 1, i.e. two POSTs. The web client serialises
    /// `persistToServer` for the same reason; this is that, for the two Swift
    /// callers.
    ///
    /// A plain lock rather than a task chain because the critical section has
    /// to span fetch→save: the decision to POST is made from what fetch saw,
    /// so anything that interleaves between them reintroduces the race.
    private actor WriteLock {
        private var busy = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func acquire() async {
            if !busy {
                busy = true
                return
            }
            await withCheckedContinuation { waiters.append($0) }
        }

        /// Hands the lock straight to the next waiter rather than clearing
        /// `busy`, so a queued writer cannot be overtaken by a fresh arrival.
        func release() {
            if waiters.isEmpty {
                busy = false
            } else {
                waiters.removeFirst().resume()
            }
        }
    }

    private static let writeLock = WriteLock()

    /// Run one read-modify-write of the metadata blob with no other
    /// interleaved. EVERY `fetch` → mutate → `save` pair must go through this;
    /// a pair that does not is a duplicate-row bug waiting to happen. Its
    /// caller: `mutatePins` here.
    ///
    /// Non-escaping closure, so it needs no `Sendable` dance under the target's
    /// minimal strict-concurrency setting. Nothing inside the section may call
    /// back into it — the lock is not reentrant and would deadlock.
    static func withWriteLock<T>(_ body: () async throws -> T) async rethrows -> T {
        await writeLock.acquire()
        defer { Task { await writeLock.release() } }
        return try await body()
    }

    /// Fetches the metadata item from the syncPull stream and decrypts
    /// it. Returns `.empty` if no metadata item exists yet — the
    /// caller can then write a new one.
    ///
    /// Pages the sync stream to the END. A single 500-item page is NOT enough:
    /// on a vault with >500 items the metadata row can fall outside the first
    /// page, and stopping there would make the recipient list (notebookShares)
    /// silently vanish AND make `save` POST a DUPLICATE item_type=10 row. Threads
    /// the backend's compound (updated_at, id) keyset cursor verbatim
    /// (SyncResponse.cursor + cursorId) so the scan neither skips nor re-fetches
    /// a page boundary.
    ///
    /// TAKES THE NEWEST MATCH, NOT THE FIRST. There is supposed to be exactly
    /// one item_type=10 row, but when there is more than one, `first(where:)`
    /// off a stream ordered ascending by (updated_at, id) means "the oldest" —
    /// and `save` PUTs whatever it was handed, which bumps that row's
    /// updated_at and moves it to the END of the same order. Consecutive writes
    /// would therefore land on DIFFERENT rows, so anything written by one is
    /// invisible to the next: pins, notebooks, label colours and notebook share
    /// recipients all rotate. Newest-wins makes that degrade to "one row is
    /// authoritative" instead. It does NOT merge the strays — recovering their
    /// contents is a deliberate, one-off repair, not something to run
    /// implicitly on every write.
    ///
    /// Scanning to the end costs little in practice: the metadata row is
    /// written often, so `updated_at ASC` already sorts it late, and a
    /// break-on-first-match would page nearly to the end anyway.
    static func fetch(vaultKeyBase64: String) async throws -> (NotebookMetadata, Item?) {
        var sinceRaw: String? = nil
        var sinceId: String? = nil
        var found: Item? = nil
        while true {
            let response = try await APIService.shared.syncPull(sinceId: sinceId, sinceRaw: sinceRaw, limit: 500)
            for item in response.items where item.itemType == itemTypeMetadata && !item.deleted {
                // The stream is ascending, so a later match is always newer;
                // compare anyway rather than trusting the ordering.
                if found == nil || item.updatedAt > found!.updatedAt { found = item }
            }
            // Advance the keyset cursor only while the server has more pages AND
            // handed back a cursor to resume from (the `guard` also prevents an
            // infinite loop if a page reports has_more with no cursor).
            guard response.hasMore, let nextCursor = response.cursor else { break }
            sinceRaw = nextCursor
            sinceId = response.cursorId
        }
        // Fall back to the row we created earlier in this session when the scan
        // cannot see it yet. This is what prevents duplicates: `save` POSTs
        // whenever it is handed a nil item, so a write whose scan misses a row
        // this session already created would make a second one — and then a
        // third, because the scan can lag a write (a read-after-write window).
        // `cachedItem` is written on both the create and update paths for
        // exactly this purpose. (android has the same guard —
        // UserMetadataStore.mutate caches the POST result "so a rapid second
        // write updates it instead of POSTing a duplicate".)
        if found == nil { found = cachedItem }
        cachedItem = found
        guard let item = found else { return (.empty, nil) }
        do {
            let data = try NoteCrypto.decrypt(item, vaultKeyBase64: vaultKeyBase64)
            let metadata = try JSONDecoder().decode(NotebookMetadata.self, from: data)
            // Same bytes, read a second way: `Codable` cannot report the keys it
            // ignored, so the only way to carry them is to look at the raw
            // object beside the typed one.
            if let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                extras = extrasFrom(raw)
            } else {
                extras = [:]
            }
            cachePins(metadata.editorModes)
            return (metadata, item)
        } catch {
            // The web client may have written a partial metadata blob
            // — start fresh rather than clobbering, but keep the item
            // ref so we update in place rather than POSTing a second
            // copy.
            return (.empty, item)
        }
    }

    /// Re-encrypt + persist. Uses PUT when an existing item is supplied,
    /// POST when this is the first write for the account.
    static func save(_ metadata: NotebookMetadata, existing: Item?, vaultKeyBase64: String) async throws -> Item {
        cachePins(metadata.editorModes)
        let encoded = try JSONEncoder().encode(metadata)
        // Re-attach whatever the blob carried that this build does not model,
        // then serialise the merged object rather than the struct.
        let jsonData: Data
        if extras.isEmpty {
            jsonData = encoded
        } else if var merged = (try? JSONSerialization.jsonObject(with: encoded)) as? [String: Any] {
            // The encoded copy wins on a collision — see `knownKeys`.
            for (k, v) in extras where merged[k] == nil { merged[k] = v }
            jsonData = (try? JSONSerialization.data(withJSONObject: merged)) ?? encoded
        } else {
            jsonData = encoded
        }
        guard let json = String(data: jsonData, encoding: .utf8) else {
            throw NSError(domain: "Metadata", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: "Encode failed"])
        }
        let encrypted = try NoteCrypto.encrypt(plaintext: json, vaultKeyBase64: vaultKeyBase64)
        if let existing {
            let req = UpdateItemRequest(
                encryptedContent: encrypted.ciphertext,
                contentNonce: encrypted.nonce,
                expectedVersion: existing.version
            )
            let saved = try await APIService.shared.updateItem(existing.id, req)
            cachedItem = saved
            return saved
        } else {
            let req = CreateItemRequest(
                itemType: itemTypeMetadata,
                encryptedContent: encrypted.ciphertext,
                contentNonce: encrypted.nonce
            )
            let saved = try await APIService.shared.createItem(req)
            cachedItem = saved
            return saved
        }
    }

    // MARK: - Per-note editor mode pins

    /// Where the pin map is mirrored for cheap reads.
    ///
    /// `fetch` PAGES THE WHOLE SYNC STREAM to find the metadata item, which is
    /// far too expensive to do every time a note is opened just to decide which
    /// editor to draw. The blob stays the source of truth and the cross-device
    /// carrier; this is a local mirror, refreshed on every read and write of it.
    private static let pinCacheKey = "note.editorModePins"

    private static func cachePins(_ pins: [String: String]?) {
        UserDefaults.standard.set(pins ?? [:], forKey: pinCacheKey)
    }

    /// The pins as last read or written. Empty before the first metadata fetch
    /// of an install, which fails SAFE: every note simply follows the global.
    static func cachedPins() -> [String: String] {
        EditorModePins.sanitize(UserDefaults.standard.dictionary(forKey: pinCacheKey))
    }

    /// Forget the mirror. Account-scoped: note ids are not scoped to an
    /// account, so a leftover pin would silently apply to whatever the incoming
    /// account's note with that id happens to be.
    static func clearPinCache() {
        UserDefaults.standard.removeObject(forKey: pinCacheKey)
    }

    /// Drop the in-memory state this type carries between calls. MUST run on
    /// logout / account switch, alongside `clearPinCache`.
    ///
    /// `cachedItem` is a fallback for `fetch`, which makes it
    /// account-scoped: without this, a write made just after a switch would
    /// PUT account A's metadata item id under account B's token. `extras` is
    /// the same class of hazard — `fetch` refreshes it only on the decrypt
    /// SUCCESS path, so a fetch that returns `(.empty, item)` leaves A's
    /// unknown metadata fields in place for `save` to merge into B's blob.
    static func resetAccountState() {
        cachedItem = nil
        extras = [:]
    }

    /// Pin `noteId` to `mode`, or un-pin it when `mode` is the current
    /// `global`. No-ops when the map would not change — this blob is shared
    /// with notebooks and label colours, and a pointless write would bump its
    /// version and race another device for nothing.
    @discardableResult
    static func setPin(
        noteId: String, mode: String, global: String, vaultKeyBase64: String,
    ) async throws -> Bool {
        try await mutatePins(vaultKeyBase64: vaultKeyBase64) { pins in
            EditorModePins.withMode(pins, noteId: noteId, mode: mode, global: global)
        }
    }

    /// Forget every pin. A pin is visible only with its note open, so this is
    /// the one way back for a user who pinned a few and cannot remember which.
    @discardableResult
    static func clearPins(vaultKeyBase64: String) async throws -> Bool {
        try await mutatePins(vaultKeyBase64: vaultKeyBase64) { $0.isEmpty ? nil : [:] }
    }

    /// Drop pins whose note is gone. Takes the FULL local note id set — a
    /// partial one would collect pins for notes merely absent from it, which is
    /// silent data loss rather than housekeeping.
    @discardableResult
    static func gcPins(liveNoteIds: Set<String>, vaultKeyBase64: String) async throws -> Bool {
        guard !liveNoteIds.isEmpty else { return false }
        return try await mutatePins(vaultKeyBase64: vaultKeyBase64) {
            EditorModePins.gc($0, liveIds: liveNoteIds)
        }
    }

    /// Read-modify-write the pin map. `transform` returns nil for "no change",
    /// which skips the round-trip entirely.
    ///
    /// The whole fetch→save pair is under `withWriteLock`, not just the save:
    /// the decision to POST is made from what THIS fetch saw, so a second
    /// writer slipping in between them sees "no row" too and creates a second.
    private static func mutatePins(
        vaultKeyBase64: String, _ transform: ([String: String]) -> [String: String]?,
    ) async throws -> Bool {
        try await withWriteLock {
            var (metadata, existing) = try await fetch(vaultKeyBase64: vaultKeyBase64)
            guard let next = transform(metadata.editorModes ?? [:]) else { return false }
            metadata.editorModes = next
            _ = try await save(metadata, existing: existing, vaultKeyBase64: vaultKeyBase64)
            return true
        }
    }
}
