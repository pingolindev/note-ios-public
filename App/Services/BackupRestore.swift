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

/// Restoring a Pingolin Note backup.
///
/// The file is the shared `pingolin-note-backup` v2 envelope, so a backup taken
/// on the web or on Android restores here and the other way round.
///
/// THE PROPERTY THAT MATTERS
///   A restored note keeps its ORIGINAL id. That is what makes restoring the
///   same file twice converge instead of doubling the account: the server
///   ignores an insert for an id it already holds and answers 409, so the
///   second pass is a no-op. A 409 on an id-carrying note is therefore
///   counted as "already restored", not as a failure — otherwise a clean second
///   restore reports as a total failure.
///
/// ADDITIVE, NEVER DESTRUCTIVE
///   It fills in what is missing and leaves everything present alone. Someone
///   restoring has already had something go wrong; overwriting their newer work
///   would be the wrong way to help.
///
/// ORDER MATTERS
///   Metadata (notebooks, label colours, editor pins) goes first: a note carries
///   `notebook_id`, and a notebook that does not exist yet means the reference
///   is dropped and every note lands unfiled.
enum BackupRestore {

    struct Summary {
        var notesRestored = 0
        var notesAlreadyPresent = 0
        var notesSkipped = 0
        var notebooksAdded = 0
        /// Things the file itself admitted it was missing, plus what this
        /// restore chose not to touch.
        var notes: [String] = []
    }

    enum ReadError: LocalizedError {
        case unreadable(String)
        case notABackup
        case futureFormat(Int)
        case needsPassphrase

        var errorDescription: String? {
            switch self {
            case .unreadable(let why): return "Couldn't read that file: \(why)"
            case .notABackup: return "That file is not a Pingolin Note backup."
            case .futureFormat(let v):
                return "That backup was written by a newer version of Pingolin (format \(v)). Update the app, then restore it."
            case .needsPassphrase:
                return "That backup is encrypted. Enter its passphrase to restore it."
            }
        }
    }

    /// This overload opens a sealed backup and parses it. It is separate from
    /// `read(_:)` so the plain path is unaffected: the sealed case is
    /// discovered by `read(_:)` throwing, and only then does the caller
    /// collect a passphrase and come back here.
    static func read(_ data: Data, passphrase: String) throws -> [String: Any] {
        let text = String(decoding: data, as: UTF8.self)
        let opened: String
        do {
            opened = try openBackupFile(text: text, passphrase: passphrase)
        } catch {
            // The SDK's message is already written for a person — "That backup
            // could not be opened. Check the passphrase."
            throw ReadError.unreadable((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
        return try read(Data(opened.utf8))
    }

    /// Parses and sanity-checks a backup file.
    ///
    /// Strict about the envelope, forgiving about the contents: a missing
    /// optional section restores as empty, but a file from a FUTURE format
    /// version is refused outright. Half-restoring a format this build does not
    /// understand produces an account that looks whole and is not.
    static func read(_ data: Data) throws -> [String: Any] {
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ReadError.unreadable(error.localizedDescription)
        }
        guard let doc = parsed as? [String: Any] else { throw ReadError.notABackup }

        // A sealed container is also JSON, and it comes from the same file
        // picker — so branch on the content, not the name.
        if doc["format"] as? String == "pingolin-encrypted-backup" {
            // `needsPassphrase` is the signal the caller prompts on: it must
            // be caught, or the message invites the user to enter a
            // passphrase with no field to enter it into.
            throw ReadError.needsPassphrase
        }
        guard doc["format"] as? String == BackupExport.format else { throw ReadError.notABackup }

        let version = doc["formatVersion"] as? Int ?? 0
        if version > BackupExport.formatVersion { throw ReadError.futureFormat(version) }
        guard doc["notes"] is [[String: Any]] else { throw ReadError.notABackup }
        return doc
    }

    /// What the file admits it could not carry, for the user to see up front.
    static func warnings(_ doc: [String: Any]) -> [String] {
        var out = (doc["incompleteReasons"] as? [String]) ?? []
        let missingAttachments = (doc["attachments"] as? [[String: Any]])?.count ?? 0
        if missingAttachments > 0 && !out.contains(where: { $0.lowercased().contains("attachment") }) {
            out.append("\(missingAttachments) note(s) had attachments. Backups list attachments but do not contain the files, so those notes restore without them.")
        }
        return out
    }

    /// Merge the backup's notebooks, label colours and editor pins into the
    /// live metadata blob, in ONE write.
    ///
    /// One write matters: all of it lives in a single `item_type = 10` row that
    /// every client rewrites whole, so doing it a notebook at a time would be N
    /// round-trips racing over one row.
    ///
    /// Notebook ids are PRESERVED, which is what lets restored notes land in
    /// the right notebook — a freshly minted id would leave every one unfiled.
    static func mergeMetadata(_ doc: [String: Any], into live: inout NotebookMetadata) -> Int {
        var added = 0
        let existing = Set(live.notebooks.map(\.id))
        for entry in (doc["notebooks"] as? [[String: Any]]) ?? [] {
            guard let id = entry["id"] as? String, !existing.contains(id) else { continue }
            live.notebooks.append(NotebookEntry(id: id, name: entry["name"] as? String ?? ""))
            added += 1
        }

        // Fill in only what is missing: a label recoloured since the backup
        // keeps its new colour.
        for (label, colour) in (doc["labelColors"] as? [String: String]) ?? [:] {
            if live.labelColors[label] == nil { live.labelColors[label] = colour }
        }
        var pins = live.editorModes ?? [:]
        for (noteId, mode) in (doc["editorModes"] as? [String: String]) ?? [:] {
            if pins[noteId] == nil { pins[noteId] = mode }
        }
        if !pins.isEmpty { live.editorModes = pins }

        for (notebookId, recipients) in (doc["notebookShares"] as? [String: [[String: Any]]]) ?? [:] {
            guard live.notebookShares[notebookId] == nil else { continue }
            // Cached public keys and user ids are deliberately absent from a
            // backup: a key that has rotated since would wrap future notes for
            // whoever held it. Restored recipients are looked up fresh.
            live.notebookShares[notebookId] = recipients.compactMap { r in
                guard let email = r["email"] as? String else { return nil }
                return ShareRecipientEntry(
                    email: email,
                    permission: (r["permission"] as? String) == "view" ? "view" : "edit",
                    publicKey: nil,
                    userId: nil
                )
            }
        }
        return added
    }

    /// Turn one backed-up note into the request that recreates it.
    ///
    /// Returns nil when the note cannot be rebuilt — a malformed id is worse
    /// than none, since it would be rejected and lose the note, where dropping
    /// it only costs idempotence for that row.
    static func createRequest(
        for note: [String: Any],
        knownNotebooks: Set<String>,
        vaultKeyBase64: String
    ) -> CreateItemRequest? {
        guard let id = note["id"] as? String, isUuid(id) else { return nil }

        // Rebuild the content JSON in the shape the app stores, starting from
        // the extras bag so a newer client's unknown keys survive and the known
        // fields below always win.
        var content: [String: Any] = (note["extras"] as? [String: Any]) ?? [:]
        content["title"] = note["title"] as? String ?? ""
        content["body"] = note["body"] as? String ?? ""
        content["note_type"] = (note["noteType"] as? String) == "checklist" ? "checklist" : "text"
        if let colour = note["color"] as? String { content["color"] = colour }
        content["is_pinned"] = note["isPinned"] as? Bool ?? false
        content["is_archived"] = note["isArchived"] as? Bool ?? false
        content["labels"] = (note["labels"] as? [Any])?.compactMap { $0 as? String } ?? []
        content["sort_order"] = note["sortOrder"] as? Int ?? 0
        if let mode = note["editMode"] as? String, mode == "rich" || mode == "markdown" {
            content["edit_mode"] = mode
        }
        if let items = note["checklistItems"] as? [[String: Any]] {
            content["checklist_items"] = items.compactMap { i -> [String: Any]? in
                guard let text = i["text"] as? String else { return nil }
                return ["text": text, "checked": i["checked"] as? Bool ?? false]
            }
        }
        // Only a notebook the SAME file defines. A dangling id would file the
        // note somewhere the user has no way to open.
        let notebookId = (note["notebookId"] as? String).flatMap { knownNotebooks.contains($0) ? $0 : nil }
        if let notebookId { content["notebook_id"] = notebookId }
        // `hasAttachments` is read from the backup and deliberately NOT
        // restored: the bytes are not in the file and there is no attachment row
        // to point at, so setting it would render the attachment strip for
        // files that do not exist.

        guard let json = try? JSONSerialization.data(withJSONObject: content),
              let plaintext = String(data: json, encoding: .utf8),
              let wrapped = try? NoteCrypto.encryptWithWrappedKey(
                  plaintext: plaintext, vaultKeyBase64: vaultKeyBase64, itemId: id
              )
        else { return nil }

        return CreateItemRequest(
            id: id,
            itemType: 1,
            encryptedContent: wrapped.encryptedContent,
            contentNonce: wrapped.contentNonce,
            notebookId: notebookId,
            wrappedContentKey: wrapped.wrappedContentKey,
            wrappedContentKeyNonce: wrapped.wrappedContentKeyNonce
        )
    }

    /// Notebook ids the file actually defines.
    static func knownNotebooks(_ doc: [String: Any]) -> Set<String> {
        Set(((doc["notebooks"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String })
    }

    private static let uuid = try! NSRegularExpression(
        pattern: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
    )

    static func isUuid(_ s: String) -> Bool {
        uuid.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }
}
