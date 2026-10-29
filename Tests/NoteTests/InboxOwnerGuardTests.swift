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
import PingolinNoteSDK
@testable import Note

/// The native inbox's verdict against the REAL pin and floor stores (over a
/// scratch UserDefaults suite).
/// - Every id is canonical before anything reads it; a store that can't be
///   read is never "empty"; no own id → nothing fetched.
/// - A share of an item this device holds as someone else's — ours by user
///   id or by a wrap our vault opens, or another owner's — or naming this
///   account as its sender, is refused before anything is unwrapped.
/// - Each item is bound to the owner of its first accepted share; anyone
///   else's share of it is refused, and a binding survives a refresh without
///   the owner's share.
/// - A first share whose directory entry names another account is refused.
/// - A note is sent as what opened it: a row our vault opens (by its wrap, or
///   with no wrap by its body) is ours whatever its user id says, the pull
///   caches it whatever the inbox names, and the drain never treats it as a
///   share's.
@MainActor
final class InboxOwnerGuardTests: XCTestCase {

    private let me = "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"
    private let alice = "2a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"
    private let bob = "3a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"
    private let item = "4a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"
    private let signA = String(repeating: "a", count: 64)
    private let shareA = String(repeating: "b", count: 64)
    private let signB = String(repeating: "c", count: 64)
    private let sig = String(repeating: "cd", count: 64)
    private let notConfirmed = "This share couldn't be confirmed as coming from its sender, so it wasn't opened. Ask them to share it again."
    private let forged = "This share couldn't be confirmed as coming from its sender, so it wasn't opened. Check with them another way before trusting a new copy."
    private let damaged = "This share is damaged, so it couldn't be opened. Ask the sender to share it again."
    private let outOfDate = "This share is out of date, so it wasn't opened. Ask the sender to share it again."

    private var suite = ""
    private var defaults: UserDefaults!
    private var pins: SenderKeyPinStore!
    private var floors: NoteGenFloorStore!
    private var rows: [String: ItemRecord] = [:]
    private var vaultOpens: Set<String> = []
    private var verdict: (verified: Bool, effectiveGeneration: UInt32)? = (true, 1)
    private var verifyCalls = 0
    private var verifyIds: [[String]] = []
    private var pinReads = 0

    override func setUpWithError() throws {
        suite = "InboxOwnerGuardTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        pins = SenderKeyPinStore(defaults: defaults)
        floors = NoteGenFloorStore(defaults: defaults)
        pins.switchUser(me)
        floors.switchUser(me)
        rows = [:]
        vaultOpens = []
        verdict = (true, 1)
        verifyCalls = 0
        verifyIds = []
        pinReads = 0
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    private var trust: SharesInboxStore.Trust {
        SharesInboxStore.Trust(
            pinned: { [unowned self] in pinReads += 1; return try pins.getPinned($0) },
            owner: { [unowned self] in try floors.owner($0) },
            floor: { [unowned self] in try floors.floor($0) },
            accept: { [unowned self] in try floors.accept($0, owner: $1, generation: $2) },
            verify: { [unowned self] _, _, sender, recipient, item, _, _ in
                verifyCalls += 1
                verifyIds.append([sender, recipient, item])
                return verdict
            },
            row: { [unowned self] in rows[$0] },
            opensUnderOurVault: { [unowned self] row in row.wrappedContentKey.map { vaultOpens.contains($0) } ?? false }
        )
    }

    private let aliceDir = SharesInboxStore.DirectoryKeys(userId: "2a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d", signingPub: String(repeating: "a", count: 64), sharingPub: String(repeating: "b", count: 64))
    private var directory: [String: SharesInboxStore.DirectoryKeys] { ["alice@x.y": aliceDir] }

    private func share(owner: String? = nil, itemId: String? = nil, email: String = "alice@x.y", signature: String? = nil,
                       generation: Int64? = 1, itemType: Int? = nil) -> InboxShareResponse {
        InboxShareResponse(
            shareId: UUID().uuidString, itemId: itemId ?? item, ownerId: owner ?? alice, permission: "edit",
            wrappedKey: "sealed", sharerPublicKey: nil, ownerEmail: email, wrapSignature: signature,
            encryptedContent: "enc", contentNonce: "nonce",
            updatedAt: Date(timeIntervalSince1970: 2000), createdAt: Date(timeIntervalSince1970: 1000),
            contentKeyGeneration: generation, itemType: itemType
        )
    }

    private func row(userId: String, wrap: String? = nil) -> ItemRecord {
        ItemRecord(
            id: item, userId: userId, itemType: 1, encryptedContent: "own", contentNonce: "n",
            decryptedContent: nil, title: nil, version: 1,
            createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1),
            deleted: false, deletedAt: nil, circleId: nil, notebookId: nil, contentSize: 0,
            color: nil, isPinned: false, isArchived: false, isDirty: false, pendingRestore: false,
            wrappedContentKey: wrap, wrappedContentKeyNonce: wrap.map { _ in "wn" }, sortOrder: 0
        )
    }

    private func decide(_ inbox: [InboxShareResponse], directory: [String: SharesInboxStore.DirectoryKeys]? = nil) throws -> SharesInboxStore.Verdict {
        try SharesInboxStore.decide(inbox, me: me, directory: directory ?? self.directory, trust: trust)
    }

    // MARK: - ids

    func testIdsThatAreNoUUIDAreRefusedBeforeAnythingReadsThem() throws {
        let v = try decide([share(owner: "owner-1"), share(itemId: "item-1"), share(itemId: "{\(item)}x")])
        XCTAssertEqual(v.blocked.map(\.reason), [notConfirmed, damaged, damaged])
        XCTAssertTrue(v.admitted.isEmpty)
        XCTAssertEqual(pinReads, 0)
        XCTAssertEqual(verifyCalls, 0)
    }

    func testEverySpellingOfAPinnedOwnerIsVerifiedAgainstThePinAndTheSharesIdsAreCanonical() throws {
        try pins.pin(ownerId: alice, signingPubHex: signA, sharingPubHex: shareA)
        for (owner, itemId) in [(alice.uppercased(), item.uppercased()), (alice.replacingOccurrences(of: "-", with: ""), "{\(item)}"),
                                ("urn:uuid:\(alice)", item.replacingOccurrences(of: "-", with: "").uppercased())] {
            verifyCalls = 0
            verdict = (false, 0)
            verifyIds = []
            let v = try decide([share(owner: owner, itemId: itemId, signature: sig)])
            XCTAssertEqual(v.blocked.map(\.reason), [forged], owner)
            XCTAssertEqual(verifyCalls, 1, owner)
            // The signature is checked over the ids' one form: sender, this account, item.
            XCTAssertEqual(verifyIds, [[alice, me, item]], owner)
        }
        verdict = (true, 2)
        let v = try decide([share(owner: alice.uppercased(), itemId: item.uppercased(), signature: sig)])
        XCTAssertEqual(v.admitted.map { [$0.share.ownerId, $0.share.itemId] }, [[alice, item]])
    }

    // MARK: - Shares of our own rows

    func testAShareOfOneOfOurOwnRowsIsRefusedByUserIdOrByAWrapOurVaultOpens() throws {
        rows[item] = row(userId: me.uppercased())
        XCTAssertEqual(try decide([share()]).blocked.map(\.reason), [notConfirmed])
        // The row is looked up by the item's one form, whatever spelling the share serves.
        XCTAssertEqual(try decide([share(itemId: "{\(item.uppercased())}")]).blocked.map(\.reason), [notConfirmed])
        rows[item] = row(userId: alice, wrap: "own-wrap")
        vaultOpens = ["own-wrap"]
        let v = try decide([share()])
        XCTAssertEqual(v.blocked.map(\.reason), [notConfirmed])
        XCTAssertTrue(v.admitted.isEmpty)
        XCTAssertEqual(pinReads, 0)
    }

    func testAShareOfAnotherOwnersRowOrFromThisAccountIsRefused() throws {
        rows[item] = row(userId: bob)
        XCTAssertEqual(try decide([share()]).blocked.map(\.reason), [notConfirmed])
        rows = [:]
        // An e-mail with no directory entry, so the directory-entry rule is not the
        // one that refuses it.
        XCTAssertEqual(try decide([share(owner: me.uppercased(), email: "me@x.y")]).blocked.map(\.reason), [notConfirmed])
    }

    func testThatOwnersRowIsNotInTheWay() throws {
        rows[item] = row(userId: alice.uppercased(), wrap: "owners-wrap")
        let v = try decide([share()])
        XCTAssertEqual(v.admitted.count, 1)
        XCTAssertTrue(v.blocked.isEmpty)
    }

    // MARK: - what our vault opens

    /// Real crypto: a wrap our vault opens, or, on a row with no wrap (a note from
    /// before per-note keys), a body it opens. A wrapped row is judged by its wrap.
    func testOurVaultOpensARowByItsWrapOrWithNoWrapByItsBody() throws {
        let vault = generateContentKey()
        let other = generateContentKey()
        let legacy = try encryptNoteWithContentKeyV2(plaintext: "{}", contentKey: vault, itemId: item)
        var body = row(userId: alice)
        body.encryptedContent = legacy.ciphertextB64
        body.contentNonce = legacy.nonceB64
        XCTAssertTrue(SharesInboxStore.opensUnder(body, vaults: [other.base64EncodedString(), vault.base64EncodedString()]))
        XCTAssertFalse(SharesInboxStore.opensUnder(body, vaults: [other.base64EncodedString()]))

        let wrap = try wrapWithVault(contentKey: generateContentKey(), vaultKey: vault)
        var wrapped = row(userId: alice, wrap: wrap.wrappedKeyB64)
        wrapped.wrappedContentKeyNonce = wrap.nonceB64
        XCTAssertTrue(SharesInboxStore.opensUnder(wrapped, vaults: [vault.base64EncodedString()]))
        XCTAssertFalse(SharesInboxStore.opensUnder(wrapped, vaults: [other.base64EncodedString()]))

        let otherWrap = try wrapWithVault(contentKey: generateContentKey(), vaultKey: other)
        var theirs = body
        theirs.wrappedContentKey = otherWrap.wrappedKeyB64
        theirs.wrappedContentKeyNonce = otherWrap.nonceB64
        XCTAssertFalse(SharesInboxStore.opensUnder(theirs, vaults: [vault.base64EncodedString()]), "a wrapped row is judged by its wrap")
    }

    func testAShareOfALegacyRowOurVaultOpensIsRefusedWhateverItsUserId() throws {
        let vault = generateContentKey()
        let legacy = try encryptNoteWithContentKeyV2(plaintext: "{}", contentKey: vault, itemId: item)
        var relabelled = row(userId: alice)
        relabelled.encryptedContent = legacy.ciphertextB64
        relabelled.contentNonce = legacy.nonceB64
        rows[item] = relabelled
        var t = trust
        t.opensUnderOurVault = { SharesInboxStore.opensUnder($0, vaults: [vault.base64EncodedString()]) }
        let v = try SharesInboxStore.decide([share()], me: me, directory: directory, trust: t)
        XCTAssertEqual(v.blocked.map(\.reason), [notConfirmed])
        XCTAssertTrue(v.admitted.isEmpty)
        XCTAssertEqual(pinReads, 0)
        XCTAssertNil(try floors.owner(item))
    }

    func testTheDrainTreatsARowAsAShareOnlyWhenTheInboxNamesItAndItIsNotOurs() throws {
        let vault = generateContentKey()
        let vaults = [vault.base64EncodedString()]
        XCTAssertTrue(SharesInboxStore.isSharesRow(row(userId: alice), inboxNamesIt: true, me: me, vaults: vaults))
        XCTAssertFalse(SharesInboxStore.isSharesRow(row(userId: alice), inboxNamesIt: false, me: me, vaults: vaults))
        XCTAssertFalse(SharesInboxStore.isSharesRow(row(userId: me.uppercased()), inboxNamesIt: true, me: me, vaults: vaults))
        let wrap = try wrapWithVault(contentKey: generateContentKey(), vaultKey: vault)
        var ours = row(userId: alice, wrap: wrap.wrappedKeyB64)
        ours.wrappedContentKeyNonce = wrap.nonceB64
        XCTAssertFalse(SharesInboxStore.isSharesRow(ours, inboxNamesIt: true, me: me, vaults: vaults))
        XCTAssertFalse(SharesInboxStore.isSharesRow(row(userId: alice), inboxNamesIt: true, me: nil, vaults: vaults))
    }

    func testThePullCachesAnItemOurVaultOpenedWhateverTheInboxNamesAndTheDrainAsksWhatOpenedARow() throws {
        XCTAssertFalse(SyncService.leftToTheInbox(openedByOurVault: true, inboxNamesIt: true))
        XCTAssertTrue(SyncService.leftToTheInbox(openedByOurVault: false, inboxNamesIt: true))
        XCTAssertFalse(SyncService.leftToTheInbox(openedByOurVault: false, inboxNamesIt: false))
        let sync = try source("App/Services/SyncService.swift")
        XCTAssertTrue(sync.contains("guard !Self.leftToTheInbox(openedByOurVault: note != nil, inboxNamesIt: SharesInboxStore.shared.isShared(item.id)) else { return nil }"))
        XCTAssertEqual(sync.components(separatedBy: "SharesInboxStore.shared.isSharedWithUs(record)").count - 1, 2, "the create push and the edit replay")
        XCTAssertFalse(sync.contains("SharesInboxStore.shared.isShared(record.id)"))
        // Our vault keys are the current one and every recovered identity's.
        XCTAssertTrue(try source("App/Services/SharesInboxStore.swift")
            .contains("[KeychainService.shared.getString(for: .vaultKey)].compactMap { $0 } + PreviousIdentityLoader.shared.vaultKeys()"))
    }

    // MARK: - Item owners

    func testAShareOfABoundItemFromAnyoneElseIsRefusedBeforeAnyPinOrVerify() throws {
        try floors.accept(item, owner: alice, generation: 2)
        try pins.pin(ownerId: bob, signingPubHex: signB, sharingPubHex: nil)
        verdict = (true, 9)
        let v = try decide([share(owner: bob, email: "bob@x.y", signature: sig)])
        XCTAssertEqual(v.blocked.map(\.reason), [notConfirmed])
        XCTAssertEqual(pinReads, 0)
        XCTAssertEqual(verifyCalls, 0)
        XCTAssertEqual(try floors.floor(item), 2)
        XCTAssertEqual(try floors.owner(item), alice)
    }

    func testABindingSurvivesARefreshWithoutTheOwnersShare() throws {
        try floors.accept(item, owner: alice)
        _ = try decide([])
        XCTAssertEqual(try floors.owner(item), alice)
        XCTAssertEqual(try decide([share(owner: bob, email: "bob@x.y")]).blocked.map(\.reason), [notConfirmed])
    }

    func testAnUnboundItemNamedByTwoOwnersInOneRefreshIsRefusedBothTimesAndBoundToNobody() throws {
        let v = try decide([share(), share(owner: bob, email: "bob@x.y")])
        XCTAssertEqual(v.blocked.map(\.reason), [notConfirmed, notConfirmed])
        XCTAssertTrue(v.admitted.isEmpty)
        XCTAssertNil(try floors.owner(item))
    }

    func testAVerifiedShareBindsItsItemAndRaisesItsFloorAFirstContactBindsNothingYet() throws {
        let first = try decide([share()])
        XCTAssertEqual(first.admitted.map(\.firstContact), [true])
        XCTAssertNil(try floors.owner(item))

        try pins.pin(ownerId: alice, signingPubHex: signA, sharingPubHex: shareA)
        verdict = (true, 3)
        let second = try decide([share(signature: sig, generation: 3, itemType: 2)])
        XCTAssertEqual(second.admitted.map(\.firstContact), [false])
        XCTAssertEqual(try floors.owner(item), alice)
        XCTAssertEqual(try floors.floor(item), 3)
    }

    func testARefusedShareNeverBinds() throws {
        try pins.pin(ownerId: alice, signingPubHex: signA, sharingPubHex: shareA)
        XCTAssertEqual(try decide([share(signature: nil)]).blocked.map(\.reason), [notConfirmed])
        verdict = (false, 0)
        XCTAssertEqual(try decide([share(signature: sig)]).blocked.map(\.reason), [forged])
        try floors.accept(item, owner: bob) // bound elsewhere later: a rollback check never binds either
        XCTAssertEqual(try floors.owner(item), bob)
    }

    func testAShareBelowItsFloorIsOutOfDateAndMovesNothing() throws {
        try pins.pin(ownerId: alice, signingPubHex: signA, sharingPubHex: shareA)
        try floors.accept(item, owner: alice, generation: 5)
        verdict = (true, 3)
        XCTAssertEqual(try decide([share(signature: sig)]).blocked.map(\.reason), [outOfDate])
        XCTAssertEqual(try floors.floor(item), 5)
    }

    func testAConflictPinVerifiesNothing() throws {
        defaults.set(try JSONEncoder().encode([alice: SenderKeyPinStore.PinRecord(signingPubHex: SenderKeyPinStore.conflictKeyHex, sharingPubHex: SenderKeyPinStore.conflictKeyHex, pinnedAt: 1)]),
                     forKey: "note_sender_pins.\(me)")
        pins = SenderKeyPinStore(defaults: defaults)
        pins.switchUser(me)
        XCTAssertEqual(try decide([share(signature: sig)]).blocked.map(\.reason), [forged])
        XCTAssertEqual(verifyCalls, 0)
    }

    // MARK: - Directory entries

    func testAFirstShareWhoseDirectoryEntryNamesAnotherAccountIsRefused() throws {
        let liar = ["alice@x.y": SharesInboxStore.DirectoryKeys(userId: bob, signingPub: signB, sharingPub: nil)]
        let v = try decide([share()], directory: liar)
        XCTAssertEqual(v.blocked.map(\.reason), [notConfirmed])
        XCTAssertTrue(v.admitted.isEmpty)
    }

    func testAPinnedOwnersShareIsVerifiedAgainstThePinAndRaisesNoAlarmFromAnotherAccountsKeys() throws {
        try pins.pin(ownerId: alice, signingPubHex: signA, sharingPubHex: shareA)
        let liar = ["alice@x.y": SharesInboxStore.DirectoryKeys(userId: bob, signingPub: signB, sharingPub: nil)]
        let v = try decide([share(signature: sig)], directory: liar)
        XCTAssertEqual(v.admitted.count, 1)
        XCTAssertTrue(v.changedKeys.isEmpty)
        XCTAssertNil(v.admitted[0].dirKeys)
    }

    func testAPinnedOwnersChangedDirectoryKeysRaiseTheAlarmWithTheRefusedCount() throws {
        try pins.pin(ownerId: alice, signingPubHex: signB, sharingPubHex: nil)
        verdict = (false, 0)
        let v = try decide([share(signature: sig)])
        XCTAssertEqual(v.changedKeys[alice]?.refused, 1)
        XCTAssertEqual(v.changedKeys[alice]?.keys.signingPub, signA)
    }

    // MARK: - unreadable stores

    func testAPinBlobThatDoesNotDecodeIsUnreadableNeverEmptyAndIsNotWrittenOver() throws {
        defaults.set(Data("{not json".utf8), forKey: "note_sender_pins.\(me)")
        let store = SenderKeyPinStore(defaults: defaults)
        store.switchUser(me)
        XCTAssertThrowsError(try store.ensureReadable()) { XCTAssertEqual($0 as? StoreUnreadable, StoreUnreadable(store: "pins")) }
        XCTAssertThrowsError(try store.getPinned(alice))
        XCTAssertThrowsError(try store.pin(ownerId: alice, signingPubHex: signA, sharingPubHex: shareA))
        XCTAssertEqual(defaults.data(forKey: "note_sender_pins.\(me)"), Data("{not json".utf8))
    }

    func testAnUnboundStoreIsUnreadableNeverTheBaseKey() throws {
        let store = SenderKeyPinStore(defaults: defaults)
        XCTAssertThrowsError(try store.getPinned(alice))
        let floorStore = NoteGenFloorStore(defaults: defaults)
        XCTAssertThrowsError(try floorStore.floor(item))
        XCTAssertThrowsError(try floorStore.owner(item))
        XCTAssertThrowsError(try floorStore.accept(item, owner: alice, generation: 2))
        XCTAssertNil(defaults.object(forKey: "note_gen_floor"))
        XCTAssertNil(defaults.object(forKey: "note_item_owners"))
    }

    func testFloorsOrOwnersThatAreNotAMapAreUnreadableAndNotWrittenOver() throws {
        defaults.set("not a map", forKey: "note_gen_floor.\(me)")
        XCTAssertThrowsError(try floors.ensureReadable())
        XCTAssertThrowsError(try floors.accept(item, owner: alice, generation: 2))
        XCTAssertEqual(defaults.string(forKey: "note_gen_floor.\(me)"), "not a map")
        defaults.removeObject(forKey: "note_gen_floor.\(me)")
        defaults.set(["x": 1], forKey: "note_item_owners.\(me)")
        XCTAssertThrowsError(try floors.owner(item))
        XCTAssertThrowsError(try decide([share()]))
    }

    // MARK: - the stores' canonical keys

    func testAPinIsFoundUnderEverySpellingAndAnIdThatIsNoUUIDIsAnError() throws {
        try pins.pin(ownerId: alice.uppercased(), signingPubHex: signA, sharingPubHex: shareA)
        for spelling in [alice, alice.uppercased(), alice.replacingOccurrences(of: "-", with: ""), "{\(alice)}", "urn:uuid:\(alice)"] {
            XCTAssertEqual(try pins.getPinned(spelling)?.signingPubHex, signA, spelling)
        }
        for bad in ["", "alice", " \(alice)", "URN:UUID:\(alice)"] {
            XCTAssertThrowsError(try pins.getPinned(bad), bad) { XCTAssertEqual($0 as? NotAnId, NotAnId(raw: bad)) }
        }
    }

    func testPinsStoredUnderOtherSpellingsOfASenderFoldAtLoad() throws {
        typealias Pin = SenderKeyPinStore.PinRecord
        defaults.set(try JSONEncoder().encode([alice.uppercased(): Pin(signingPubHex: signA, sharingPubHex: shareA, pinnedAt: 5),
                                               "junk": Pin(signingPubHex: signB, sharingPubHex: nil, pinnedAt: 1)]),
                     forKey: "note_sender_pins.\(me)")
        let store = SenderKeyPinStore(defaults: defaults)
        store.switchUser(me)
        XCTAssertEqual(try store.getPinned(alice)?.signingPubHex, signA)
    }

    func testFloorsAndOwnersAreCanonicalAndABindingIsNeverReplaced() throws {
        try floors.accept(item.uppercased(), owner: alice.uppercased(), generation: 2)
        try floors.accept(item, owner: bob, generation: 4)
        XCTAssertEqual(try floors.owner("{\(item)}"), alice)
        XCTAssertEqual(try floors.floor(item.replacingOccurrences(of: "-", with: "")), 4)
        XCTAssertEqual((defaults.dictionary(forKey: "note_item_owners.\(me)") as? [String: String])?[item], alice)
        defaults.set([item: alice, item.uppercased(): bob], forKey: "note_item_owners.\(me)")
        XCTAssertEqual(try floors.owner(item), NoteGenFloorStore.ownerConflict)
        XCTAssertThrowsError(try floors.owner("item-1"))
    }

    // MARK: - after the shares opened

    func testAFirstContactThatOpenedIsPinnedAndBoundOneThatDidNotIsNeither() throws {
        var v = SharesInboxStore.Verdict()
        let opens = share(owner: alice).withIds(item: item, owner: alice)
        let other = "5a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"
        let doesNot = share(owner: bob, itemId: other).withIds(item: other, owner: bob)
        let pinnedOwner = share(owner: bob, itemId: "6a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d")
            .withIds(item: "6a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d", owner: bob)
        v.admitted = [
            .init(share: opens, firstContact: true, dirKeys: aliceDir),
            .init(share: doesNot, firstContact: true, dirKeys: nil),
            .init(share: pinnedOwner, firstContact: false, dirKeys: nil),
        ]
        var pinnedNow: [String] = []
        var bound: [String: String] = [:]
        _ = SharesInboxStore.afterOpening(
            v, opened: [item, pinnedOwner.itemId], directory: directory, me: me, myEmail: nil,
            pin: { owner, _ in pinnedNow.append(owner) },
            bind: { item, owner in bound[item] = owner }
        )
        XCTAssertEqual(pinnedNow, [alice])
        XCTAssertEqual(bound, [item: alice])
    }

    // MARK: - the refresh's order (its source)

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func refreshBody() throws -> String {
        let text = try source("App/Services/SharesInboxStore.swift")
        let s = try XCTUnwrap(text.range(of: "    func refresh(sharingPrivateKeyBase64: String?, sharingPublicKey: String?) async throws {"))
        let e = try XCTUnwrap(text.range(of: "\n    }\n", range: s.upperBound..<text.endIndex))
        return String(text[s.upperBound..<e.lowerBound])
    }

    /// No own id, or a store that can't be read: nothing is fetched. The
    /// account is checked again after each await, before anything is decided
    /// or published.
    func testTheRefreshStopsBeforeTheFetchAndChecksTheAccountAfterEveryAwait() throws {
        let body = try refreshBody()
        func at(_ needle: String) throws -> String.Index { try XCTUnwrap(body.range(of: needle), needle).lowerBound }
        let ownId = try at("guard let me = CanonicalId.of(KeychainService.shared.getString(for: .userId)) else { return }")
        let pinsRead = try at("try SenderKeyPinStore.shared.ensureReadable()")
        let floorsRead = try at("try NoteGenFloorStore.shared.ensureReadable()")
        let fetch = try at("let inbox = try await APIService.shared.listInbox()")
        let lookup = try at("let directory = await Self.lookupDirectory(")
        let decide = try at("verdict = try Self.decide(inbox, me: me, directory: directory, trust: .live(vaults: vaults))")
        let unwrap = try at("Self.decryptInbox(admitted,")
        let publish = try at("sharedNotes = notes")
        XCTAssertTrue(ownId < pinsRead && pinsRead < floorsRead && floorsRead < fetch && fetch < lookup && lookup < decide && decide < unwrap && unwrap < publish)
        guard floorsRead < fetch else { return XCTFail("the trust stores are read after the fetch") }
        // A store that can't be read stops the refresh with an error line of its
        // own, before the fetch.
        let stop = String(body[floorsRead..<fetch])
        XCTAssertTrue(stop.contains("} catch {\n            Self.log.error(\"INBOX NOT REFRESHED:"), stop)
        XCTAssertTrue(stop.hasSuffix("\n            return\n        }\n        "), stop)
        let checks = body.components(separatedBy: "guard Self.acting(me) else { return }").count - 1
        XCTAssertEqual(checks, 3, "one check after each await: the fetch, the lookup and the unwrap")
        XCTAssertTrue(body[fetch...].contains("guard Self.acting(me) else { return }"))
    }
}
