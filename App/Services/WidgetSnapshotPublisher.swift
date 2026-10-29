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
import WidgetKit

/// Publishes the widget snapshot from the LOCAL STORE at the end of every
/// sync cycle. With the web shell as the note UI there is no native list to
/// publish after each mutation, but every mutation reaches the store through
/// the same funnel (web edit → `pingolinNudge` → `SyncService.sync()` pull,
/// or a share-extension draft → dirty create → the same sync), so the end of
/// `sync()` is the single point where the store is fresh.
///
/// The snapshot persists decrypted text to a data-protected, backup-excluded
/// file in the app-group container (see `SharedAppGroup.writeSnapshot`), so it
/// honors the notification-detail level: "titles" drops body snippets,
/// "generic" writes no decrypted content at all.
enum WidgetSnapshotPublisher {

    static func publish() {
        let detail = AppConfiguration.shared.notificationDetail
        // activeNotesRequest already filters to live, unarchived notes and
        // orders pinned → drag order → recency — the order the widget
        // shows.
        let entries = NoteStore.shared.fetchActiveNotes()
            .prefix(8)
            .map { record in
                NoteSnapshotEntry(
                    id: record.id,
                    title: detail == .generic ? "Note" : (record.title ?? "Untitled"),
                    updatedAt: record.updatedAt,
                    isPinned: record.isPinned,
                    bodySnippet: detail == .full ? bodySnippet(of: record) : nil
                )
            }
        SharedAppGroup.writeSnapshot(Array(entries))
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// The denormalized columns carry no body, so the snippet comes from the
    /// row's local-only decrypted JSON — a plain decode, no vault key needed.
    /// Rows cached without plaintext (an undecrypted conflict copy) just get
    /// no snippet.
    private static func bodySnippet(of record: ItemRecord) -> String? {
        guard let json = record.decryptedContent,
              let note = try? DecodedNote.decode(from: Data(json.utf8))
        else { return nil }
        return String(note.body.prefix(200))
    }
}
