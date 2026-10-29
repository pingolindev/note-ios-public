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
import GRDB

/// SQLCipher-encrypted local store for the note read cache (offline
/// support). The iOS analog of note-android's `NoteDatabase` (Room +
/// SQLCipher).
///
/// The whole database file is encrypted at rest with a 32-byte passphrase held
/// in the Keychain (`KeychainService.localDatabaseKey()`), so it is safe to
/// persist decrypted plaintext (`ItemRecord.decryptedContent`) next to the
/// ciphertext.
///
/// Resilient by design: if the store can't be opened — passphrase wiped by a
/// prior logout, corruption, or a first run before the keychain is unlocked —
/// it degrades to a no-op. The app keeps working online (just without the
/// offline cache) and self-heals by rebuilding the cache from the server on
/// the next sync.
final class NoteStore {
    static let shared = NoteStore()

    private var dbQueue: DatabaseQueue?

    private init() {
        self.dbQueue = Self.openOrRebuild()
    }

    // MARK: - Opening

    private static func databaseURL() throws -> URL {
        let dir = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true)
        return dir.appendingPathComponent("note-cache.sqlite")
    }

    private static func makeQueue(url: URL, key: Data) throws -> DatabaseQueue {
        var config = GRDB.Configuration()
        config.prepareDatabase { db in
            // Raw 32-byte passphrase (SQLCipher KDFs it, like android's
            // SupportOpenHelperFactory(ByteArray)).
            try db.usePassphrase(key)
        }
        let queue = try DatabaseQueue(path: url.path, configuration: config)
        // Force a keyed DB access now so a wrong passphrase surfaces here
        // (SQLITE_NOTADB) rather than on the first read.
        try migrator.migrate(queue)
        return queue
    }

    private static func openOrRebuild() -> DatabaseQueue? {
        let key: Data
        let url: URL
        do {
            key = try KeychainService.shared.localDatabaseKey()
            url = try databaseURL()
        } catch {
            return nil
        }
        do {
            return try makeQueue(url: url, key: key)
        } catch {
            // Wrong passphrase (e.g. the key was rotated after a logout wipe)
            // or corruption: crypto-shred the stale file and rebuild it empty.
            // The cache is disposable — the next sync repopulates it.
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: url.path + suffix)
            }
            return try? makeQueue(url: url, key: key)
        }
    }

    // MARK: - Migrations

    private static let migrator: DatabaseMigrator = {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_items") { db in
            try db.create(table: ItemRecord.databaseTableName) { t in
                t.column("id", .text).primaryKey()
                t.column("user_id", .text).notNull()
                t.column("item_type", .integer).notNull()
                t.column("encrypted_content", .text).notNull()
                t.column("content_nonce", .text).notNull()
                t.column("decrypted_content", .text)
                t.column("title", .text)
                t.column("version", .integer).notNull().defaults(to: 1)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
                t.column("deleted", .boolean).notNull().defaults(to: false)
                t.column("deleted_at", .datetime)
                t.column("circle_id", .text)
                t.column("notebook_id", .text)
                t.column("content_size", .integer).notNull().defaults(to: 0)
                t.column("color", .text)
                t.column("is_pinned", .boolean).notNull().defaults(to: false)
                t.column("is_archived", .boolean).notNull().defaults(to: false)
                t.column("is_dirty", .boolean).notNull().defaults(to: false)
                t.column("wrapped_content_key", .text)
                t.column("wrapped_content_key_nonce", .text)
                t.column("sort_order", .integer).notNull().defaults(to: 0)
                t.column("content_key_generation", .integer)
            }
            // Covers the active-notes filter + ordering
            // (mirrors android observeActiveNotes).
            try db.create(
                index: "idx_items_active",
                on: ItemRecord.databaseTableName,
                columns: ["item_type", "deleted", "is_archived",
                          "is_pinned", "sort_order", "updated_at"])
        }
        // Offline restore: a note un-trashed offline can't ride the
        // dirty-edit replay (the server's `PUT /items` refuses a deleted
        // row), so it needs its own outbox state, replayed via
        // `POST /items/{id}/restore`. Additive column, default false — the
        // cache is disposable, so an alter-fail just rebuilds it empty.
        migrator.registerMigration("v2_pending_restore") { db in
            try db.alter(table: ItemRecord.databaseTableName) { t in
                t.add(column: "pending_restore", .boolean).notNull().defaults(to: false)
            }
        }
        // Server-computed share state for the "Shared" badge. Additive, default
        // false; the next /sync/pull fills in the real value, so the badge
        // appears a moment later rather than a migration guessing it. Mirrors
        // android's Room migration 4->5.
        migrator.registerMigration("v3_shared_by_me") { db in
            try db.alter(table: ItemRecord.databaseTableName) { t in
                t.add(column: "shared_by_me", .boolean).notNull().defaults(to: false)
            }
        }
        return migrator
    }()

    // MARK: - Writes

    /// Insert or replace a record (keyed by id). Room analog:
    /// `ItemDao.upsert(@Insert OnConflictStrategy.REPLACE)`.
    func upsert(_ record: ItemRecord) {
        guard let dbQueue else { return }
        try? dbQueue.write { db in try record.save(db) }
    }

    /// Batch upsert — one transaction for a whole sync page.
    func upsert(_ records: [ItemRecord]) {
        guard let dbQueue, !records.isEmpty else { return }
        try? dbQueue.write { db in
            for record in records { try record.save(db) }
        }
    }

    /// Off-main batch upsert. `dbQueue.write` runs the SQLite
    /// transaction on GRDB's writer queue but BLOCKS the calling thread until it
    /// commits — a whole-vault reconcile would therefore jank the main actor even
    /// with the decrypt already moved off-main. Hop onto a background
    /// executor for the (blocking) write; awaiting `.value` preserves caller
    /// ordering, so the observation the list renders from still fires only after
    /// the commit. The DatabaseQueue serializes writes internally, so this stays
    /// safe to interleave with the synchronous `upsert`.
    func upsertOffMain(_ records: [ItemRecord]) async {
        guard dbQueue != nil, !records.isEmpty else { return }
        await Task.detached(priority: .utility) { [records] in
            NoteStore.shared.upsert(records)
        }.value
    }

    /// Off-main batch upsert that RE-CHECKS the dirty / pending-restore guard
    /// INSIDE the write transaction. A reconcile that reads
    /// `isDirty` while BUILDING its records and only commits them later (a split
    /// fetch-then-upsert, as `pullIntoCache` does) leaves a
    /// TOCTOU window: an interactive offline edit landing in the gap marks the row
    /// dirty AFTER the snapshot was taken, then the stale non-dirty snapshot
    /// commits and clears `is_dirty` — silently dropping the edit on the next
    /// pull. Re-reading each row inside the SAME serialized writer transaction
    /// makes the guard's read atomic with the write, so a row that became dirty
    /// (or pending-restore) in the gap is skipped, not overwritten. Same off-main
    /// hop + queue-serialization guarantees as `upsertOffMain`.
    func upsertPreservingDirtyOffMain(_ records: [ItemRecord]) async {
        guard dbQueue != nil, !records.isEmpty else { return }
        await Task.detached(priority: .utility) { [records] in
            NoteStore.shared.upsertPreservingDirty(records)
        }.value
    }

    /// Synchronous core of `upsertPreservingDirtyOffMain` (see its docs).
    func upsertPreservingDirty(_ records: [ItemRecord]) {
        guard let dbQueue, !records.isEmpty else { return }
        try? dbQueue.write { db in
            for record in records {
                // Re-read the CURRENT row inside the transaction: a row that
                // became dirty or pending-restore after the caller built `records`
                // holds an un-pushed local change (SyncService replays it), so it
                // must be kept, not clobbered by the stale server snapshot.
                if let local = try ItemRecord.fetchOne(db, key: record.id),
                   local.isDirty || local.pendingRestore {
                    continue
                }
                try record.save(db)
            }
        }
    }

    /// Hard-remove a row outright (no tombstone). Used to drop a materialized
    /// shared note once its share leaves the inbox (un-share / owner-delete) — a
    /// recipient never "trashes" someone else's note, so it's removed rather than
    /// soft-deleted. Mirrors android `ItemDao.deleteById`. A user-initiated delete
    /// of an OWNED note goes through `softDelete` so the delete replays to the
    /// server.
    func deleteById(_ id: String) {
        guard let dbQueue else { return }
        _ = try? dbQueue.write { db in try ItemRecord.deleteOne(db, key: id) }
    }

    // MARK: - Outbox (offline support)
    //
    // The iOS analog of note-android's `ItemDao` dirty-queue surface. A local
    // create/edit sets `is_dirty = 1` (the row is queued for a server push); a
    // delete sets `deleted = 1, is_dirty = 1` (a tombstone queued for a server
    // DELETE). `SyncService` drains this queue on reconnect and clears the flag.

    /// Active (non-deleted) rows with un-pushed local changes — offline creates
    /// and edits. `is_dirty = 1 AND deleted = 0`, oldest-first so the queue
    /// drains in write order. Mirrors android `ItemDao.getDirtyItems` (filtered
    /// to non-deleted, as `getDirtyItemsPaged` does).
    func dirtyItems() -> [ItemRecord] {
        guard let dbQueue else { return [] }
        return (try? dbQueue.read { db in
            try ItemRecord
                .filter(ItemRecord.Columns.isDirty == true
                        && ItemRecord.Columns.deleted == false)
                .order(ItemRecord.Columns.updatedAt.asc)
                .fetchAll(db)
        }) ?? []
    }

    /// Paged variant of `dirtyItems` for a large offline backlog. Mirrors
    /// android `ItemDao.getDirtyItemsPaged`.
    func dirtyItemsPaged(limit: Int, offset: Int) -> [ItemRecord] {
        guard let dbQueue else { return [] }
        return (try? dbQueue.read { db in
            try ItemRecord
                .filter(ItemRecord.Columns.isDirty == true
                        && ItemRecord.Columns.deleted == false)
                .order(ItemRecord.Columns.updatedAt.asc)
                .limit(limit, offset: offset)
                .fetchAll(db)
        }) ?? []
    }

    /// Soft-deleted rows whose delete hasn't reached the server yet — pending
    /// tombstones. `is_dirty = 1 AND deleted = 1`. Mirrors android
    /// `ItemDao.getDeletedDirtyItems`.
    func deletedDirtyItems() -> [ItemRecord] {
        guard let dbQueue else { return [] }
        return (try? dbQueue.read { db in
            try ItemRecord
                .filter(ItemRecord.Columns.isDirty == true
                        && ItemRecord.Columns.deleted == true)
                .fetchAll(db)
        }) ?? []
    }

    /// Soft-delete: `deleted = 1, is_dirty = 1, updated_at = now`. The row drops
    /// out of the active-notes query immediately (offline feedback) and the
    /// delete is queued for the server, replayed by `SyncService.retryDeletes`.
    /// Mirrors android `ItemDao.softDelete`.
    func softDelete(_ id: String) {
        guard let dbQueue else { return }
        _ = try? dbQueue.write { db in
            try db.execute(
                sql: "UPDATE items SET deleted = 1, is_dirty = 1, updated_at = ? WHERE id = ?",
                arguments: [Date(), id])
        }
    }

    /// Clear the outbox flag for the given ids after a successful push. Mirrors
    /// android `ItemDao.clearDirtyFlags`.
    func clearDirty(_ ids: [String]) {
        guard let dbQueue, !ids.isEmpty else { return }
        try? dbQueue.write { db in
            for id in ids {
                try db.execute(sql: "UPDATE items SET is_dirty = 0 WHERE id = ?",
                               arguments: [id])
            }
        }
    }

    /// Confirm a PUSHED outbox row. `expectedEncryptedContent` /
    /// `expectedContentNonce` are the ciphertext values snapshotted BEFORE the
    /// network await; `toWrite.version` is the version the
    /// server assigned to THAT ciphertext (every caller sets it from the create /
    /// update response for the very push it is confirming).
    ///
    /// CALLER CONTRACT — the unconditional version-adopt below is sound ONLY when
    /// `toWrite.version`'s server-side content IS the ciphertext we just pushed,
    /// i.e. a known ancestor of whatever the row now holds. That is true at a
    /// push-confirm site and nowhere else. NEVER pass a version fetched from a
    /// FOREIGN row (`getItem` on a conflicting edit): the row would then claim to
    /// be based on a version whose content it does not descend from, its next PUT
    /// would pass the server's compare-and-swap on `version`, and it would
    /// silently destroy the other device's edit. The keep-both conflict resolver
    /// (`SyncService.resolveConflictKeepBoth`) therefore adopts the server row
    /// WHOLESALE with a plain `upsert` instead of calling this.
    ///
    /// Two outcomes, atomic inside the writer transaction:
    ///
    ///  • Row UNCHANGED — still holds exactly the pushed ciphertext AND was not
    ///    soft-deleted during the push → adopt the server row wholesale (`toWrite`:
    ///    version + updated_at + display columns) and clear the dirty flag.
    ///
    ///  • Row CHANGED (a concurrent interactive edit re-encrypted it → different
    ///    ciphertext) OR concurrently SOFT-DELETED during the push → adopt the
    ///    server `version` UNCONDITIONALLY, but leave the newer ciphertext /
    ///    decrypted content / is_dirty=1 (and any soft-delete tombstone) untouched.
    ///    Adopting the version means the racing edit's NEXT drain PUTs
    ///    `expectedVersion = <server version>` and lands cleanly, instead of
    ///    replaying the STALE pre-push version, 409ing, and forking a spurious
    ///    "(conflict copy)" duplicate. Returning without writing here would leave
    ///    the surviving dirty row on its stale version, guaranteeing a 409-fork on
    ///    the next drain.
    ///
    /// A faithful port of note-android `ItemDao.adoptVersionClearDirtyIfUnchanged`
    /// (version always adopted; is_dirty cleared only on the unchanged + `deleted =
    /// 0` branch). The `!deleted` guard preserves a concurrent, still-unpushed
    /// soft-delete's is_dirty=1 — `softDelete` leaves the ciphertext intact, so a
    /// bare ciphertext compare would wrongly clear it and silently drop the
    /// tombstone from the delete drain. Adopting a version on a to-be-deleted row
    /// is harmless: the delete drain (`retryDeletes` → `APIService.deleteItem`) is
    /// version-less. Re-reading inside the writer transaction makes the compare
    /// atomic with the write. Do NOT route the drain's confirm-write through
    /// `upsertPreservingDirty`: the drained row is itself dirty, so that guard would
    /// never let it clear.
    func clearDirtyIfUnchanged(expectedEncryptedContent: String,
                               expectedContentNonce: String,
                               toWrite: ItemRecord) {
        guard let dbQueue else { return }
        try? dbQueue.write { db in
            guard let current = try ItemRecord.fetchOne(db, key: toWrite.id) else { return }
            if current.encryptedContent == expectedEncryptedContent,
               current.contentNonce == expectedContentNonce,
               !current.deleted {
                // Unchanged, active row: adopt the server row + clear the flag.
                try toWrite.save(db)
            } else {
                // Raced (re-edited) or soft-deleted during the push: adopt ONLY the
                // server version so the next drain sends the correct expectedVersion
                // and lands cleanly; leave the newer ciphertext / decrypted content /
                // is_dirty / tombstone exactly as they are so nothing is lost.
                try db.execute(
                    sql: "UPDATE items SET version = ? WHERE id = ?",
                    arguments: [toWrite.version, toWrite.id])
            }
        }
    }

    /// Restore a soft-deleted row: `deleted = 0, is_dirty = 0, updated_at = now`.
    /// Called only after the server restore succeeds (no pending delete to push).
    /// Mirrors android `ItemDao.restore`.
    func restore(_ id: String) {
        guard let dbQueue else { return }
        _ = try? dbQueue.write { db in
            try db.execute(
                sql: "UPDATE items SET deleted = 0, is_dirty = 0, updated_at = ? WHERE id = ?",
                arguments: [Date(), id])
        }
    }

    /// Offline-first restore: un-tombstone the row (`deleted = 0`) and
    /// mark it `pending_restore = 1` so `SyncService.retryRestores` replays the
    /// `POST /items/{id}/restore` when the server can be reached. The note
    /// leaves Trash and returns to the active list immediately. `is_dirty` is
    /// left untouched (0 for a synced trashed note) so this restore is NEVER
    /// mistaken for a dirty edit — the server's `PUT /items` refuses a deleted
    /// row, so a dirty-edit replay would 409 and spawn a spurious keep-both
    /// conflict copy.
    func restoreLocally(_ id: String) {
        guard let dbQueue else { return }
        _ = try? dbQueue.write { db in
            try db.execute(
                sql: "UPDATE items SET deleted = 0, pending_restore = 1, updated_at = ? WHERE id = ?",
                arguments: [Date(), id])
        }
    }

    /// Rows the user un-trashed offline, awaiting a server restore replay.
    /// `pending_restore = 1`. No android analog (android restore is online-only).
    func pendingRestoreItems() -> [ItemRecord] {
        guard let dbQueue else { return [] }
        return (try? dbQueue.read { db in
            try ItemRecord
                .filter(ItemRecord.Columns.pendingRestore == true)
                .fetchAll(db)
        }) ?? []
    }

    /// Clear the offline-restore flag after a successful `POST .../restore`
    /// (or a 404 — already restored / never trashed server-side).
    func clearPendingRestore(_ ids: [String]) {
        guard let dbQueue, !ids.isEmpty else { return }
        try? dbQueue.write { db in
            for id in ids {
                try db.execute(sql: "UPDATE items SET pending_restore = 0 WHERE id = ?",
                               arguments: [id])
            }
        }
    }

    /// Cached rows we hold ciphertext for but no decrypted plaintext — arrived
    /// undecryptable earlier (e.g. the keep-both conflict fork stores the
    /// server's version undecrypted for backfill to re-derive in the same sync).
    /// `decrypted_content IS NULL AND deleted = 0`. Mirrors android
    /// `ItemDao.getUndecryptedItems`.
    func undecryptedItems() -> [ItemRecord] {
        guard let dbQueue else { return [] }
        return (try? dbQueue.read { db in
            try ItemRecord
                .filter(ItemRecord.Columns.decryptedContent == nil
                        && ItemRecord.Columns.deleted == false)
                .fetchAll(db)
        }) ?? []
    }

    /// Crypto-shred the cache content: clear every row so account B on the same
    /// device can't read account A's cached plaintext (decrypted body + title).
    /// This ONLY deletes rows — it does NOT touch the passphrase or close the
    /// open queue. In `logout()` it runs while the queue is still valid, and is
    /// then followed by `keychain.deleteAll()` (which DESTROYS `.localDbKey`) and
    /// `reopen()` (which re-establishes a fresh-keyed empty queue so the next
    /// login writes under a passphrase the next launch can reproduce). Mirrors
    /// android `LocalDataWiper` → `database.clearAllTables()`. MUST run before
    /// the keychain passphrase is wiped (the open queue is still valid here).
    func wipe() {
        guard let dbQueue else { return }
        _ = try? dbQueue.write { db in try ItemRecord.deleteAll(db) }
    }

    /// Re-open the cache against the CURRENT keychain passphrase, rebuilding the
    /// file from scratch when that passphrase changed out from under the queue
    /// opened in `init`. `logout()` deletes `.localDbKey` via
    /// `keychain.deleteAll()`, so the next `localDatabaseKey()` here MINTS a fresh
    /// passphrase and `openOrRebuild()`'s wrong-key path crypto-shreds the stale
    /// file and recreates it empty under that new key. Without this the queue
    /// would keep the OLD (now-orphaned) passphrase in memory: a same-process
    /// re-login would write the next account's rows + outbox under a key the next
    /// launch can't reproduce, and that launch's wrong-key rebuild would
    /// crypto-shred those un-pushed offline edits. Drop our reference first so the
    /// stale connection can close before the rebuild (an in-flight observation
    /// keeps its own reference until it ends). No-op-safe: a nil rebuild just
    /// leaves the store degraded, exactly like `init`.
    func reopen() {
        dbQueue = nil
        dbQueue = Self.openOrRebuild()
    }

    // MARK: - Reads

    /// One-shot active notes (used to seed an instant launch synchronously).
    func fetchActiveNotes() -> [ItemRecord] {
        guard let dbQueue else { return [] }
        return (try? dbQueue.read { db in
            try ItemRecord.activeNotesRequest().fetchAll(db)
        }) ?? []
    }

    /// Every note id this device holds, INCLUDING trashed ones — a note in the
    /// trash can be restored, so its editor-mode pin must survive with it.
    /// Feeds the pin GC, which needs the FULL set: a partial one would collect
    /// pins for notes merely absent from it.
    func allNoteIds() -> Set<String> {
        guard let dbQueue else { return [] }
        let ids = (try? dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM items WHERE item_type = 1")
        }) ?? []
        return Set(ids)
    }

    func fetchById(_ id: String) -> ItemRecord? {
        guard let dbQueue else { return nil }
        return try? dbQueue.read { db in try ItemRecord.fetchOne(db, key: id) }
    }

    /// True when the cache holds at least one row. Gates incremental
    /// (watermark-based) pulls: an EMPTY cache — fresh login,
    /// or a crypto-shred rebuild — must do a FULL server scan so no rows are
    /// missed, regardless of any stale watermark. A non-empty cache means a prior
    /// full scan populated it, so a delta from the persisted cursor is safe.
    func hasAnyRow() -> Bool {
        guard let dbQueue else { return false }
        // LIMIT 1 existence probe (stops at the first row) rather than a full
        // COUNT(*) — this runs on the calling (main) actor.
        return (try? dbQueue.read { db in
            try ItemRecord.limit(1).fetchOne(db) != nil
        }) ?? false
    }

    /// Live active-notes stream — the analog of android
    /// `ItemDao.observeActiveNotes(): Flow<List<ItemEntity>>`. Emits the current
    /// cached rows immediately (instant launch / offline read), then again on
    /// every change. Returns `nil` when the store failed to open, so the caller
    /// falls back to network-only.
    func observeActiveNotes() -> AsyncValueObservation<[ItemRecord]>? {
        guard let dbQueue else { return nil }
        return ValueObservation
            .tracking { db in try ItemRecord.activeNotesRequest().fetchAll(db) }
            .values(in: dbQueue)
    }

    /// Live trashed-notes stream — the analog of android
    /// `ItemDao.observeTrash(): Flow<List<ItemEntity>>`. Offline trash:
    /// emits the cached `deleted = 1` rows so Trash is viewable with no network
    /// (includes notes deleted offline whose tombstone hasn't reached the
    /// server yet). `nil` when the store failed to open.
    func observeTrash() -> AsyncValueObservation<[ItemRecord]>? {
        guard let dbQueue else { return nil }
        return ValueObservation
            .tracking { db in try ItemRecord.trashedNotesRequest().fetchAll(db) }
            .values(in: dbQueue)
    }

    /// Live notebooks stream — the analog of android
    /// `ItemDao.observeNotebooks(): Flow<List<ItemEntity>>`. Offline
    /// notebooks: emits the cached `item_type = 2` rows (including notebooks
    /// created offline, still queued for the server) so the notebook filter
    /// renders with no network. `nil` when the store failed to open.
    func observeNotebooks() -> AsyncValueObservation<[ItemRecord]>? {
        guard let dbQueue else { return nil }
        return ValueObservation
            .tracking { db in try ItemRecord.notebooksRequest().fetchAll(db) }
            .values(in: dbQueue)
    }
}
