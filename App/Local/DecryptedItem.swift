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

/// Decrypted item ready to display: original Item + the decoded note
/// plaintext. The shares inbox hands rows around in this shape.
struct DecryptedItem: Identifiable {
    let item: Item
    let note: DecodedNote?           // nil when decryption failed
    let decryptError: String?         // first-line error message for debugging
    var id: String { item.id }
}

extension ItemRecord {
    /// Build a cache record from a server `Item` and its decoded note. When
    /// `note` is nil (a decode failure) the last-known-good plaintext columns
    /// are preserved from `prior` rather than blanked — the ciphertext and
    /// server metadata are always taken from the fresh `item`.
    init(item: Item, note: DecodedNote?, prior: ItemRecord? = nil, isDirty: Bool = false) {
        self.id = item.id
        self.userId = item.userId
        self.itemType = item.itemType
        self.encryptedContent = item.encryptedContent
        self.contentNonce = item.contentNonce
        // Server-computed. `prior` fallback keeps the badge across a local edit
        // whose synthesized Item carries no share state — the iOS counterpart
        // of android's targeted UPDATE leaving shared_by_me untouched.
        self.sharedByMe = item.sharedByMe ?? prior?.sharedByMe ?? false
        if let note {
            self.decryptedContent = try? note.encodeJSON()
            self.title = note.title
            self.isPinned = note.isPinned ?? false
            self.isArchived = note.isArchived ?? false
            self.sortOrder = note.sortOrder ?? 0
        } else {
            self.decryptedContent = prior?.decryptedContent
            self.title = prior?.title
            self.isPinned = prior?.isPinned ?? false
            self.isArchived = prior?.isArchived ?? false
            self.sortOrder = prior?.sortOrder ?? 0
        }
        self.color = prior?.color
        // Callers building an offline create/edit pass isDirty:true so the row is
        // queued for the outbox; a pulled/confirmed row defaults false.
        self.isDirty = isDirty
        // Preserve a pending offline-restore across an edit-then-cache
        // upsert (e.g. the user restores a note offline, then edits it before it
        // syncs). Sourced from `prior` because the server `Item` has no such
        // concept; a fresh pull/create has no prior → false. The pull dirty-guard
        // also skips pending_restore rows, so a pull never lands here to clear it.
        self.pendingRestore = prior?.pendingRestore ?? false
        self.version = item.version
        self.createdAt = item.createdAt
        self.updatedAt = item.updatedAt
        self.deleted = item.deleted
        self.deletedAt = item.deletedAt
        self.circleId = item.circleId
        self.notebookId = item.notebookId
        self.contentSize = item.contentSize
        self.wrappedContentKey = item.wrappedContentKey
        self.wrappedContentKeyNonce = item.wrappedContentKeyNonce
        self.contentKeyGeneration = item.contentKeyGeneration
    }

    /// Reconstruct the server `Item` from a cached row (no crypto needed).
    func toItem() -> Item {
        Item(
            id: id,
            userId: userId,
            itemType: itemType,
            encryptedContent: encryptedContent,
            contentNonce: contentNonce,
            version: version,
            createdAt: createdAt,
            updatedAt: updatedAt,
            deleted: deleted,
            deletedAt: deletedAt,
            circleId: circleId,
            contentSize: contentSize,
            notebookId: notebookId,
            wrappedContentKey: wrappedContentKey,
            wrappedContentKeyNonce: wrappedContentKeyNonce,
            sharedByMe: sharedByMe,
            contentKeyGeneration: contentKeyGeneration
        )
    }

    /// Map a cached row to a display row — the offline read. The note is
    /// decoded from the cached plaintext JSON; no vault key is required.
    func toDecryptedItem() -> DecryptedItem {
        let note: DecodedNote? = {
            guard let json = decryptedContent,
                  let data = json.data(using: .utf8) else { return nil }
            return try? DecodedNote.decode(from: data)
        }()
        return DecryptedItem(
            item: toItem(),
            note: note,
            decryptError: note == nil ? "cached copy unavailable" : nil)
    }
}
