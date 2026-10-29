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

/// Turns a share-extension draft into a local dirty create at the start of a
/// sync cycle.
///
/// No second confirmation on purpose: the extension's own prompt
/// (`SharePromptView`) already showed the user an editable title/body with
/// Save/Cancel, so saving in the share sheet MEANS save.
///
/// The create is the usual offline-first shape: client-owned id, encrypt,
/// dirty row — and then the enclosing sync's own `drainOutbox` replays it to
/// the server, so there is no separate network path to get wrong. The web
/// app shows it after its next pull.
enum ShareDraftConsumer {

    @MainActor
    static func consumePending() {
        guard let draft = SharedAppGroup.takePendingDraft() else { return }
        guard let vaultKey = AuthManager.shared.vaultKeyBase64,
              let userId = KeychainService.shared.getString(for: .userId)
        else {
            // Signed out (or keys not yet restored): put the draft back and
            // let a later cycle pick it up — take-then-restore keeps the read
            // and the guard atomic enough for the single-app consumer.
            SharedAppGroup.setPendingDraft(draft)
            return
        }
        let payload = DecodedNote(
            title: draft.title,
            body: draft.body,
            noteType: "text",
            isPinned: false,
            isArchived: false,
            labels: [],
            sortOrder: 0,
            editMode: "rich"
        )
        do {
            let plaintext = try payload.encodeJSON()
            // Wrapped-content-key path (matches note-web + android).
            let wrapped = try NoteCrypto.encryptWithWrappedKey(plaintext: plaintext, vaultKeyBase64: vaultKey)
            let now = Date()
            let item = Item(
                id: UUID().uuidString.lowercased(),
                userId: userId,
                itemType: ItemType.note.rawValue,
                encryptedContent: wrapped.encryptedContent,
                contentNonce: wrapped.contentNonce,
                version: 1,
                createdAt: now,
                updatedAt: now,
                deleted: false,
                deletedAt: nil,
                circleId: nil,
                contentSize: wrapped.encryptedContent.count,
                notebookId: nil,
                wrappedContentKey: wrapped.wrappedContentKey,
                wrappedContentKeyNonce: wrapped.wrappedContentKeyNonce,
                contentKeyGeneration: nil
            )
            NoteStore.shared.upsert(ItemRecord(item: item, note: payload, isDirty: true))
        } catch {
            // Encrypt/encode failed — keep the draft rather than lose the
            // user's shared text; the next cycle retries.
            SharedAppGroup.setPendingDraft(draft)
        }
    }
}
