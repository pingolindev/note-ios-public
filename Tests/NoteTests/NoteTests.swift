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

final class NoteTests: XCTestCase {
    func testAppLaunches() throws {
        XCTAssertTrue(true)
    }
}

/// Cross-platform schema guard: note-android writes fields into the
/// same encrypted JSON that this client doesn't model (`color`,
/// `checklist_items`) — and either app may add keys the other hasn't
/// shipped yet. A save from iOS must round-trip every one of them;
/// without `DecodedNote.extras` it would silently strip all unknown
/// keys on every edit.
final class DecodedNoteRoundTripTests: XCTestCase {

    private let androidJSON = """
    {"title":"t","body":"b","note_type":"checklist","color":"#FF5722",\
    "is_pinned":false,"is_archived":false,"labels":["l1"],"sort_order":3,\
    "edit_mode":"rich",\
    "checklist_items":[{"text":"milk","checked":true},{"text":"eggs","checked":false}],\
    "future_field":{"nested":[1,2,3]}}
    """

    func testDecodeCapturesUnknownKeysAndTypedFields() throws {
        let note = try DecodedNote.decode(from: Data(androidJSON.utf8))

        XCTAssertEqual(note.title, "t")
        XCTAssertEqual(note.noteType, "checklist")
        XCTAssertEqual(note.sortOrder, 3)
        XCTAssertEqual(note.editMode, "rich")
        XCTAssertEqual(note.labels, ["l1"])
        XCTAssertEqual(Set(note.extras.keys), ["color", "checklist_items", "future_field"])
    }

    func testEditedSavePreservesAndroidFields() throws {
        let note = try DecodedNote.decode(from: Data(androidJSON.utf8))

        // Rebuild with edits, extras passed through — the shape of
        // a save.
        let edited = DecodedNote(
            title: "edited",
            body: "new body",
            noteType: note.noteType,
            isPinned: true,
            isArchived: note.isArchived,
            labels: note.labels,
            sortOrder: note.sortOrder,
            editMode: note.editMode,
            extras: note.extras
        )
        let out = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(edited.encodeJSON().utf8)) as? [String: Any]
        )

        XCTAssertEqual(out["title"] as? String, "edited")
        XCTAssertEqual(out["is_pinned"] as? Bool, true)
        XCTAssertEqual(out["color"] as? String, "#FF5722")
        XCTAssertEqual(out["edit_mode"] as? String, "rich")
        XCTAssertEqual(out["sort_order"] as? Int, 3)
        let checklist = try XCTUnwrap(out["checklist_items"] as? [[String: Any]])
        XCTAssertEqual(checklist.count, 2)
        XCTAssertEqual(checklist[0]["text"] as? String, "milk")
        XCTAssertEqual(checklist[0]["checked"] as? Bool, true)
        let future = try XCTUnwrap(out["future_field"] as? [String: Any])
        XCTAssertEqual(future["nested"] as? [Int], [1, 2, 3])
    }

    func testWholeNumberExtrasStayIntegers() throws {
        let note = try DecodedNote.decode(from: Data(#"{"title":"t","body":"b","count":7}"#.utf8))

        let json = try note.encodeJSON()

        XCTAssertTrue(json.contains("\"count\":7"), "got \(json)")
        XCTAssertFalse(json.contains("7.0"), "whole numbers must not grow a decimal point: \(json)")
    }

    func testWithoutExtrasEmitsOnlyKnownKeys() throws {
        let note = DecodedNote(
            title: "a", body: "b", noteType: "text",
            isPinned: false, isArchived: false,
            labels: [], sortOrder: 0, editMode: "rich"
        )
        let out = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(note.encodeJSON().utf8)) as? [String: Any]
        )

        let allowed: Set<String> = [
            "title", "body", "note_type", "is_pinned", "is_archived",
            "labels", "sort_order", "edit_mode",
        ]
        XCTAssertTrue(Set(out.keys).isSubset(of: allowed), "unexpected keys: \(out.keys)")
    }
}

/// Inbox materialization (android parity): shared
/// notes render in the main list straight from the inbox payload —
/// /sync/pull never delivers them — and edits to a shared note must
/// never carry a wrap field.
@MainActor
final class SharesInboxMaterializationTests: XCTestCase {

    private func share(itemId: String = "item-1", itemType: Int? = nil) -> InboxShareResponse {
        InboxShareResponse(
            shareId: "share-1",
            itemId: itemId,
            ownerId: "owner-1",
            permission: "edit",
            wrappedKey: "sealed",
            sharerPublicKey: nil,
            ownerEmail: "test-user1@example.test",
            wrapSignature: nil,
            encryptedContent: "ciphertext",
            contentNonce: "nonce",
            updatedAt: Date(timeIntervalSince1970: 2000),
            createdAt: Date(timeIntervalSince1970: 1000),
            // Declared last on InboxShareResponse and a `let`
            // optional, so Swift's memberwise init does NOT default
            // it to nil — every construction has to name it. nil =
            // a row with no recorded content-key generation, which
            // is what this fixture models.
            contentKeyGeneration: nil,
            itemType: itemType
        )
    }

    private func sharedNote(itemId: String, note: DecodedNote?, error: String? = nil) -> SharesInboxStore.SharedNote {
        SharesInboxStore.SharedNote(
            item: SharesInboxStore.synthesizeItem(from: share(itemId: itemId)),
            shareId: "share-1",
            note: note,
            decryptError: error,
            ownerEmail: "test-user1@example.test",
            permission: "edit"
        )
    }

    func testSynthesizedItemMirrorsAndroidMaterialization() {
        let item = SharesInboxStore.synthesizeItem(from: share())

        XCTAssertEqual(item.id, "item-1")
        XCTAssertEqual(item.userId, "owner-1", "item is owned by the sharer, mirroring what sync would store")
        XCTAssertEqual(item.itemType, ItemType.note.rawValue)
        XCTAssertEqual(item.version, 1, "inbox payload carries no version")
        XCTAssertNil(item.wrappedContentKey, "recipients decrypt via the inbox key, never a vault wrap")
        XCTAssertNil(item.wrappedContentKeyNonce)
        XCTAssertFalse(item.deleted)
        XCTAssertEqual(item.contentSize, "ciphertext".count)
        XCTAssertEqual(item.createdAt, Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(item.updatedAt, Date(timeIntervalSince1970: 2000))
    }

    func testMaterializedRowsSkipIdsAlreadyPulled() {
        let rows = SharesInboxStore.materializedRows(
            shared: [
                sharedNote(itemId: "pulled", note: DecodedNote(title: "a", body: "")),
                sharedNote(itemId: "fresh", note: DecodedNote(title: "b", body: "")),
            ],
            pulledIds: ["pulled"],
            priorNotes: [:]
        )

        XCTAssertEqual(rows.map(\.id), ["fresh"], "sync-pulled copy wins over the inbox copy")
    }

    func testMaterializedRowsFallBackToPriorDecodeOnDecryptFailure() {
        let prior = DecodedNote(title: "last known good", body: "kept")

        let rows = SharesInboxStore.materializedRows(
            shared: [sharedNote(itemId: "item-1", note: nil, error: "decrypt failed")],
            pulledIds: [],
            priorNotes: ["item-1": prior]
        )

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].note?.title, "last known good")
        XCTAssertNil(rows[0].decryptError)
    }

    func testMaterializedRowsSkipUndecryptableWithoutPrior() {
        let rows = SharesInboxStore.materializedRows(
            shared: [sharedNote(itemId: "item-1", note: nil, error: "decrypt failed")],
            pulledIds: [],
            priorNotes: [:]
        )

        XCTAssertTrue(rows.isEmpty, "android skips undecryptable shares rather than rendering a stub")
    }

    // MARK: - reconcile (un-share / delete propagation)

    private func owned(_ id: String) -> DecryptedItem {
        DecryptedItem(
            item: SharesInboxStore.synthesizeItem(from: share(itemId: id)),
            note: DecodedNote(title: id, body: ""),
            decryptError: nil
        )
    }

    func testReconcileDropsUnsharedNote() {
        // Owned O stays; share S was materialized but the inbox no
        // longer lists it (un-shared / owner-deleted) → S drops.
        let result = SharesInboxStore.reconcile(
            displayed: [owned("O"), owned("S")],
            materializedShareIds: ["S"],
            shared: [],
            priorNotes: [:]
        )

        XCTAssertEqual(result.rows.map(\.id), ["O"], "the revoked share is dropped, the owned row stays")
        XCTAssertTrue(result.materializedShareIds.isEmpty)
    }

    func testReconcileAddsNewlyArrivedShare() {
        let result = SharesInboxStore.reconcile(
            displayed: [owned("O")],
            materializedShareIds: [],
            shared: [sharedNote(itemId: "S", note: DecodedNote(title: "shared", body: ""))],
            priorNotes: [:]
        )

        XCTAssertEqual(Set(result.rows.map(\.id)), ["O", "S"], "a share that joined the inbox is materialized in")
        XCTAssertEqual(result.materializedShareIds, ["S"])
    }

    func testReconcileReplacesUndecryptablePulledShareWithInboxCopy() {
        // The backend delivers a share via /sync/pull carrying the owner's
        // wrap (undecryptable by us); the inbox copy, decrypted with the
        // key sealed to us, must supersede it — not render "[decrypt failed]".
        let pulledUndecryptable = DecryptedItem(
            item: SharesInboxStore.synthesizeItem(from: share(itemId: "S")),
            note: nil,
            decryptError: "owner's wrap — not ours to unwrap"
        )
        let result = SharesInboxStore.reconcile(
            displayed: [owned("O"), pulledUndecryptable],
            materializedShareIds: [],   // first load: the pulled row isn't flagged a share yet
            shared: [sharedNote(itemId: "S", note: DecodedNote(title: "decrypted via inbox key", body: ""))],
            priorNotes: [:]
        )

        let s = result.rows.first { $0.id == "S" }
        XCTAssertEqual(s?.note?.title, "decrypted via inbox key", "inbox copy supersedes the undecryptable pulled row")
        XCTAssertNil(s?.decryptError)
        XCTAssertEqual(result.rows.filter { $0.id == "S" }.count, 1, "no duplicate share row")
        XCTAssertEqual(result.rows.first?.id, "O", "owned row untouched and kept first")
    }

    func testReconcileRefreshesAlreadyDisplayedShareWithoutDuplicating() {
        // A share already shown (prior materialization) and still in the
        // inbox is refreshed in place, never duplicated.
        let shownStale = DecryptedItem(
            item: SharesInboxStore.synthesizeItem(from: share(itemId: "S")),
            note: DecodedNote(title: "old", body: ""),
            decryptError: nil
        )
        let result = SharesInboxStore.reconcile(
            displayed: [owned("O"), shownStale],
            materializedShareIds: ["S"],
            shared: [sharedNote(itemId: "S", note: DecodedNote(title: "fresh", body: ""))],
            priorNotes: [:]
        )

        XCTAssertEqual(result.rows.filter { $0.id == "S" }.count, 1, "share appears exactly once")
        XCTAssertEqual(result.rows.first { $0.id == "S" }?.note?.title, "fresh", "refreshed from the inbox copy")
    }

    func testReconcileIsIdempotent() {
        let displayed = [owned("O"), owned("S")]
        let shared = [sharedNote(itemId: "S", note: DecodedNote(title: "s", body: ""))]

        let once = SharesInboxStore.reconcile(
            displayed: displayed, materializedShareIds: ["S"], shared: shared, priorNotes: [:])
        let twice = SharesInboxStore.reconcile(
            displayed: once.rows, materializedShareIds: once.materializedShareIds,
            shared: shared, priorNotes: [:])

        XCTAssertEqual(once.rows.map(\.id), twice.rows.map(\.id), "running reconcile again changes nothing")
        XCTAssertEqual(once.materializedShareIds, twice.materializedShareIds)
    }

    func testReconcileKeepsLastKnownContentForStillSharedButUndecryptable() {
        // S is still shared but came back undecryptable this round; the
        // already-displayed decoded row is kept (last-known-good), not
        // dropped or blanked.
        let shown = DecryptedItem(
            item: SharesInboxStore.synthesizeItem(from: share(itemId: "S")),
            note: DecodedNote(title: "last good", body: "keep"),
            decryptError: nil
        )
        let result = SharesInboxStore.reconcile(
            displayed: [shown],
            materializedShareIds: ["S"],
            shared: [sharedNote(itemId: "S", note: nil, error: "decrypt failed")],
            priorNotes: ["S": DecodedNote(title: "last good", body: "keep")]
        )

        XCTAssertEqual(result.rows.map(\.id), ["S"])
        XCTAssertEqual(result.rows.first?.note?.title, "last good")
    }

    // MARK: - version adoption from the pulled copy

    private func pulledShareRow(_ id: String, version: Int64) -> DecryptedItem {
        let base = SharesInboxStore.synthesizeItem(from: share(itemId: id))
        let pulled = Item(
            id: base.id, userId: base.userId, itemType: base.itemType,
            encryptedContent: base.encryptedContent, contentNonce: base.contentNonce,
            version: version, createdAt: base.createdAt, updatedAt: base.updatedAt,
            deleted: false, deletedAt: nil, circleId: nil, contentSize: base.contentSize,
            notebookId: nil, wrappedContentKey: "owner-wrap", wrappedContentKeyNonce: "n",
            contentKeyGeneration: nil
        )
        return DecryptedItem(item: pulled, note: nil, decryptError: "owner's wrap")
    }

    func testReconcileAdoptsPulledVersionForMaterializedShare() {
        // /sync/pull delivered the share at v5 (undecryptable, owner's
        // wrap); the materialized row keeps the inbox-decrypted content but
        // adopts v5 so the first edit doesn't 409 on the placeholder v1.
        let result = SharesInboxStore.reconcile(
            displayed: [owned("O"), pulledShareRow("S", version: 5)],
            materializedShareIds: [],
            shared: [sharedNote(itemId: "S", note: DecodedNote(title: "from inbox", body: ""))],
            priorNotes: [:]
        )

        let s = result.rows.first { $0.id == "S" }
        XCTAssertEqual(s?.item.version, 5, "adopts the version /sync/pull delivered")
        XCTAssertEqual(s?.note?.title, "from inbox", "content still comes from the inbox key")
    }

    func testReconcileKeepsSynthesizedVersionWhenShareNotPulled() {
        // Inbox-only share (no pulled copy to learn the version from) keeps
        // the synthesized v1 — updateSharedNote's retry covers the 409.
        let result = SharesInboxStore.reconcile(
            displayed: [owned("O")],
            materializedShareIds: [],
            shared: [sharedNote(itemId: "S", note: DecodedNote(title: "inbox only", body: ""))],
            priorNotes: [:]
        )

        XCTAssertEqual(result.rows.first { $0.id == "S" }?.item.version, 1)
    }

    // MARK: - Notebook shares are not notes

    /// The notebook object carries a collection's name and its roster, not a
    /// document. Treating it as a note would put a phantom entry titled with
    /// the notebook's name in the recipient's list.
    func testSharedNotebookIsRecognisedAsANotebook() {
        XCTAssertTrue(share(itemId: "nb-1", itemType: 2).isNotebook)
        XCTAssertFalse(share(itemId: "item-1", itemType: 1).isNotebook)
    }

    /// An older server omits the field. Swift's Decodable THROWS on a missing
    /// non-optional key, so it is optional and absent means note — what every
    /// client assumed before the field existed.
    func testAbsentItemTypeReadsAsANote() {
        let s = share()
        XCTAssertNil(s.itemType)
        XCTAssertEqual(s.itemTypeOrNote, 1)
        XCTAssertFalse(s.isNotebook)
    }

    /// The inbox JSON really does decode without the field.
    func testInboxRowDecodesWithoutAnItemType() throws {
        let json = """
        {"share_id":"s","item_id":"i","owner_id":"o","permission":"view",
         "encrypted_content":"e","content_nonce":"n",
         "created_at":"2024-01-01T00:00:00Z","updated_at":"2024-01-01T00:00:00Z"}
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let fmt = ISO8601DateFormatter()
        decoder.dateDecodingStrategy = .custom { d in
            let c = try d.singleValueContainer()
            let raw = try c.decode(String.self)
            guard let date = fmt.date(from: raw) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "bad date")
            }
            return date
        }
        let row = try decoder.decode(InboxShareResponse.self, from: json)
        XCTAssertFalse(row.isNotebook)
    }
}

/// The materialized share's expectedVersion is a placeholder (the
/// inbox carries no version → 1), so the first edit of an
/// owner-revised note 409s. APIService.retryingOnVersionConflict
/// turns that stale-version 409 into a refetch-and-retry instead
/// of a surfaced error.
final class SharedNoteVersionRetryTests: XCTestCase {

    private func item(version: Int64) -> Item {
        Item(
            id: "item-1", userId: "owner", itemType: ItemType.note.rawValue,
            encryptedContent: "c", contentNonce: "n", version: version,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            deleted: false, deletedAt: nil, circleId: nil, contentSize: 1,
            notebookId: nil, wrappedContentKey: nil, wrappedContentKeyNonce: nil,
            contentKeyGeneration: nil
        )
    }

    func testRetriesWithLiveVersionOnConflict() async throws {
        var attempts: [Int64] = []
        var liveVersionCalls = 0

        let result = try await APIService.retryingOnVersionConflict(
            expectedVersion: 1,
            put: { version in
                attempts.append(version)
                if version == 1 {
                    throw APIError(code: "item_version_conflict", message: "stale", status: 409)
                }
                return self.item(version: version)
            },
            liveVersion: { liveVersionCalls += 1; return 7 }
        )

        XCTAssertEqual(attempts, [1, 7], "retries with the refetched live version after a 409")
        XCTAssertEqual(liveVersionCalls, 1)
        XCTAssertEqual(result.version, 7)
    }

    func testSucceedsFirstTryWithoutRefetch() async throws {
        var liveVersionCalls = 0

        let result = try await APIService.retryingOnVersionConflict(
            expectedVersion: 3,
            put: { self.item(version: $0) },
            liveVersion: { liveVersionCalls += 1; return 99 }
        )

        XCTAssertEqual(result.version, 3)
        XCTAssertEqual(liveVersionCalls, 0, "no refetch when the first PUT succeeds")
    }

    func testNonConflictErrorPropagatesWithoutRetry() async {
        var attempts = 0
        var liveVersionCalls = 0

        do {
            _ = try await APIService.retryingOnVersionConflict(
                expectedVersion: 1,
                put: { _ in attempts += 1; throw APIError(code: "http_500", message: "boom", status: 500) },
                liveVersion: { liveVersionCalls += 1; return 2 }
            )
            XCTFail("expected the 500 to propagate")
        } catch let err as APIError {
            XCTAssertEqual(err.status, 500)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertEqual(attempts, 1, "a non-409 error must not retry")
        XCTAssertEqual(liveVersionCalls, 0)
    }

    func testSecondConflictPropagates() async {
        // Owner revises again between our refetch and retry: the second
        // 409 surfaces rather than looping.
        do {
            _ = try await APIService.retryingOnVersionConflict(
                expectedVersion: 1,
                put: { _ in throw APIError(code: "conflict", message: "stale", status: 409) },
                liveVersion: { 5 }
            )
            XCTFail("expected the second 409 to propagate")
        } catch let err as APIError {
            XCTAssertEqual(err.status, 409)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}


/// Mirrors android NotificationDetailTest: redaction levels for the
/// local-notification + widget-snapshot surfaces.
final class NotificationDetailTests: XCTestCase {

    func testReminderTitleByLevel() {
        XCTAssertEqual(NotificationDetail.reminderTitle(.full, noteTitle: "Groceries"), "Groceries")
        XCTAssertEqual(NotificationDetail.reminderTitle(.titles, noteTitle: "Groceries"), "Groceries")
        XCTAssertEqual(NotificationDetail.reminderTitle(.generic, noteTitle: "Groceries"), "Note reminder")
        XCTAssertEqual(NotificationDetail.reminderTitle(.full, noteTitle: ""), "Note reminder")
    }

    func testPinnedTitleByLevel() {
        XCTAssertEqual(NotificationDetail.pinnedTitle(.full, noteTitle: "Secret"), "Secret")
        XCTAssertEqual(NotificationDetail.pinnedTitle(.titles, noteTitle: "Secret"), "Secret")
        XCTAssertEqual(NotificationDetail.pinnedTitle(.generic, noteTitle: "Secret"), "Pinned note")
        XCTAssertEqual(NotificationDetail.pinnedTitle(.titles, noteTitle: ""), "Pinned note")
    }

    func testPinnedSnippetOnlySurvivesFull() {
        XCTAssertEqual(NotificationDetail.pinnedSnippet(.full, snippet: "body"), "body")
        XCTAssertNil(NotificationDetail.pinnedSnippet(.titles, snippet: "body"))
        XCTAssertNil(NotificationDetail.pinnedSnippet(.generic, snippet: "body"))
    }

    func testUnknownStoredLevelNormalizesToFull() {
        XCTAssertEqual(NotificationDetailLevel(rawValue: "bogus") ?? .full, .full)
    }
}


/// Guard for the share-wrap fail-closed rule.
/// `SharesInboxStore.decide` drops a pinned sender's share unless the
/// wrap's signature verifies — i.e. on an explicit `false` (invalid) OR
/// a `nil`. This locks the reachable `nil` case: a MALFORMED /
/// unparseable signature makes the SDK's `verifyNoteShareWrap` throw,
/// which `WrapSigner.verifyInboundGen` maps to `nil`. Testing
/// `== false` instead grace-keeps that `nil`, letting a
/// server-substituted wrap (an attacker-chosen content key + garbage
/// signature bytes) materialize under a trusted, TOFU-pinned identity
/// with no key-change alarm. Mirrors the Android app's `if (ok != true)`.
@MainActor
final class WrapSignerVerifyInboundTests: XCTestCase {

    func testMalformedSignatureYieldsNilNotAuthentic() {
        // verifyInboundGen also reports the generation the signature actually
        // verified under, so the verdict is a tuple.
        let result = WrapSigner.verifyInboundGen(
            signingPubkeyHex: "not-a-hex-signing-key",
            signatureHex: "zzzz-not-valid-hex",
            senderUserId: "sender-1",
            recipientUserId: "recipient-1",
            itemId: "item-1",
            contentKeyVersion: 1,
            wrappedKeyB64: "c2VhbGVk"
        )
        // A malformed signature must NEVER read as authentic; the SDK throws on
        // un-decodable input and `verifyInboundGen` maps that to `nil`. The
        // fail-closed `!= true` verdict drops both `nil` and `false`.
        XCTAssertNil(result, "verifyInboundGen maps a thrown (malformed) verify to nil")
        XCTAssertNotEqual(result?.verified, true, "malformed input must never verify as authentic")
    }

}
