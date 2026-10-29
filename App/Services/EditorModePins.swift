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

/// Per-note editor-mode pins: the rule, with no storage and no SwiftUI.
///
/// The global setting is the DEFAULT for every note. Changing the mode with a
/// specific note open pins that note; setting it back to whatever the global
/// currently is un-pins it, so the note follows the default again.
///
/// Kept in step with the web's `src/lib/editorModeOverrides.ts` and
/// note-android's `EditorModePins.kt` — the map is ONE blob shared by three
/// clients, so a disagreement about what a key means is a user watching a note
/// change mode when they open it somewhere else.
///
/// WHY NOT IN THE NOTE. The note body is what syncs to collaborators and to
/// `/shared/:token` readers, so a view preference stored there would impose one
/// reader's choice on everyone — and writing it would bump `updated_at`,
/// reordering the notes list for nothing more than looking at a note in a
/// different mode. A pin never writes the note.
enum EditorModePins {

    /// The three modes, spelled as `NoteEditorMode.rawValue` spells them.
    private static let modes: Set<String> = ["hybrid", "markdown", "preview"]

    /// Drop anything that is not a known mode.
    ///
    /// The blob is shared with clients this build has never met, including
    /// later ones, so an unrecognised value is treated as absent rather than
    /// trusted into a UI that switches on three names.
    static func sanitize(_ raw: Any?) -> [String: String] {
        guard let dict = raw as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        for (id, value) in dict {
            if !id.isEmpty, let mode = value as? String, modes.contains(mode) {
                out[id] = mode
            }
        }
        return out
    }

    /// The mode a note is actually edited in.
    static func resolve(_ pins: [String: String], noteId: String?, global: String) -> String {
        guard let noteId else { return global }
        return pins[noteId] ?? global
    }

    /// True when this note is pinned AWAY from the current global — i.e. when
    /// the UI should say "this note" rather than "default". A pin that happens
    /// to equal the global reads as not pinned, which is honest: it changes
    /// nothing the user can see.
    static func isPinned(_ pins: [String: String], noteId: String?, global: String) -> Bool {
        guard let noteId, let pin = pins[noteId] else { return false }
        return pin != global
    }

    /// Apply the pin/un-pin rule. Returns nil when nothing would change, so
    /// callers can skip a write — the map shares a blob with notebooks and
    /// label colours, and a pointless save would bump its version and race
    /// another device for nothing.
    static func withMode(
        _ pins: [String: String], noteId: String, mode: String, global: String,
    ) -> [String: String]? {
        let current = pins[noteId]
        if mode == global {
            guard current != nil else { return nil }
            var next = pins
            next.removeValue(forKey: noteId)
            return next
        }
        guard current != mode else { return nil }
        var next = pins
        next[noteId] = mode
        return next
    }

    /// Drop pins whose note is gone, so the map cannot grow forever. Returns
    /// nil when there is nothing to collect.
    ///
    /// `liveIds` must be the ids the caller actually knows to exist — a partial
    /// set would delete pins for notes merely absent from it, which is silent
    /// data loss rather than housekeeping.
    static func gc(_ pins: [String: String], liveIds: Set<String>) -> [String: String]? {
        guard !pins.isEmpty else { return nil }
        let kept = pins.filter { liveIds.contains($0.key) }
        return kept.count == pins.count ? nil : kept
    }
}

/// The three editor modes, matching the Android app's
/// `SessionManager.EDITOR_MODE_*` and the web's `EditorMode` exactly — the same
/// names, so the three clients can be compared without a translation table. The
/// mode pins carry these values in the shared metadata blob.
enum NoteEditorMode: String, CaseIterable, Identifiable {
    case hybrid, markdown, preview
    var id: String { rawValue }
    var label: String {
        switch self {
        case .hybrid: return "Hybrid"
        case .markdown: return "Markdown"
        case .preview: return "Preview"
        }
    }
}
