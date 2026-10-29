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

/// Reading a backup back.
///
/// The decisions that make the difference between a restore that helps and
/// one that makes a mess: preserving the id so a repeat converges, refusing
/// a file it cannot honour rather than half-reading it, and never filing a
/// note into a notebook the file does not define.
final class BackupRestoreTests: XCTestCase {

    private let noteId = "22222222-2222-4222-8222-222222222222"
    private let notebookId = "11111111-1111-4111-8111-111111111111"

    private func doc(
        notes: [[String: Any]] = [],
        notebooks: [[String: Any]]? = nil,
        extra: [String: Any] = [:]
    ) -> [String: Any] {
        var d: [String: Any] = [
            "format": "pingolin-note-backup",
            "formatVersion": 2,
            "notes": notes,
            "notebooks": notebooks ?? [["id": notebookId, "name": "Work"]],
        ]
        for (k, v) in extra { d[k] = v }
        return d
    }

    private func data(_ o: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: o)
    }

    // MARK: - Reading

    func testAcceptsABackupThisAppWrote() throws {
        let read = try BackupRestore.read(data(doc()))
        XCTAssertEqual(read["format"] as? String, "pingolin-note-backup")
    }

    func testRefusesAFileThatIsNotABackup() {
        // Silently finding zero notes in someone's TRACK export is worse than
        // telling them they picked the wrong file.
        XCTAssertThrowsError(try BackupRestore.read(data(["export": ["product": "pingolin-track"]])))
    }

    func testRefusesAFutureFormatRatherThanHalfReadingIt() {
        // Half-restoring a format this build does not understand produces an
        // account that looks whole and is not.
        var d = doc()
        d["formatVersion"] = 99
        XCTAssertThrowsError(try BackupRestore.read(data(d))) { error in
            XCTAssertTrue("\(error.localizedDescription)".contains("newer version"))
        }
    }

    func testTellsTheUserWhenTheBackupIsEncrypted() {
        // A sealed container is also JSON from the same picker, so the reader
        // has to branch on content and say what to do about it.
        let sealed: [String: Any] = ["format": "pingolin-encrypted-backup", "ciphertext": "x"]
        XCTAssertThrowsError(try BackupRestore.read(data(sealed))) { error in
            XCTAssertTrue("\(error.localizedDescription)".contains("passphrase"))
        }
    }

    func testReportsUnreadableJsonInsteadOfCrashing() {
        XCTAssertThrowsError(try BackupRestore.read(Data("{ not json".utf8)))
    }

    func testSurfacesWhatTheFileAdmitsItIsMissing() {
        let d = doc(extra: ["attachments": [["noteId": noteId, "filenames": NSNull()]]])
        XCTAssertTrue(BackupRestore.warnings(d).contains { $0.contains("attachment") })
    }

    // MARK: - Metadata merge

    func testMergingMetadataIsAdditiveAndNeverOverwrites() {
        var live = NotebookMetadata.empty
        live.notebooks = [NotebookEntry(id: "nb1", name: "Renamed since the backup")]
        live.labelColors = ["work": "#new"]

        let added = BackupRestore.mergeMetadata(doc(
            notebooks: [["id": "nb1", "name": "Old name"], ["id": "nb2", "name": "Missing one"]],
            extra: ["labelColors": ["work": "#old", "home": "#green"]]
        ), into: &live)

        // Someone restoring has already had something go wrong; winding their
        // newer edits back is the wrong way to help.
        XCTAssertEqual(added, 1)
        XCTAssertEqual(live.notebooks.count, 2)
        XCTAssertEqual(live.notebooks[0].name, "Renamed since the backup")
        XCTAssertEqual(live.labelColors["work"], "#new")
        XCTAssertEqual(live.labelColors["home"], "#green")
    }

    func testMergingStripsCachedRecipientKeys() {
        var live = NotebookMetadata.empty
        _ = BackupRestore.mergeMetadata(doc(extra: [
            "notebookShares": ["nb1": [["email": "a@example.com", "permission": "view",
                                        "publicKey": "CACHED", "userId": "U"]]]
        ]), into: &live)
        let r = live.notebookShares["nb1"]?.first
        XCTAssertEqual(r?.email, "a@example.com")
        // A key that has rotated since would wrap future notes for whoever held
        // the old one, so a restore must look recipients up fresh.
        XCTAssertNil(r?.publicKey)
        XCTAssertNil(r?.userId)
    }

    // MARK: - Building the create request

    private let vaultKey = Data(repeating: 0, count: 32).base64EncodedString()

    func testPreservesTheNoteId() throws {
        let note: [String: Any] = ["id": noteId, "title": "Shopping", "body": "b"]
        let req = try XCTUnwrap(BackupRestore.createRequest(
            for: note, knownNotebooks: [], vaultKeyBase64: vaultKey
        ))
        // The id is what makes restoring the same file twice converge: the
        // server's insert does nothing on conflict and answers 409.
        XCTAssertEqual(req.id, noteId)
        XCTAssertEqual(req.itemType, 1)
        XCTAssertFalse(req.encryptedContent.isEmpty)
    }

    func testRefusesAMalformedId() {
        // A bad id would be rejected and LOSE the note; dropping it only costs
        // idempotence for that row — but there is no id here to fall back to,
        // so the note is skipped and counted rather than silently mangled.
        XCTAssertNil(BackupRestore.createRequest(
            for: ["id": "not-a-uuid", "title": "T"], knownNotebooks: [], vaultKeyBase64: vaultKey
        ))
        XCTAssertNil(BackupRestore.createRequest(
            for: ["title": "no id at all"], knownNotebooks: [], vaultKeyBase64: vaultKey
        ))
    }

    func testFilesANoteOnlyIntoANotebookTheFileDefines() throws {
        let note: [String: Any] = ["id": noteId, "notebookId": notebookId]

        let filed = try XCTUnwrap(BackupRestore.createRequest(
            for: note, knownNotebooks: [notebookId], vaultKeyBase64: vaultKey
        ))
        XCTAssertEqual(filed.notebookId, notebookId)

        // A dangling id would file the note somewhere the user has no way to
        // open. Better unfiled and visible.
        let orphan = try XCTUnwrap(BackupRestore.createRequest(
            for: note, knownNotebooks: [], vaultKeyBase64: vaultKey
        ))
        XCTAssertNil(orphan.notebookId)
    }

    func testKnownNotebooksReadsTheFilesOwnList() {
        XCTAssertEqual(BackupRestore.knownNotebooks(doc()), [notebookId])
        XCTAssertTrue(BackupRestore.knownNotebooks(doc(notebooks: [])).isEmpty)
    }

    func testA409IsReadAsAlreadyRestoredRatherThanAFailure() {
        // The route answers a plain 409 deliberately — a 500 would confirm to
        // another tenant that an id exists — so there is no error code to match
        // on and the status is the only signal.
        XCTAssertTrue(APIError(code: "http_409", message: "exists", status: 409).isAlreadyPresent)
        XCTAssertFalse(APIError(code: "quota", message: "nope", status: 402).isAlreadyPresent)
        XCTAssertFalse(APIError(code: "boom", message: "nope").isAlreadyPresent)
    }
}
