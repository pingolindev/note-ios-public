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

import AppIntents
import WidgetKit

/// Configuration intent for the SingleNoteWidget. iOS surfaces the
/// `selectedNote` parameter in the widget's "Edit" UI so the user
/// picks which note this instance renders. The picker source is
/// `NoteEntityQuery` below, which reads the snapshot the main app
/// publishes to the App Group.
///
/// AppIntent-configurable widgets are the iOS analog of android's
/// SingleNoteConfigActivity (the picker that fires when the user
/// adds the widget to their home screen).
struct SingleNoteIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Pick a note"
    static let description = IntentDescription("Choose which note this widget displays.")

    @Parameter(title: "Note")
    var selectedNote: NoteEntity?

    init() {}

    init(selectedNote: NoteEntity? = nil) {
        self.selectedNote = selectedNote
    }
}

/// The `AppEntity` the user picks from. Identifier is the server item
/// id so the widget can deep-link via `noteapp://item/{id}` on tap.
struct NoteEntity: AppEntity, Identifiable, Hashable {
    let id: String
    let title: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Note")
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title.isEmpty ? "Untitled" : title)")
    }

    static var defaultQuery: NoteEntityQuery { NoteEntityQuery() }
}

/// Resolves the picker contents from the App Group snapshot the main
/// app writes (`WidgetSnapshotPublisher.publish`). No crypto,
/// no network, no keychain — by the time the entries reach the
/// snapshot they're already decrypted and trusted.
struct NoteEntityQuery: EntityQuery {
    // Signed out the picker offers and resolves nothing, and no note is read.
    func entities(for identifiers: [NoteEntity.ID]) async throws -> [NoteEntity] {
        let want = Set(identifiers)
        return SharedAppGroup.widgetState().notes
            .filter { want.contains($0.id) }
            .map { NoteEntity(id: $0.id, title: $0.title) }
    }

    func suggestedEntities() async throws -> [NoteEntity] {
        SharedAppGroup.widgetState().notes
            .prefix(20)
            .map { NoteEntity(id: $0.id, title: $0.title) }
    }
}
