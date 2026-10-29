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

/// Recent notes grid. Reads a snapshot the main app writes to the App
/// Group at the end of every sync cycle. The widget never
/// touches the keychain or libsodium — by the time titles reach the
/// snapshot they're already decrypted. Mirrors android's
/// NoteListWidgetProvider + NoteListRemoteViewsFactory.
struct NotesListWidget: Widget {
    let kind: String = "NotesListWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NotesListProvider()) { entry in
            NotesListWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Recent Notes")
        .description("Your latest notes at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct NotesListEntry: TimelineEntry {
    let date: Date
    let entries: [NoteSnapshotEntry]
    let isSignedIn: Bool
}

struct NotesListProvider: TimelineProvider {
    func placeholder(in context: Context) -> NotesListEntry {
        NotesListEntry(
            date: Date(),
            entries: (0..<4).map {
                NoteSnapshotEntry(
                    id: "placeholder-\($0)",
                    title: "Note title \($0 + 1)",
                    updatedAt: Date().addingTimeInterval(-Double($0) * 3600),
                    isPinned: $0 == 0
                )
            },
            isSignedIn: true
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (NotesListEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NotesListEntry>) -> Void) {
        // The main app calls WidgetCenter.shared.reloadAllTimelines()
        // whenever it republishes the snapshot or the sign-in state
        // changes, so .never is fine — we don't poll.
        completion(Timeline(entries: [currentEntry()], policy: .never))
    }

    private func currentEntry() -> NotesListEntry {
        // Signed out, no note is read: the flag and the snapshot
        // come from one read of the session
        // (SharedAppGroup.widgetState).
        let state = SharedAppGroup.widgetState()
        return NotesListEntry(
            date: Date(),
            entries: state.notes,
            // The signed-in flag comes from the session, never from the
            // snapshot: the empty state renders only WHEN the snapshot is
            // empty, so a flag inferred from `!snapshot.isEmpty` would be
            // false every time, and a signed-in user with no notes would be
            // told to sign in instead of invited to write one.
            isSignedIn: state.isSignedIn
        )
    }
}

struct NotesListWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NotesListEntry

    /// systemSmall shows 2 rows. A small widget's content box is 126x126pt
    /// on a 390x844 phone (158pt minus WidgetKit's 16pt margins); a header
    /// plus three .subheadline rows would leave each row about 20pt tall,
    /// and they are not individually tappable anyway (see `tappable`). Two
    /// rows are legible and honest about what the size can hold.
    var rowCount: Int {
        switch family {
        case .systemSmall: return 2
        case .systemMedium: return 4
        default: return 8
        }
    }

    /// Per-row tap targets exist only where WidgetKit supports more than one.
    ///
    /// In systemSmall the whole widget is a SINGLE target, taken from
    /// `widgetURL`; `Link` is supported only in systemMedium and systemLarge,
    /// so a row Link or the "+" would be inert there. Rather than pretend,
    /// small renders the rows as plain content and the widget as a whole opens
    /// the app.
    @ViewBuilder
    private func tappable<Content: View>(
        _ destination: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if family == .systemSmall {
            content()
        } else if let url = URL(string: destination) {
            Link(destination: url) { content() }
                .buttonStyle(.plain)
        } else {
            content()
        }
    }

    var body: some View {
        // Signed out: "Not signed in", whatever the entry holds.
        if !entry.isSignedIn || entry.entries.isEmpty {
            emptyState
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "note.text")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.brandAccent)
                    Text("Notes")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    // Hidden on small: a ~22pt glyph that cannot be its own
                    // target is a button that lies. Quick Capture is the
                    // small-size answer for "new note".
                    if family != .systemSmall {
                        tappable("noteapp://create") {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(Color.brandAccent)
                        }
                    }
                }
                ForEach(entry.entries.prefix(rowCount)) { row in
                    tappable("noteapp://item/\(row.id)") {
                        HStack(spacing: 6) {
                            if row.isPinned {
                                Image(systemName: "pin.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                            Text(row.title.isEmpty ? "Untitled" : row.title)
                                .font(.subheadline)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Text(row.updatedAt, style: .relative)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: entry.isSignedIn ? "note.text.badge.plus" : "person.crop.circle.badge.questionmark")
                .font(.largeTitle)
                .foregroundStyle(Color.brandAccent)
            Text(entry.isSignedIn ? "No notes yet" : "Not signed in")
                .font(.subheadline.weight(.semibold))
            Text(entry.isSignedIn ? "Tap to add one" : "Open Note to sign in")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Only offer the composer when there is an account to put a note in.
        // Signed out, a tap should reach the login screen, which is what the
        // app opens to with no URL — so no widgetURL in that case.
        .widgetURL(entry.isSignedIn ? URL(string: "noteapp://create") : nil)
    }
}
