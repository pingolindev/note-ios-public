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

import WidgetKit
import SwiftUI

/// Configurable single-note widget. iOS analog of android's
/// SingleNoteWidgetProvider + SingleNoteConfigActivity: user picks
/// the note in the widget's Edit UI (driven by `SingleNoteIntent`),
/// the widget renders that note's title + snippet + relative
/// timestamp. Tap → `noteapp://item/{id}` deep-link.
///
/// Snapshot is read from the App Group so the widget process stays
/// free of libsodium + the keychain dance — the main app pre-decrypts
/// titles + snippets into `NoteSnapshotEntry` and publishes them.
struct SingleNoteWidget: Widget {
    let kind: String = "SingleNoteWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: SingleNoteIntent.self,
            provider: SingleNoteProvider()
        ) { entry in
            SingleNoteWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Single Note")
        .description("Pin a specific note to your home screen.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct SingleNoteEntry: TimelineEntry {
    let date: Date
    let note: NoteSnapshotEntry?
    /// True when the user added the widget but hasn't picked a note yet.
    let needsConfiguration: Bool
    /// False when nobody is signed in: then no note is read or shown.
    let isSignedIn: Bool
}

struct SingleNoteProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> SingleNoteEntry {
        SingleNoteEntry(
            date: Date(),
            note: NoteSnapshotEntry(
                id: "placeholder",
                title: "Shopping list",
                updatedAt: Date(),
                isPinned: false,
                bodySnippet: "Milk, eggs, bread, coffee — the usual."
            ),
            needsConfiguration: false,
            isSignedIn: true
        )
    }

    func snapshot(for configuration: SingleNoteIntent, in context: Context) async -> SingleNoteEntry {
        currentEntry(for: configuration)
    }

    func timeline(for configuration: SingleNoteIntent, in context: Context) async -> Timeline<SingleNoteEntry> {
        // Main app calls WidgetCenter.shared.reloadAllTimelines() whenever
        // it republishes the snapshot or the sign-in state changes; .never
        // policy keeps us off the polling treadmill.
        return Timeline(entries: [currentEntry(for: configuration)], policy: .never)
    }

    private func currentEntry(for configuration: SingleNoteIntent) -> SingleNoteEntry {
        // Signed out, no note is read, whatever the widget was set
        // to show.
        let state = SharedAppGroup.widgetState()
        guard state.isSignedIn else {
            return SingleNoteEntry(date: Date(), note: nil, needsConfiguration: false, isSignedIn: false)
        }
        guard let configured = configuration.selectedNote else {
            return SingleNoteEntry(date: Date(), note: nil, needsConfiguration: true, isSignedIn: true)
        }
        let note = state.notes.first(where: { $0.id == configured.id })
        // If the note was deleted on another device after the user
        // configured the widget, the snapshot lookup misses; that's not
        // a configuration error — it's just stale. Surface a "no
        // longer available" view, not the picker prompt.
        return SingleNoteEntry(date: Date(), note: note, needsConfiguration: false, isSignedIn: true)
    }
}

struct SingleNoteWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SingleNoteEntry

    var body: some View {
        if !entry.isSignedIn {
            // First: nothing can be picked or shown signed
            // out. No widgetURL, so a tap opens the app,
            // which asks to sign in.
            signedOutView
        } else if entry.needsConfiguration {
            // Deliberately not tappable. This card's whole job
            // is to teach a long-press ("Tap and hold this
            // widget → Edit Widget"); a Link to
            // noteapp://create here would contradict that, and
            // a tap would produce an unwanted blank note. With
            // no widgetURL a tap just opens the app, which is
            // the harmless default.
            configureView
        } else if let note = entry.note {
            // widgetURL rather than Link: this widget supports systemSmall,
            // where WidgetKit ignores Link and takes the single tap target
            // from widgetURL. It is one note either way, so there is never a
            // second target to need Link for.
            content(for: note)
                .widgetURL(URL(string: "noteapp://item/\(note.id)"))
        } else {
            unavailableView
        }
    }

    private func content(for note: NoteSnapshotEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                if note.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Text(note.title.isEmpty ? "Untitled" : note.title)
                    .font(.headline)
                    .lineLimit(1)
            }
            if let snippet = note.bodySnippet, !snippet.isEmpty {
                Text(snippet)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(family == .systemMedium ? 5 : 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
            Text(note.updatedAt, style: .relative)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var configureView: some View {
        VStack(spacing: 6) {
            Image(systemName: "rectangle.and.pencil.and.ellipsis")
                .font(.largeTitle)
                .foregroundStyle(Color.brandAccent)
            Text("Tap and hold this widget")
                .font(.caption.weight(.semibold))
            Text("→ Edit Widget → choose a note")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The list widget's own signed-out words and glyph (NotesListWidget).
    private var signedOutView: some View {
        VStack(spacing: 6) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.largeTitle)
                .foregroundStyle(Color.brandAccent)
            Text("Not signed in")
                .font(.caption.weight(.semibold))
            Text("Open Note to sign in")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var unavailableView: some View {
        VStack(spacing: 6) {
            Image(systemName: "questionmark.folder")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text("Note unavailable")
                .font(.caption.weight(.semibold))
            Text("This note may have been deleted, or your snapshot is out of date — open Note to refresh.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
