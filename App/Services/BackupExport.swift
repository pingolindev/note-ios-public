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
import PingolinNoteSDK

/// The Pingolin Note backup format, iOS side.
///
/// WHY THIS EXISTS
///   One envelope for every client: the Note web editor defines it (its
///   `backupFormat.ts`), and the Android app (`BackupFormat.kt`) and this app
///   write the same one, so a backup taken on a phone restores on the web and
///   the other way round.
///
///   Keep it in step with those two: same magic, same version, same key
///   names. A client that drifts writes a file the others silently read as
///   incomplete.
///
/// WHAT IT DELIBERATELY DOES NOT CARRY
///   - Attachment BYTES. They live in object storage, up to 100 MB a user, and
///     embedding them turns a text file into something a phone cannot build.
///     The manifest names them instead, so a restore can say what it could not
///     bring back rather than dropping it in silence.
///   - Cached share-recipient keys. A key that has rotated since would wrap
///     future notes for whoever held the old one, so recipients travel as an
///     email and a permission and are looked up fresh.
enum BackupExport {

    static let format = "pingolin-note-backup"
    static let formatVersion = 2

    /// Build the backup document.
    ///
    /// Notes are emitted from their STORED CONTENT JSON rather than from a typed
    /// model, so keys this build does not know about — a newer client's fields —
    /// ride along instead of being quietly dropped. Same reasoning as the
    /// `extras` bag one layer down.
    ///
    /// - Parameters:
    ///   - notes: active (non-deleted) note rows
    ///   - metadata: the decrypted user-metadata blob, or nil if unavailable
    ///   - attachmentNames: noteId → filenames the backup cannot carry, or nil
    ///     for a note whose list could not be read. Passed IN rather than
    ///     fetched here so this stays pure and testable: naming the files needs
    ///     a request plus a per-attachment decrypt, which is the caller's job.
    static func build(
        notes: [ItemRecord],
        metadata: NotebookMetadata?,
        attachmentNames: [String: [String]?] = [:]
    ) -> [String: Any] {
        var notesArray: [[String: Any]] = []
        var attachments: [[String: Any]] = []
        var withAttachments = 0

        for item in notes {
            let content = decodedContent(item)
            let hasAttachments = (content["has_attachments"] as? Bool) ?? false
            if hasAttachments {
                withAttachments += 1
                var entry: [String: Any] = ["noteId": item.id]
                // nil means "couldn't read this note's list", which is a
                // different statement from an empty list and must stay
                // distinguishable.
                if let names = attachmentNames[item.id], let names {
                    entry["filenames"] = names
                } else {
                    entry["filenames"] = NSNull()
                }
                attachments.append(entry)
            }

            var note: [String: Any] = [
                // Preserved so a re-import is idempotent: the server ignores an
                // insert for an id it already holds and answers 409, so
                // restoring the same file twice converges instead of
                // duplicating.
                "id": item.id,
                "title": (content["title"] as? String) ?? item.title ?? "",
                "body": (content["body"] as? String) ?? "",
                "noteType": (content["note_type"] as? String) ?? "text",
                "color": content["color"] ?? item.color ?? NSNull(),
                "isPinned": (content["is_pinned"] as? Bool) ?? item.isPinned,
                "isArchived": (content["is_archived"] as? Bool) ?? item.isArchived,
                "labels": (content["labels"] as? [Any]) ?? [],
                "sortOrder": (content["sort_order"] as? Int) ?? 0,
                "editMode": (content["edit_mode"] as? String) ?? "markdown",
                "notebookId": content["notebook_id"] ?? item.notebookId ?? NSNull(),
                "hasAttachments": hasAttachments,
                "createdAt": iso.string(from: item.createdAt),
                "updatedAt": iso.string(from: item.updatedAt),
            ]
            if let checklist = content["checklist_items"] as? [[String: Any]] {
                note["checklistItems"] = checklist.map { item in
                    [
                        "text": (item["text"] as? String) ?? "",
                        "checked": (item["checked"] as? Bool) ?? false,
                    ] as [String: Any]
                }
            }
            if let extras = extrasOf(content) { note["extras"] = extras }
            notesArray.append(note)
        }

        var reasons: [String] = []
        if withAttachments > 0 {
            reasons.append("\(withAttachments) note(s) have attachments. Backups list attachments but do not contain the files themselves.")
        }
        if metadata == nil {
            reasons.append("Notebooks, label colours and editor pins could not be read, so they are not in this backup.")
        }

        let notebooks = (metadata?.notebooks ?? []).map { ["id": $0.id, "name": $0.name] }

        var doc: [String: Any] = [
            "format": format,
            "formatVersion": formatVersion,
            "client": "ios",
            "generatedAt": iso.string(from: Date()),
            "isComplete": reasons.isEmpty,
            "counts": [
                "notes": notesArray.count,
                "notebooks": notebooks.count,
                "reminders": 0,
                "notesWithAttachments": withAttachments,
            ],
            "notebooks": notebooks,
            "labelColors": metadata?.labelColors ?? [:],
            "editorModes": metadata?.editorModes ?? [:],
            "notebookShares": strippedShares(metadata),
            "notes": notesArray,
            // Reminders are server-side and this client does not hold them.
            // Declared empty rather than omitted, so a reader can tell "none"
            // from "this client didn't try".
            "reminders": [],
            "attachments": attachments,
        ]
        if !reasons.isEmpty { doc["incompleteReasons"] = reasons }
        return doc
    }

    /// Serialise to the bytes that get written to a file.
    static func encode(_ document: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: - Helpers

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func decodedContent(_ item: ItemRecord) -> [String: Any] {
        guard let raw = item.decryptedContent,
              let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj
    }

    /// Content-JSON keys the typed model does not own, so a newer client's
    /// fields survive the trip. Mirrors the other clients' known-key sets.
    private static func extrasOf(_ content: [String: Any]) -> [String: Any]? {
        var extras: [String: Any] = [:]
        for (key, value) in content where !knownContentKeys.contains(key) {
            extras[key] = value
        }
        return extras.isEmpty ? nil : extras
    }

    private static let knownContentKeys: Set<String> = [
        "title", "body", "note_type", "color", "is_pinned", "is_archived",
        "labels", "sort_order", "edit_mode", "notebook_id", "checklist_items",
        "has_attachments",
    ]

    /// Recipients keep their email and permission; their cached public keys and
    /// user ids do not travel. Reusing a cached key after it has rotated wraps a
    /// note for whoever held the old one.
    private static func strippedShares(_ metadata: NotebookMetadata?) -> [String: Any] {
        var out: [String: Any] = [:]
        for (notebookId, recipients) in (metadata?.notebookShares ?? [:]) {
            out[notebookId] = recipients.map { r in
                [
                    "email": r.email,
                    "permission": r.permission == "view" ? "view" : "edit",
                ] as [String: Any]
            }
        }
        return out
    }

    /// Seal an encoded backup under a passphrase, or return it unchanged when
    /// none was given.
    ///
    /// Lives here rather than in the view because importing the SDK into a
    /// SwiftUI file makes `Environment` ambiguous — the SDK exports one too.
    static func seal(_ data: Data, passphrase: String) throws -> Data {
        guard !passphrase.isEmpty else { return data }
        let sealed = try sealBackupFile(
            payload: String(decoding: data, as: UTF8.self),
            passphrase: passphrase,
            product: "pingolin-note",
            createdAt: ISO8601DateFormatter().string(from: Date())
        )
        return Data(sealed.utf8)
    }
}
