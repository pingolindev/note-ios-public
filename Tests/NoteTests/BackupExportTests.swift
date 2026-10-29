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

import XCTest
@testable import Note

/// The written side of the backup format, iOS copy.
///
/// The envelope is ONE thing shared by three clients: a backup written here
/// has to be readable by the web editor's restore and the Android app's
/// parser. Mirrors the Android app's `BackupFormatTest.kt` case for case, so
/// a drift on either side shows up as a failing test rather than as a file
/// the other app quietly reads as empty.
final class BackupExportTests: XCTestCase {

    private let noteId = "22222222-2222-4222-8222-222222222222"

    private func record(id: String, content: String) -> ItemRecord {
        ItemRecord(
            id: id,
            userId: "u",
            itemType: 1,
            encryptedContent: "ct",
            contentNonce: "n",
            decryptedContent: content,
            title: "t",
            version: 1,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_086_400),
            deleted: false,
            deletedAt: nil,
            circleId: nil,
            notebookId: nil,
            contentSize: 0,
            color: nil,
            isPinned: false,
            isArchived: false,
            isDirty: false,
            pendingRestore: false,
            sortOrder: 0
        )
    }

    private var withAttachment: ItemRecord {
        record(id: noteId, content: #"{"title":"Has files","has_attachments":true}"#)
    }
    private var plain: ItemRecord {
        record(id: "33333333-3333-4333-8333-333333333333", content: #"{"title":"Plain"}"#)
    }

    private func firstNote(_ doc: [String: Any]) -> [String: Any] {
        (doc["notes"] as? [[String: Any]])?.first ?? [:]
    }
    private func manifest(_ doc: [String: Any]) -> [[String: Any]] {
        (doc["attachments"] as? [[String: Any]]) ?? []
    }

    func testWritesTheSharedEnvelope() {
        let doc = BackupExport.build(notes: [plain], metadata: nil)
        XCTAssertEqual(doc["format"] as? String, "pingolin-note-backup")
        XCTAssertEqual(doc["formatVersion"] as? Int, 2)
        XCTAssertEqual(doc["client"] as? String, "ios")
        XCTAssertEqual((doc["notes"] as? [[String: Any]])?.count, 1)
    }

    func testCarriesTheWholeNote() {
        let full = record(id: noteId, content: #"""
        {"title":"Shopping","body":"body text","note_type":"checklist","color":"#00ff00",
         "is_pinned":true,"is_archived":false,"labels":["urgent","home"],
         "checklist_items":[{"text":"milk","checked":true}],
         "sort_order":7,"edit_mode":"markdown","notebook_id":"nb1"}
        """#)
        let n = firstNote(BackupExport.build(notes: [full], metadata: nil))

        // The id is what makes a repeat restore converge instead of duplicating.
        XCTAssertEqual(n["id"] as? String, noteId)
        XCTAssertEqual(n["title"] as? String, "Shopping")
        XCTAssertEqual(n["body"] as? String, "body text")
        XCTAssertEqual(n["noteType"] as? String, "checklist")
        XCTAssertEqual(n["color"] as? String, "#00ff00")
        XCTAssertEqual(n["isPinned"] as? Bool, true)
        XCTAssertEqual(n["labels"] as? [String], ["urgent", "home"])
        XCTAssertEqual(n["sortOrder"] as? Int, 7)
        XCTAssertEqual(n["editMode"] as? String, "markdown")
        XCTAssertEqual(n["notebookId"] as? String, "nb1")
        // The checklist items travel: a checklist note whose items
        // were dropped would export as an empty note.
        let checklist = n["checklistItems"] as? [[String: Any]]
        XCTAssertEqual(checklist?.count, 1)
        XCTAssertEqual(checklist?.first?["text"] as? String, "milk")
        XCTAssertEqual(checklist?.first?["checked"] as? Bool, true)
    }

    func testCarriesANewerClientsUnknownKeysVerbatim() {
        let n = firstNote(BackupExport.build(
            notes: [record(id: noteId, content: #"{"title":"T","fromANewerClient":"keep me"}"#)],
            metadata: nil
        ))
        // Dropping these would make a backup a downgrade.
        XCTAssertEqual((n["extras"] as? [String: Any])?["fromANewerClient"] as? String, "keep me")
    }

    func testNamesTheAttachmentFilesABackupCannotCarry() {
        let doc = BackupExport.build(
            notes: [withAttachment], metadata: nil,
            attachmentNames: [noteId: ["invoice.pdf", "photo.jpg"]]
        )
        let entry = manifest(doc).first
        XCTAssertEqual(entry?["noteId"] as? String, noteId)
        // "2 notes lost their attachments" is not actionable; the names are.
        XCTAssertEqual(entry?["filenames"] as? [String], ["invoice.pdf", "photo.jpg"])
    }

    func testAnUnreadableAttachmentListStaysDistinctFromAnEmptyOne() {
        // nil means "could not read this note's attachments". An empty list
        // would claim there was nothing to lose, which is a different and
        // misleading statement.
        let unreadable = BackupExport.build(
            notes: [withAttachment], metadata: nil, attachmentNames: [noteId: nil]
        )
        XCTAssertTrue(manifest(unreadable).first?["filenames"] is NSNull)

        let none = BackupExport.build(
            notes: [withAttachment], metadata: nil, attachmentNames: [noteId: []]
        )
        XCTAssertEqual(manifest(none).first?["filenames"] as? [String], [])
    }

    func testAttachmentsMakeTheBackupDeclareItselfIncomplete() {
        let doc = BackupExport.build(notes: [withAttachment], metadata: .empty)
        // The file must never look whole when it isn't — that is the whole
        // point of carrying a manifest rather than dropping the files silently.
        XCTAssertEqual(doc["isComplete"] as? Bool, false)
        let reasons = doc["incompleteReasons"] as? [String] ?? []
        XCTAssertTrue(reasons.contains { $0.contains("attachments") })
        XCTAssertEqual((doc["counts"] as? [String: Any])?["notesWithAttachments"] as? Int, 1)
    }

    func testUnreadableMetadataIsCalledOutRatherThanSilentlyOmittingNotebooks() {
        let doc = BackupExport.build(notes: [plain], metadata: nil)
        XCTAssertEqual(doc["isComplete"] as? Bool, false)
        let reasons = doc["incompleteReasons"] as? [String] ?? []
        XCTAssertTrue(reasons.contains { $0.contains("Notebooks") })
    }

    func testAPlainNoteIsAbsentFromTheManifestAndKeepsTheBackupComplete() {
        let doc = BackupExport.build(notes: [plain], metadata: .empty)
        XCTAssertTrue(manifest(doc).isEmpty)
        XCTAssertEqual(doc["isComplete"] as? Bool, true)
    }

    func testStripsCachedRecipientKeysFromNotebookShares() {
        var meta = NotebookMetadata.empty
        meta.notebookShares = ["nb1": [
            ShareRecipientEntry(email: "a@example.com", permission: "view",
                                publicKey: "CACHED", userId: "U")
        ]]
        let shares = BackupExport.build(notes: [plain], metadata: meta)["notebookShares"] as? [String: Any]
        let entry = (shares?["nb1"] as? [[String: Any]])?.first
        XCTAssertEqual(entry?["email"] as? String, "a@example.com")
        XCTAssertEqual(entry?["permission"] as? String, "view")
        // A key that has rotated since would wrap future notes for whoever held
        // the old one, so the cache must not travel.
        XCTAssertNil(entry?["publicKey"])
        XCTAssertNil(entry?["userId"])
    }

    func testEncodesToJsonTheOtherClientsCanParse() throws {
        let doc = BackupExport.build(notes: [withAttachment], metadata: .empty)
        let data = try BackupExport.encode(doc)
        let back = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(back?["format"] as? String, "pingolin-note-backup")
        XCTAssertEqual((back?["notes"] as? [[String: Any]])?.count, 1)
        // NSNull has to survive as JSON null rather than throwing on encode —
        // it is how "could not read the list" is expressed on the wire.
        let unreadable = BackupExport.build(
            notes: [withAttachment], metadata: .empty, attachmentNames: [noteId: nil]
        )
        let text = String(data: try BackupExport.encode(unreadable), encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("\"filenames\" : null") || text.contains("\"filenames\":null"))
    }
}
