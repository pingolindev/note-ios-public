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

/// Drains the offline outbox and reconciles the local cache with the server —
/// the iOS analog of note-android's `SyncRepository.sync()` push half + pull.
///
/// Offline support: a local create / edit / delete writes to `NoteStore`
/// FIRST (offline-first) and marks the row dirty; this service replays those
/// dirty rows to the server the moment we can reach it (app launch, foreground,
/// login, a push, or a connectivity regain), then pulls the server's changes
/// back into the cache. The cache is observable (`observeActiveNotes`), so
/// no view coupling is required.
///
/// Owned notes only. Shares are not offline-cached (deliberately, so a revoked
/// share can't leak offline), so their edits stay online-only and are
/// re-sourced from the inbox on the pull.
@MainActor
final class SyncService {
    static let shared = SyncService()
    private init() {}

    /// Coalesces overlapping triggers (launch + login + connectivity can all
    /// fire at once) so the same backlog isn't double-pushed.
    private var isSyncing = false

    /// Full cycle: refresh the shares inbox, drain the outbox (creates, edits,
    /// deletes), then pull server changes into the cache. Best-effort per stage —
    /// a stage failure never blocks the others. Safe to call from any trigger.
    func sync() async {
        guard AuthManager.shared.isAuthenticated, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        // Acting account for this whole cycle, captured before any network fetch.
        // A page pulled for this user must never be written into a DIFFERENT
        // account's cache if a logout / account switch lands mid-sync (see the
        // guard in pullIntoCache). Mirrors android SyncRepository.actingUser.
        let actingUser = KeychainService.shared.getString(for: .userId)

        // A share-extension draft becomes a dirty create NOW, so the
        // drainOutbox below pushes it in this same cycle.
        ShareDraftConsumer.consumePending()

        // Refresh the shares inbox first. Besides re-sourcing shared-note keys,
        // this mutates the @MainActor SharesInboxStore, whose observers react
        // to the change. Best-effort. Mirrors android sync()'s inbox
        // refresh at the top.
        try? await SharesInboxStore.shared.refresh(
            sharingPrivateKeyBase64: AuthManager.shared.sharingPrivateKeyBase64,
            sharingPublicKey: AuthManager.shared.sharingPublicKey
        )

        await drainOutbox(actingUser: actingUser)
        await pullIntoCache(actingUser: actingUser)
        // Re-derive any rows cached without plaintext — notably the copies the
        // keep-both conflict fork adopts undecrypted — so they resolve in THIS
        // sync cycle instead of waiting for the next pull. Mirrors android
        // SyncRepository.sync()'s backfillUndecryptedItems after the pull.
        _ = await backfillUndecryptedItems(actingUser: actingUser)

        // Collect editor-mode pins whose note is gone, so the map in the
        // metadata blob cannot grow forever. Guarded hard, because getting it
        // wrong is silent data loss: never against an empty id set, which is
        // what a fresh install looks like before its first page lands and
        // would wipe every pin the user has on every other device.
        if let vaultKey = AuthManager.shared.vaultKeyBase64 {
            let liveIds = await NoteStore.shared.allNoteIds()
            if !liveIds.isEmpty {
                _ = try? await NotebookMetadataStore.gcPins(
                    liveNoteIds: liveIds, vaultKeyBase64: vaultKey)
            }
        }

        // The store is as fresh as it gets right here — republish the widget
        // snapshot. Every mutation funnel ends in this method (web edits via
        // the shell nudge, share drafts via the consumer above, offline
        // replays via the outbox), so one publish here covers them all.
        WidgetSnapshotPublisher.publish()
    }

    /// Push-only: drain the outbox WITHOUT pulling. Used before the logout
    /// wipe so unsynced offline edits reach the server before the cache is
    /// crypto-shredded. Mirrors android SyncRepository.pushPendingChanges.
    @discardableResult
    func pushPendingChanges() async -> Int {
        guard AuthManager.shared.isAuthenticated else { return 0 }
        // Capture the acting account so a logout / switch mid-drain can't push
        // this user's queued rows under the next user's token.
        let actingUser = KeychainService.shared.getString(for: .userId)
        return await drainOutbox(actingUser: actingUser)
    }

    /// True while the signed-in user is unchanged since the drain began. Every
    /// server push and post-await store write in the outbox guards on this so a
    /// logout / account switch landing mid-drain never pushes account A's queued
    /// rows under account B's token, nor writes A's cleared/adopted rows into B's
    /// freshly-keyed cache. On a mismatch each loop simply stops.
    private func stillActing(_ actingUser: String?) -> Bool {
        KeychainService.shared.getString(for: .userId) == actingUser
    }

    @discardableResult
    private func drainOutbox(actingUser: String?) async -> Int {
        // Order matches android sync(): creates, then edits, then deletes — a row
        // must exist server-side before we PUT an edit or DELETE it. Restores run
        // between creates and edits: un-delete the row server-side BEFORE an edit
        // replay (the server's PUT rejects an edit of a trashed item), so a
        // restore-then-edit offline session lands both.
        let created = await pushDirtyCreates(actingUser: actingUser)
        let restored = await retryRestores(actingUser: actingUser)
        let edited = await retryDirtyEdits(actingUser: actingUser)
        let deleted = await retryDeletes(actingUser: actingUser)
        return created + restored + edited + deleted
    }

    // MARK: - Push

    /// POST every owned dirty (non-deleted) row. The backend's `POST /items` is
    /// create-only: a brand-new offline note is created (201) and its flag
    /// cleared; a dirty EDIT of an already-synced note 409s (`ITEM_ALREADY_EXISTS`)
    /// and is left for `retryDirtyEdits`. Shares are skipped (recipients don't
    /// create). The iOS analog of android SyncRepository.pushDirtyItems (/sync/push).
    private func pushDirtyCreates(actingUser: String?) async -> Int {
        var pushed = 0
        for record in NoteStore.shared.dirtyItems() {
            guard stillActing(actingUser) else { break }  // account switched mid-drain
            if SharesInboxStore.shared.isSharedWithUs(record) { continue }  // an edit, not a create
            let request = CreateItemRequest(
                id: record.id,
                itemType: record.itemType,
                encryptedContent: record.encryptedContent,
                contentNonce: record.contentNonce,
                circleId: record.circleId,
                notebookId: record.notebookId,
                wrappedContentKey: record.wrappedContentKey,
                wrappedContentKeyNonce: record.wrappedContentKeyNonce
            )
            do {
                let created = try await APIService.shared.createItem(request)
                // Discard the cleared-flag write if the account switched during
                // the push — it would re-introduce A's row into B's cache.
                guard stillActing(actingUser) else { break }
                var cleared = record
                cleared.version = created.version
                cleared.updatedAt = created.updatedAt
                cleared.isDirty = false
                // Clear the dirty flag ONLY if the row still holds
                // the ciphertext we just pushed. A concurrent interactive edit
                // landing during the create await re-encrypts the row (new
                // ciphertext, is_dirty=1); a blind upsert(cleared) would stomp it
                // with the OLD content + is_dirty=0 — losing the edit AND dropping it
                // from the outbox. Compare-and-clear inside the writer transaction.
                NoteStore.shared.clearDirtyIfUnchanged(
                    expectedEncryptedContent: record.encryptedContent,
                    expectedContentNonce: record.contentNonce,
                    toWrite: cleared)
                pushed += 1
            } catch let api as APIError where api.status == 409 {
                // Already exists — it's a dirty EDIT; retryDirtyEdits PUTs it.
            } catch {
                // Offline / transient / 402 quota: leave dirty for the next cycle.
            }
        }
        return pushed
    }

    /// PUT every dirty (non-deleted) row that already exists server-side — the
    /// offline-edit replay. Replays the STORED ciphertext (encrypted at edit time
    /// under the right key), not a re-encrypt, matching android
    /// NoteRepository.retryDirtyItems. A shared note omits the wrap fields (only
    /// the owner rotates the wrap). A 409 version conflict on a note WE own forks
    /// keep-both; a shared 409 is left dirty for its interactive
    /// refetch-and-retry path.
    private func retryDirtyEdits(actingUser: String?) async -> Int {
        var pushed = 0
        for record in NoteStore.shared.dirtyItems() {
            guard stillActing(actingUser) else { break }  // account switched mid-drain
            let isShared = SharesInboxStore.shared.isSharedWithUs(record)
            let request = UpdateItemRequest(
                encryptedContent: record.encryptedContent,
                contentNonce: record.contentNonce,
                wrappedContentKey: isShared ? nil : record.wrappedContentKey,
                wrappedContentKeyNonce: isShared ? nil : record.wrappedContentKeyNonce,
                expectedVersion: record.version
            )
            do {
                let server = try await APIService.shared.updateItem(record.id, request)
                // Discard the cleared-flag write if the account switched during
                // the push — it would re-introduce A's row into B's cache.
                guard stillActing(actingUser) else { break }
                var cleared = record
                cleared.version = server.version
                cleared.updatedAt = server.updatedAt
                cleared.isDirty = false
                // Compare-and-clear — see pushDirtyCreates. A
                // concurrent interactive edit landing during the PUT await must not
                // be clobbered by this stale pre-await snapshot; if the row's
                // ciphertext changed, leave it dirty so the newer edit still pushes.
                NoteStore.shared.clearDirtyIfUnchanged(
                    expectedEncryptedContent: record.encryptedContent,
                    expectedContentNonce: record.contentNonce,
                    toWrite: cleared)
                pushed += 1
            } catch let api as APIError where api.status == 409 && !isShared {
                // Genuine concurrent-edit conflict on a note WE own: the server
                // moved past the version our offline edit was based on. Keep BOTH
                // (Dropbox-style) instead of silently losing either side. Mirrors
                // android NoteRepository.retryDirtyItems' `409 && sharedKey == null`
                // branch → resolveConflictKeepBoth. Shared 409s fall through to
                // stay-dirty (their interactive editor resolves via refetch+retry).
                if await resolveConflictKeepBoth(record, actingUser: actingUser) { pushed += 1 }
            } catch let api as APIError where api.status == 403 && isShared {
                // View-only share edited before the read-only gate resolved (or
                // access revoked): the server will NEVER accept it. Clear the flag
                // so it stops retrying every sync. Mirrors android's 403 branch.
                // Owned 403s are LEFT dirty — never drop an owned edit.
                NoteStore.shared.clearDirty([record.id])
            } catch {
                // Shared 409 (interactive path refetches), owned/transient 403,
                // offline / transient: leave dirty for the next drain.
            }
        }
        return pushed
    }

    /// Resolve a concurrent-edit conflict on an OWNED note by keeping BOTH
    /// versions. Forks the LIVE LOCAL row's un-pushable edit into a NEW note
    /// titled "… (conflict copy)" — a fresh id with its own vault-wrapped content
    /// key, so the next create-push lands it cleanly — then resets the original id
    /// to the server's current row WHOLESALE (ciphertext + version + wrap),
    /// stored undecrypted so `backfillUndecryptedItems()` re-derives its
    /// title/body in the same sync. Returns true only when both sides were
    /// preserved; on any failure it returns false and the caller leaves the row
    /// dirty so nothing is lost and we retry next sync. A faithful port of
    /// note-android NoteRepository.resolveConflictKeepBoth.
    private func resolveConflictKeepBoth(_ record: ItemRecord, actingUser: String?) async -> Bool {
        guard let vaultKey = AuthManager.shared.vaultKeyBase64 else { return false }
        // The server's current version for the original id (getItem returns the
        // live row, whether or not it is deleted).
        guard let live = try? await APIService.shared.getItem(record.id) else { return false }
        // Bail if the account switched during the getItem await — both writes
        // below would land account A's conflict fork in B's cache.
        guard stillActing(actingUser) else { return false }
        // Fork from the LIVE LOCAL row re-read AFTER the awaits, not from the
        // pre-PUT drain snapshot: step 2 below adopts the server row WHOLESALE,
        // so any local edit this fork doesn't carry is gone. An interactive edit
        // can land during the failed PUT *or* during the getItem above, and
        // `record` was snapshotted before both (retryDirtyEdits' `dirtyItems()`
        // read). Mirrors note-android NoteRepository.resolveConflictKeepBoth's
        // `val liveLocal = itemDao.getById(item.id) ?: item` — re-reading after
        // the refetch (android re-reads before it) also closes the getItem
        // window. Fall back to the snapshot only if the row vanished (a
        // concurrent hard-delete) so we still preserve something.
        let liveLocal = NoteStore.shared.fetchById(record.id) ?? record
        // A soft-delete landed during the awaits: the user trashed this note, so
        // there is nothing worth forking and the tombstone must survive. Leave
        // the row untouched — `retryDeletes` drains it and `APIService.deleteItem`
        // is version-less, so the stale version is harmless. (This is the
        // `!current.deleted` guard `clearDirtyIfUnchanged` applies at the
        // push-confirm sites; the unconditional write below can't express it.)
        guard !liveLocal.deleted else { return false }
        // An offline restore hasn't been replayed yet, so the 409 we're resolving
        // is the server's PUT refusing an edit of a still-trashed row — NOT a
        // genuine concurrent edit. Adopting `live` here would write the server's
        // tombstone back over the note the user just un-trashed. Leave it for the
        // next drain, whose `retryRestores` runs BEFORE `retryDirtyEdits` and
        // clears the flag on success or 404.
        guard !liveLocal.pendingRestore else { return false }
        // Our un-pushable local edit (the plaintext we cached at edit time).
        guard let localJSON = liveLocal.decryptedContent,
              let localData = localJSON.data(using: .utf8),
              let localNote = try? DecodedNote.decode(from: localData) else { return false }

        // 1. Fork our local edit into a new conflict-copy note. A brand-new id →
        //    its content key is bound to THAT id (AAD v2), and pushDirtyCreates
        //    creates it on the next drain (it's a fresh, non-shared dirty row).
        let copyId = UUID().uuidString.lowercased()
        let copyNote = localNote.withConflictTitle()
        guard let copyPlaintext = try? copyNote.encodeJSON(),
              let copyWrapped = try? NoteCrypto.encryptWithWrappedKey(
                  plaintext: copyPlaintext, vaultKeyBase64: vaultKey, itemId: copyId)
        else { return false }
        let now = Date()
        let copyItem = Item(
            id: copyId,
            userId: liveLocal.userId,
            itemType: liveLocal.itemType,
            encryptedContent: copyWrapped.encryptedContent,
            contentNonce: copyWrapped.contentNonce,
            version: 1,
            createdAt: now,
            updatedAt: now,
            deleted: false,
            deletedAt: nil,
            circleId: liveLocal.circleId,
            contentSize: copyWrapped.encryptedContent.count,
            notebookId: liveLocal.notebookId,
            wrappedContentKey: copyWrapped.wrappedContentKey,
            wrappedContentKeyNonce: copyWrapped.wrappedContentKeyNonce,
            contentKeyGeneration: nil
        )
        NoteStore.shared.upsert(ItemRecord(item: copyItem, note: copyNote, isDirty: true))

        // 2. Accept the server's current row for the original id — ciphertext,
        //    version AND wrap together. Store it undecrypted (decryptedContent /
        //    title nil) + clean; the same sync's backfill re-derives the
        //    plaintext. `prior: liveLocal` keeps the row's local-only columns
        //    (pin/archive/sortOrder/pending_restore) until backfill refreshes
        //    them, matching android's `liveLocal.copy(...)`.
        var adopted = ItemRecord(item: live, note: nil, prior: liveLocal)
        adopted.decryptedContent = nil
        adopted.title = nil
        adopted.isDirty = false
        // UNCONDITIONAL full-row write — do NOT route this through
        // `clearDirtyIfUnchanged`. That helper's raced branch
        // adopts the server VERSION while keeping the row's existing ciphertext,
        // which is only sound where the adopted version's server content IS the
        // content we just pushed — true at the push-confirm callers, false
        // here: `live` came from `getItem`, an edit this device never
        // incorporated. Taking just its version would leave the row claiming
        // "based on vN" while holding content derived from vN-1; the next drain's
        // PUT would then satisfy the server's only lost-update guard (the update
        // matches on `id`, `version` and not-deleted, nothing more)
        // and silently overwrite the other device's edit, and
        // its stale `wrappedContentKey` — sent for owned notes in
        // `retryDirtyEdits` above — would COALESCE back over a content-key
        // rotation, restoring access for a revoked recipient. Writing the whole
        // server row keeps content, version and wrap consistent; nothing is lost
        // because the surviving local edit was just forked into `copyId` above.
        NoteStore.shared.upsert(adopted)
        return true
    }

    /// Replay offline restores: `POST /items/{id}/restore` for every row the user
    /// un-trashed while offline (`pending_restore = 1`). Clears the flag on
    /// success or 404 (already restored / never trashed server-side); leaves it
    /// for the next drain on a transient failure. No android analog — android's
    /// restore is online-only. Needed because the server's `PUT /items` refuses
    /// a deleted row, so a restore can't ride the dirty-edit replay.
    private func retryRestores(actingUser: String?) async -> Int {
        var pushed = 0
        for record in NoteStore.shared.pendingRestoreItems() {
            guard stillActing(actingUser) else { break }  // account switched mid-drain
            do {
                try await APIService.shared.restoreItem(record.id)
                guard stillActing(actingUser) else { break }
                NoteStore.shared.clearPendingRestore([record.id])
                pushed += 1
            } catch let api as APIError where api.status == 404 {
                NoteStore.shared.clearPendingRestore([record.id])
                pushed += 1
            } catch {
                // Offline / transient: leave pending_restore for the next drain.
            }
        }
        return pushed
    }

    /// DELETE every pending tombstone. Clears the flag on success or 404 (already
    /// gone / never synced). Mirrors android NoteRepository.retryDeletedItems.
    private func retryDeletes(actingUser: String?) async -> Int {
        var pushed = 0
        for record in NoteStore.shared.deletedDirtyItems() {
            guard stillActing(actingUser) else { break }  // account switched mid-drain
            do {
                try await APIService.shared.deleteItem(record.id)
                guard stillActing(actingUser) else { break }
                NoteStore.shared.clearDirty([record.id])
                pushed += 1
            } catch let api as APIError where api.status == 404 {
                NoteStore.shared.clearDirty([record.id])
                pushed += 1
            } catch {
                // Offline / transient: leave the tombstone dirty for the next retry.
            }
        }
        return pushed
    }

    // MARK: - Pull

    /// Pull server changes into the SQLCipher cache so a later cold / offline
    /// launch renders them with no network. Owned notes only (shares flow through
    /// the inbox). Runs AFTER the push halves, so a row still dirty here has an
    /// un-pushed local change — the dirty-guard keeps the pulled copy from
    /// clobbering it. Cross-account-guarded at the write. Mirrors android
    /// SyncRepository.pullRemoteChanges.
    private func pullIntoCache(actingUser: String?) async {
        // Incremental pull: resume from the persisted keyset
        // watermark so a launch / foreground / connectivity / push sync fetches
        // only what changed instead of re-downloading + re-decrypting the WHOLE
        // vault every time. A FULL scan (nil watermark) runs whenever the cache is
        // empty — first login or a crypto-shred rebuild — so no rows are missed;
        // the watermark is per-account (Keychain, wiped on logout / switch).
        // syncPullAll still threads the keyset cursor across every page it fetches
        // (the backend returns the OLDEST `limit` items first, so a single page
        // would drop newer notes).
        // Make any RECOVERED pre-reset identity available before decrypting.
        // Note's vault key is derived from the account keypair, so a password
        // reset makes every older note fail to unwrap — without this the pull
        // succeeds and the notes land as undecryptable rows.
        await PreviousIdentityLoader.shared.ensureLoaded()

        let keychain = KeychainService.shared
        let useWatermark = NoteStore.shared.hasAnyRow()
        let sinceRaw = useWatermark ? keychain.getString(for: .syncCursor) : nil
        let sinceId = useWatermark ? keychain.getString(for: .syncCursorId) : nil
        guard let page = try? await APIService.shared.syncPullAll(
            sinceRaw: sinceRaw, sinceId: sinceId, limit: 200) else { return }
        let items = page.items
        let vaultKey = AuthManager.shared.vaultKeyBase64
        // Decrypt off the main actor (libsodium + JSON per item; the whole vault).
        let decoded: [(Item, DecodedNote?)] = await Task.detached {
            items.map { ($0, Self.decode($0, vaultKeyBase64: vaultKey)) }
        }.value
        // Cross-account guard: if the signed-in user changed while this page was
        // being fetched + decrypted (logout / account switch mid-sync), discard
        // it — writing now would land account A's plaintext in account B's cache.
        // Mirrors android SyncRepository's acting-user guard.
        guard KeychainService.shared.getString(for: .userId) == actingUser else { return }
        let records: [ItemRecord] = decoded.compactMap { (item, note) in
            // Shares are re-sourced from the inbox, never cached (a revoked one
            // would leak offline). But an item our vault opened is ours, whatever
            // the inbox names (see leftToTheInbox).
            guard !Self.leftToTheInbox(openedByOurVault: note != nil, inboxNamesIt: SharesInboxStore.shared.isShared(item.id)) else { return nil }
            // Dirty-guard: never overwrite a row with un-pushed local changes —
            // a dirty create/edit, OR an offline restore not yet replayed (whose
            // server copy is still `deleted = TRUE` and would re-trash the row
            // the user just restored). SyncService replays them instead.
            if let local = NoteStore.shared.fetchById(item.id),
               local.isDirty || local.pendingRestore { return nil }
            if note != nil { return ItemRecord(item: item, note: note) }
            // Undecryptable now: only refresh a row we already cache (keep its
            // last-known-good plaintext), never blank it.
            guard let prior = NoteStore.shared.fetchById(item.id) else { return nil }
            return ItemRecord(item: item, note: nil, prior: prior)
        }
        // Write the whole-vault reconcile off the main actor (the blocking
        // SQLite transaction, not just the decrypt), and re-check the
        // dirty / pending-restore guard INSIDE the write transaction so an
        // interactive offline edit that landed in the gap between the read-side
        // guard above and this deferred write is not clobbered (dirty-clobber
        // TOCTOU). The read-side check still builds the records (and the prior-
        // plaintext path); the in-transaction re-read is authoritative.
        await NoteStore.shared.upsertPreservingDirtyOffMain(records)
        // Advance the watermark AFTER the write committed and only while still the
        // same account (the cross-account guard above holds). Persist only a real
        // cursor — a single-page vault yields nil, and there's nothing to resume.
        if let cursor = page.cursor {
            try? keychain.save(cursor, for: .syncCursor)
            if let cursorId = page.cursorId { try? keychain.save(cursorId, for: .syncCursorId) }
        }
    }

    /// Does the pull leave this item to the inbox? A share is never cached (a
    /// revoked one would leak offline), but an item our vault opened is ours,
    /// whatever the inbox names: it is cached, and the next refresh sees the row
    /// and refuses the share naming it. Skipping it instead would let a share
    /// naming one of ours before its first pull keep it out of the cache for
    /// good.
    nonisolated static func leftToTheInbox(openedByOurVault: Bool, inboxNamesIt: Bool) -> Bool {
        inboxNamesIt && !openedByOurVault
    }

    /// Vault-decrypt an owned item to its decoded note (nil on any failure), so
    /// the pull can run off the main actor. Shares aren't decrypted here (they
    /// need the inbox key and aren't cached).
    nonisolated private static func decode(_ item: Item, vaultKeyBase64 vaultKey: String?) -> DecodedNote? {
        guard let vaultKey else { return nil }
        guard let plaintext = try? NoteCrypto.decrypt(item, vaultKeyBase64: vaultKey),
              let note = try? DecodedNote.decode(from: plaintext) else { return nil }
        return note
    }

    // MARK: - Backfill

    /// Re-decrypt cached rows we hold ciphertext for but no plaintext (arrived
    /// undecryptable earlier — notably the copies the keep-both conflict fork
    /// adopts undecrypted, and rows pulled while the vault key was momentarily
    /// unavailable), updating the cache in place. Owned rows only — shares are
    /// never cached — so the vault path (`decode`, which handles both the wrapped
    /// and legacy frames) suffices. A faithful port of note-android
    /// SyncRepository.backfillUndecryptedItems; runs after the pull in `sync()`.
    @discardableResult
    private func backfillUndecryptedItems(actingUser: String?) async -> Int {
        guard let vaultKey = AuthManager.shared.vaultKeyBase64 else { return 0 }
        let undecrypted = NoteStore.shared.undecryptedItems()
        guard !undecrypted.isEmpty else { return 0 }
        // Decrypt off the main actor (libsodium + JSON per row). Preserve each
        // row's dirty/pending flags (via `prior`) so backfill never clears the
        // outbox — it only fills in the missing plaintext + display columns.
        let updated: [ItemRecord] = await Task.detached {
            undecrypted.compactMap { record -> ItemRecord? in
                let item = record.toItem()
                guard let note = Self.decode(item, vaultKeyBase64: vaultKey) else { return nil }
                return ItemRecord(item: item, note: note, prior: record, isDirty: record.isDirty)
            }
        }.value
        guard !updated.isEmpty else { return 0 }
        // Cross-account guard (mirrors pullIntoCache + android): a logout / account
        // switch can land mid-sync between reading the undecrypted rows and writing
        // their plaintext back — never persist this account's content elsewhere.
        guard KeychainService.shared.getString(for: .userId) == actingUser else { return 0 }
        // Off-main SQLite write (the batch can span the whole vault).
        // Use the dirty-preserving write for consistency with the
        // pull reconcile — it re-checks each row's dirty state INSIDE the
        // transaction, so an interactive edit that raced this backfill (filling the
        // row's plaintext + marking it dirty after `undecryptedItems()` was read) is
        // not clobbered by the re-derived stale snapshot. No false skips: a dirty
        // row always carries plaintext, so it is never in `undecryptedItems()`.
        await NoteStore.shared.upsertPreservingDirtyOffMain(updated)
        return updated.count
    }
}

private extension DecodedNote {
    /// Append a "(conflict copy)" marker to the note's title so the forked copy
    /// is recognisable in the list. Mirrors android
    /// NoteRepository.withConflictTitle (blank title → "Conflict copy").
    func withConflictTitle() -> DecodedNote {
        let base = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let newTitle = base.isEmpty ? "Conflict copy" : "\(title) (conflict copy)"
        return DecodedNote(
            title: newTitle,
            body: body,
            noteType: noteType,
            isPinned: isPinned,
            isArchived: isArchived,
            labels: labels,
            sortOrder: sortOrder,
            editMode: editMode,
            extras: extras
        )
    }
}
