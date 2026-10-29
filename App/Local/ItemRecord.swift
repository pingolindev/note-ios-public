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

/// Local, SQLCipher-encrypted representation of an encrypted note item.
///
/// The iOS analog of the Android app's `ItemEntity`: it stores BOTH the
/// encrypted blob (the sync source of truth, sent to/from the server) AND the
/// decrypted plaintext cache + denormalized display columns (title / is_pinned
/// / is_archived / sort_order). Persisting plaintext is only safe because the
/// whole database file is SQLCipher-encrypted at rest (see `NoteStore`) — the
/// plaintext never leaves this device, and it is crypto-shredded on logout when
/// the DB passphrase is wiped.
///
/// Column names are snake_case (via `CodingKeys`) so the schema reads like the
/// android `items` table; the iOS database is independent of android's file.
struct ItemRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "items"

    /// `item_type == 1` (a note). Kept local so this record layer doesn't
    /// depend on the app's `ItemType` enum.
    static let noteItemType = 1
    /// `item_type == 2` (a notebook). Mirrors `ItemType.notebook`.
    static let notebookItemType = 2

    var id: String
    var userId: String
    /// 1 = note, 2 = notebook, 3 = label (mirrors `ItemType`).
    var itemType: Int
    /// Encrypted content blob (base64) — synced to/from the server.
    var encryptedContent: String
    var contentNonce: String
    /// Decrypted content JSON — LOCAL ONLY, never synced. Lets an offline or
    /// cold launch render notes without the vault key (a plain JSON decode).
    var decryptedContent: String?
    /// Decrypted title, denormalized for list display / search.
    var title: String?
    var version: Int64
    var createdAt: Date
    var updatedAt: Date
    var deleted: Bool
    var deletedAt: Date?
    var circleId: String?
    var notebookId: String?
    var contentSize: Int
    /// Color extracted from decrypted content for local display. Reserved for
    /// parity with android; nothing sets it.
    var color: String?
    var isPinned: Bool
    var isArchived: Bool
    /// Dirty flag: modified locally, needs sync push (the offline-write
    /// outbox). A pulled or confirmed row is false.
    var isDirty: Bool
    /// Offline restore: the user un-trashed this row while offline (`deleted
    /// = 0` locally, but still `deleted = TRUE` server-side). It is NOT a
    /// dirty edit — the server's `PUT /items` refuses to touch a deleted row,
    /// so an edit replay can't un-delete — so a dedicated
    /// `SyncService.retryRestores` replays it via `POST /items/{id}/restore`.
    /// Kept distinct from `isDirty` so a restore never falls into the
    /// keep-both conflict fork. (iOS-only; the Android app restores online
    /// only.)
    var pendingRestore: Bool
    var wrappedContentKey: String?
    var wrappedContentKeyNonce: String?
    /// User drag order. Denormalized from the encrypted note body so the query
    /// can `ORDER BY` without decrypting. Mirrors android `ItemEntity.sortOrder`.
    var sortOrder: Int
    /// Monotonic per-item content-key generation, as the server keeps it.
    /// Bound into the share-wrap signature; `nil`/base 1 for rows from
    /// before generations existed.
    var contentKeyGeneration: Int64?
    /// Server-computed share state, cached so the list can badge shared notes
    /// offline like every other denormalized display field here. Refreshed on
    /// each sync; never set by a local edit. Mirrors android
    /// `ItemEntity.sharedByMe`.
    var sharedByMe: Bool = false

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case itemType = "item_type"
        case encryptedContent = "encrypted_content"
        case contentNonce = "content_nonce"
        case decryptedContent = "decrypted_content"
        case title
        case version
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deleted
        case deletedAt = "deleted_at"
        case circleId = "circle_id"
        case notebookId = "notebook_id"
        case contentSize = "content_size"
        case color
        case isPinned = "is_pinned"
        case isArchived = "is_archived"
        case isDirty = "is_dirty"
        case pendingRestore = "pending_restore"
        case wrappedContentKey = "wrapped_content_key"
        case wrappedContentKeyNonce = "wrapped_content_key_nonce"
        case sortOrder = "sort_order"
        case contentKeyGeneration = "content_key_generation"
        case sharedByMe = "shared_by_me"
    }

    /// Typed column references for the query interface.
    enum Columns {
        static let id = Column(CodingKeys.id.stringValue)
        static let itemType = Column(CodingKeys.itemType.stringValue)
        static let deleted = Column(CodingKeys.deleted.stringValue)
        static let isArchived = Column(CodingKeys.isArchived.stringValue)
        static let isPinned = Column(CodingKeys.isPinned.stringValue)
        static let sortOrder = Column(CodingKeys.sortOrder.stringValue)
        static let updatedAt = Column(CodingKeys.updatedAt.stringValue)
        /// Outbox flag: row has an un-pushed local create/edit/delete.
        static let isDirty = Column(CodingKeys.isDirty.stringValue)
        /// Offline-restore flag: row un-trashed offline, awaiting a
        /// `POST /items/{id}/restore` replay.
        static let pendingRestore = Column(CodingKeys.pendingRestore.stringValue)
        static let decryptedContent = Column(CodingKeys.decryptedContent.stringValue)
        static let encryptedContent = Column(CodingKeys.encryptedContent.stringValue)
        static let notebookId = Column(CodingKeys.notebookId.stringValue)
    }

    /// Active notes: `item_type = note AND !deleted AND !archived`,
    /// `ORDER BY is_pinned DESC, sort_order ASC, updated_at DESC`.
    /// The iOS analog of android `ItemDao.observeActiveNotes`.
    static func activeNotesRequest() -> QueryInterfaceRequest<ItemRecord> {
        ItemRecord
            .filter(Columns.itemType == noteItemType
                    && Columns.deleted == false
                    && Columns.isArchived == false)
            .order(Columns.isPinned.desc,
                   Columns.sortOrder.asc,
                   Columns.updatedAt.desc)
    }

    /// Trashed notes: `item_type = note AND deleted`, `ORDER BY sort_order ASC,
    /// updated_at DESC`. The iOS analog of android `ItemDao.observeTrash`
    /// (the offline trash surface — includes offline-deleted tombstones still
    /// queued for the server).
    static func trashedNotesRequest() -> QueryInterfaceRequest<ItemRecord> {
        ItemRecord
            .filter(Columns.itemType == noteItemType && Columns.deleted == true)
            .order(Columns.sortOrder.asc, Columns.updatedAt.desc)
    }

    /// Notebooks: `item_type = notebook AND !deleted`, `ORDER BY updated_at
    /// DESC`. The iOS analog of android `ItemDao.observeNotebooks` (the
    /// offline notebook surface).
    static func notebooksRequest() -> QueryInterfaceRequest<ItemRecord> {
        ItemRecord
            .filter(Columns.itemType == notebookItemType && Columns.deleted == false)
            .order(Columns.updatedAt.desc)
    }
}
