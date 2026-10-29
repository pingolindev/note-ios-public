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

/// App Group plumbing for the main app + widget + share extensions.
///
/// Two pieces of state cross the process boundary:
///   1. A snapshot of recent decrypted notes (titles + flags) written
///      by the main app, read by the widgets. Avoids running libsodium
///      and the keychain dance inside the widget process — the widget
///      only ever sees `[NoteSnapshotEntry]`.
///   2. A pending draft from the share extension. The extension can't
///      reliably reach the keychain on every device (the access-group
///      defaults differ across iOS versions), so it just hands the
///      text off to the main app via UserDefaults. The main app
///      surfaces it on next launch.
enum SharedAppGroup {
    static let identifier = "group.com.pingolin.note"

    static var defaults: UserDefaults {
        UserDefaults(suiteName: identifier) ?? .standard
    }

    /// Legacy key: older app versions stored the snapshot in the
    /// app group's UserDefaults plist. Kept only so such a write
    /// can be read once and then purged.
    private static let snapshotKey = "notes_snapshot_v1"
    private static let snapshotFilename = "notes_snapshot_v1.json"
    private static let draftKey = "pending_share_draft_v1"
    private static let draftFilename = "pending_share_draft_v1.json"
    private static let signedInKey = "signed_in_v1"

    // MARK: - Session flag (main app → widgets)

    /// Whether anybody is signed in.
    ///
    /// The widgets cannot infer this from the snapshot being non-empty:
    /// the empty state is only rendered when the snapshot is empty, so an
    /// inferred flag would be false every time it is read, and a
    /// signed-in user with no notes yet — every new user, at exactly the
    /// moment the widget should invite them to write one — would be told
    /// to sign in to the account they are already signed in to.
    ///
    /// Deliberately in UserDefaults rather than the protected file the
    /// snapshot uses: it says that *someone* is signed in, not who, and
    /// the widget needs it in the empty case where there is no snapshot
    /// file to read.
    static var isSignedIn: Bool {
        get { defaults.bool(forKey: signedInKey) }
        set { defaults.set(newValue, forKey: signedInKey) }
    }

    // MARK: - What the widgets may show

    /// Whether anybody is signed in and, only then, the notes snapshot,
    /// with the flag read once so the two can't disagree. Signed out, the
    /// snapshot isn't read at all, so no widget, and no widget picker,
    /// shows a note. Before the first unlock the flag reads false (the
    /// app group's plist is still protected), so this fails closed.
    /// Tests pass their own [signedIn] and [snapshot].
    static func widgetState(
        signedIn: () -> Bool = { SharedAppGroup.isSignedIn },
        snapshot: () -> [NoteSnapshotEntry] = { SharedAppGroup.readSnapshot() }
    ) -> (isSignedIn: Bool, notes: [NoteSnapshotEntry]) {
        guard signedIn() else { return (false, []) }
        return (true, snapshot())
    }

    // MARK: - Notes snapshot (main app → widgets)

    /// The snapshot carries *decrypted* titles (and, at `.full`,
    /// body snippets). The app group's UserDefaults plist would
    /// leave that plaintext at rest with no data-protection class
    /// and make it iCloud/iTunes backup-eligible — outside the
    /// server-blind note store. So it is written to a file in the
    /// app-group container with
    /// `.completeFileProtectionUntilFirstUserAuthentication` and
    /// excluded from backup. AfterFirstUnlock (not the stricter
    /// `.completeFileProtection`) so the widget can still read it
    /// on the lock screen once the device has been unlocked once
    /// since boot.
    private static var snapshotFileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: identifier)?
            .appendingPathComponent(snapshotFilename, isDirectory: false)
    }

    static func writeSnapshot(_ entries: [NoteSnapshotEntry]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let url = snapshotFileURL,
              let data = try? encoder.encode(entries) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutableURL.setResourceValues(values)
        // Purge any snapshot a prior version left in the plaintext
        // UserDefaults store so no decrypted title survives at rest there.
        defaults.removeObject(forKey: snapshotKey)
    }

    static func readSnapshot() -> [NoteSnapshotEntry] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let url = snapshotFileURL, let data = try? Data(contentsOf: url) {
            return (try? decoder.decode([NoteSnapshotEntry].self, from: data)) ?? []
        }
        // Upgrade fallback: a snapshot written by a prior version still
        // lives in UserDefaults until the main app next runs writeSnapshot
        // (which migrates + purges it). Keeps the widget populated across
        // the upgrade window.
        guard let legacy = defaults.data(forKey: snapshotKey) else { return [] }
        return (try? decoder.decode([NoteSnapshotEntry].self, from: legacy)) ?? []
    }

    // MARK: - Pending draft (share extension → main app)

    /// The draft carries the full plaintext title+body the user shared in.
    /// The app group's UserDefaults plist would leave that plaintext at
    /// rest with no data-protection class and make it iCloud/iTunes
    /// backup-eligible — the exposure the notes snapshot avoids the same
    /// way (`snapshotFileURL`). So it is written to a file in the
    /// app-group container with
    /// `.completeFileProtectionUntilFirstUserAuthentication` and excluded
    /// from backup. AfterFirstUnlock (not the stricter
    /// `.completeFileProtection`) so the main app can still pick the draft
    /// up on its next launch once the device has been unlocked once since
    /// boot.
    private static var draftFileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: identifier)?
            .appendingPathComponent(draftFilename, isDirectory: false)
    }

    static func setPendingDraft(_ draft: PendingShareDraft?) {
        guard let draft else {
            if let url = draftFileURL { try? FileManager.default.removeItem(at: url) }
            defaults.removeObject(forKey: draftKey)
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let url = draftFileURL,
              let data = try? encoder.encode(draft) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutableURL.setResourceValues(values)
        // Purge any draft a prior version left in the plaintext UserDefaults
        // store so no shared-in plaintext survives at rest there.
        defaults.removeObject(forKey: draftKey)
    }

    static func takePendingDraft() -> PendingShareDraft? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // Primary: the data-protected app-group file. One-shot — delete it
        // after reading so the plaintext draft doesn't linger at rest.
        if let url = draftFileURL, let data = try? Data(contentsOf: url) {
            try? FileManager.default.removeItem(at: url)
            defaults.removeObject(forKey: draftKey)
            guard let draft = try? decoder.decode(PendingShareDraft.self, from: data),
                  !draft.isExpired()
            else { return nil }
            return draft
        }
        // Upgrade fallback: a draft written by a prior version still lives in
        // UserDefaults. Read it once, then purge it (mirrors readSnapshot's
        // legacy path) so it doesn't survive at rest.
        guard let legacy = defaults.data(forKey: draftKey) else { return nil }
        defaults.removeObject(forKey: draftKey)
        guard let draft = try? decoder.decode(PendingShareDraft.self, from: legacy),
              !draft.isExpired()
        else { return nil }
        return draft
    }
}

/// Minimal projection of a note for the widget. The list widget only
/// needs title + updatedAt + pin flag; the SingleNoteWidget renders a
/// snippet of the body too, so an optional `bodySnippet` is included
/// here (capped to ~200 chars by the main app before write). Stays
/// JSON-encodable so it survives the round trip across processes.
struct NoteSnapshotEntry: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let updatedAt: Date
    let isPinned: Bool
    /// Optional snippet (first ~200 chars of the decrypted body).
    /// Older snapshot writes omit this — `nil` decodes cleanly.
    var bodySnippet: String? = nil
}

/// A draft handed off by the share extension. Title is best-effort;
/// the extension's own prompt lets the user edit it before saving.
struct PendingShareDraft: Codable, Identifiable {
    static let lifetime: TimeInterval = 30 * 60

    let id: UUID
    var title: String
    var body: String
    let createdAt: Date

    init(title: String, body: String, createdAt: Date = Date()) {
        self.id = UUID()
        self.title = title
        self.body = body
        self.createdAt = createdAt
    }

    func isExpired(at now: Date = Date()) -> Bool {
        now.timeIntervalSince(createdAt) > Self.lifetime
    }
}
