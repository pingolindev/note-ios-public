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
import Sodium
import PingolinNoteSDK
@testable import Note

/// Finishing a note shared before its reader had an account, in the
/// background: the page's lib/finishSingleInvitations.ts ported (its test
/// cases first, one for one), the contract's trust rows, and whole passes
/// against a stub server with the SDK's real sealing and signing: what is
/// sent, to whom, and what is never sent.
final class FinishInvitationsTests: XCTestCase {

    typealias Row = InvitationFinisher.UnfinishedShare
    typealias Keys = InvitationFinisher.DirectoryKeys

    // MARK: - The page's test cases (finishSingleInvitations.test.ts)

    private let zoe = Keys(userId: "zoe-id", sharingPub: String(repeating: "cc", count: 32),
                           signingPub: String(repeating: "dd", count: 32))
    private var n = 0

    private func row(_ change: (inout Row) -> Void = { _ in }) -> Row {
        n += 1
        var r = Row(shareId: "s\(n)", itemId: "note-\(n)", recipientEmail: "Zoe@Example.test")
        change(&r)
        return r
    }

    private final class Harness {
        var clock: Int64 = 5_000_000
        var finished: [String] = []
        var asked: [[String]] = []
        var steps: InvitationFinisher.Steps!
        func tick(_ ms: Int64) { clock += ms }
    }

    /// `directory`: the directory's answer (nil: no answer). `outcome`: what
    /// sealing each row comes to (done by default).
    private func harness(_ rows: [Row]?, directory: [String: Keys]?? = .none,
                         outcome: ((Row) -> InvitationFinisher.Outcome)? = nil,
                         standing: [String: [String]] = [:], local: [String: String] = [:]) -> Harness {
        let h = Harness()
        let answer: [String: Keys]? = directory ?? ["zoe@example.test": zoe]
        h.steps = InvitationFinisher.Steps(
            unfinished: { rows },
            inStanding: { nb, email in (standing[nb] ?? []).contains(email.lowercased()) },
            localNotebookOf: { local[$0] },
            lookup: { [unowned h] emails in
                h.asked.append(emails)
                return answer
            },
            finish: { [unowned h] r, _ in
                h.finished.append(r.shareId)
                return outcome?(r) ?? .done
            },
            now: { [unowned h] in h.clock })
        return h
    }

    func testFinishesTheClaimedOnesAndOnlyNotesNotCoveredByANotebookInvitation() async {
        let claimed = row()
        let waiting = row { $0.claimed = false }
        let ranOut = row { $0.expired = true }
        let notebook = row { $0.itemType = 2 }
        let inBook = row { $0.notebookId = "nb-1" }
        let inOtherBook = row { $0.notebookId = "nb-2" }
        let h = harness([claimed, waiting, ranOut, notebook, inBook, inOtherBook], standing: ["nb-1": ["zoe@example.test"]])
        let done = await InvitationFinisher.run(h.steps, tried: .init()).finishedIds
        XCTAssertEqual(done, [claimed.shareId, inOtherBook.shareId])
        XCTAssertEqual(h.finished, [claimed.shareId, inOtherBook.shareId])
        XCTAssertEqual(h.asked, [["zoe@example.test"]])
    }

    /// Review of 2026-11-11: rows a notebook removal has not reached yet look
    /// just like a notebook's waiting rows, and must not be finished.
    func testFinishesOnlyAShareMadeOnItsOwnNeverANotebooksRow() async {
        let own = row()
        let notebooks = row { $0.single = false; $0.notebookId = "nb-gone" }
        let unsaid = row { $0.single = nil }
        let h = harness([own, notebooks, unsaid])
        let done = await InvitationFinisher.run(h.steps, tried: .init()).finishedIds
        XCTAssertEqual(done, [own.shareId])
        XCTAssertEqual(h.finished, [own.shareId])
    }

    func testLeavesANoteWhoseNotebookHereHasTheAddressOnItsStandingListWhateverTheServerRowSays() async {
        let inLocalBook = row { $0.notebookId = nil }
        let h = harness([inLocalBook], standing: ["nb-9": ["zoe@example.test"]], local: [inLocalBook.itemId: "nb-9"])
        let done = await InvitationFinisher.run(h.steps, tried: .init()).finishedIds
        XCTAssertEqual(done, [])
    }

    func testConcludesNothingFromNoAnswer() async {
        let tried = InvitationFinisher.Tried()
        let noList = harness(nil)
        let none = await InvitationFinisher.run(noList.steps, tried: tried)
        XCTAssertEqual(none.finishedIds, [])
        XCTAssertEqual(noList.asked, [])

        let noDirectory = harness([row()], directory: .some(nil))
        let nothing = await InvitationFinisher.run(noDirectory.steps, tried: tried)
        XCTAssertEqual(nothing.finishedIds, [])
        XCTAssertEqual(noDirectory.finished, [])
        XCTAssertEqual(tried.at.count, 0)
    }

    func testTriesEachAtMostOncePerRetryIntervalAndForgetsOneThatWent() async {
        let failing = row()
        let going = row()
        let tried = InvitationFinisher.Tried()
        let h = harness([failing, going], outcome: { $0 == failing ? .failed : .done })
        let done = await InvitationFinisher.run(h.steps, tried: tried).finishedIds
        XCTAssertEqual(done, [going.shareId])
        XCTAssertTrue(tried.has(failing.shareId))
        XCTAssertFalse(tried.has(going.shareId))

        h.finished.removeAll()
        h.tick(InvitationFinisher.retryMs - 1)
        _ = await InvitationFinisher.run(h.steps, tried: tried)
        XCTAssertEqual(h.finished, [going.shareId])

        h.finished.removeAll()
        h.tick(1)
        _ = await InvitationFinisher.run(h.steps, tried: tried)
        XCTAssertEqual(h.finished, [failing.shareId, going.shareId])
    }

    func testLeavesAnAddressTheDirectoryHasNoAccountForAndTriesItAgainLater() async {
        let tried = InvitationFinisher.Tried()
        let r = row { $0.recipientEmail = "nobody@example.test" }
        let h = harness([r])
        let report = await InvitationFinisher.run(h.steps, tried: tried)
        XCTAssertEqual(report.finishedIds, [])
        XCTAssertEqual(h.finished, [])
        XCTAssertTrue(tried.has(r.shareId))
        XCTAssertEqual(report.noAccount, 1)
    }

    func testStopsAtAPlanThatNoLongerShares() async {
        let rows = [row(), row(), row()]
        let tried = InvitationFinisher.Tried()
        let h = harness(rows, outcome: { _ in .upgrade })
        _ = await InvitationFinisher.run(h.steps, tried: tried)
        XCTAssertEqual(h.finished, [rows[0].shareId])
        XCTAssertEqual(Set(tried.at.keys), [rows[0].shareId], "the rest were never tried")
    }

    func testSealsABoundedNumberInOnePass() async {
        let rows = (0..<(InvitationFinisher.perPass + 3)).map { _ in row() }
        let quiet = harness(rows)
        quiet.steps.inStanding = { _, _ in false }
        quiet.steps.localNotebookOf = { _ in nil }
        XCTAssertEqual(InvitationFinisher.due(rows, steps: quiet.steps, tried: .init(), now: 0).count,
                       InvitationFinisher.perPass)
        let h = harness(rows)
        let done = await InvitationFinisher.run(h.steps, tried: .init()).finishedIds
        XCTAssertEqual(done.count, InvitationFinisher.perPass)
    }

    // MARK: - What a background pass adds

    /// Out of time, the pass stops where it is: the shares it did not start
    /// are not marked tried, so the next pass takes them at once.
    func testOutOfTimeStopsWithoutMarkingTheRest() async {
        let rows = [row(), row(), row()]
        let tried = InvitationFinisher.Tried()
        let h = harness(rows)
        var starts = 0
        h.steps.mayStart = {
            starts += 1
            return starts <= 1
        }
        let report = await InvitationFinisher.run(h.steps, tried: tried)
        XCTAssertEqual(report.finishedIds, [rows[0].shareId])
        XCTAssertEqual(report.stopped, "out of time")
        XCTAssertTrue(tried.at.isEmpty)
    }

    // MARK: - Trust (the contract's rows)

    private let theirId = "0a1b2c3d-4e5f-4061-8728-394a5b6c7d8e"
    private let s = String(repeating: "ab", count: 32)
    private let g = String(repeating: "cd", count: 32)

    private func pin(_ sharing: String, conflict: Bool = false) -> InvitationFinisher.KeptPin {
        InvitationFinisher.KeptPin(sharingPubkeyHex: sharing, signingPubkeyHex: g, conflict: conflict)
    }

    func testAKeptPinDecidesByItsSharingKeyAndAConflictIsNeverMatched() {
        var asked = 0
        let seals: () -> SealRead = { asked += 1; return .unreadable }
        XCTAssertEqual(InvitationFinisher.trust(userId: theirId, sharing: s.uppercased(), signing: g,
                                                pins: [theirId: pin(s)], seals: seals), .pinned)
        XCTAssertEqual(InvitationFinisher.trust(userId: theirId.uppercased(), sharing: s, signing: g,
                                                pins: [theirId: pin(s)], seals: seals), .pinned,
                       "the id in any spelling")
        if case .refused = InvitationFinisher.trust(userId: theirId, sharing: String(repeating: "ef", count: 32),
                                                    signing: g, pins: [theirId: pin(s)], seals: seals) {} else {
            XCTFail("another sharing key than the pin's is refused")
        }
        if case .refused = InvitationFinisher.trust(userId: theirId, sharing: s, signing: g,
                                                    pins: [theirId: pin(s, conflict: true)], seals: seals) {} else {
            XCTFail("a conflict matches nothing")
        }
        XCTAssertEqual(asked, 0, "with a pin the seals are not read")
    }

    func testWithNoPinAPendingSealDecidesAndOneThatCantBeReadRefuses() {
        let mine = ShellSeal(userId: theirId, sharingPublicKey: s, signingPublicKey: g, sealedAt: 1)
        XCTAssertEqual(InvitationFinisher.trust(userId: theirId, sharing: s.uppercased(), signing: g, pins: [:],
                                                seals: { .seals([mine]) }), .sealed)
        if case .refused = InvitationFinisher.trust(userId: theirId, sharing: String(repeating: "ef", count: 32),
                                                    signing: g, pins: [:], seals: { .seals([mine]) }) {} else {
            XCTFail("a sealed person with another key is refused")
        }
        if case .refused = InvitationFinisher.trust(userId: theirId, sharing: s, signing: g, pins: [:],
                                                    seals: { .unreadable }) {} else {
            XCTFail("seals that can't be read decide nothing")
        }
        let someoneElse = ShellSeal(userId: "11111111-1111-4111-8111-111111111111", sharingPublicKey: g,
                                    signingPublicKey: g, sealedAt: 1)
        XCTAssertEqual(InvitationFinisher.trust(userId: theirId, sharing: s, signing: g, pins: [:],
                                                seals: { .seals([someoneElse]) }), .firstContact)
    }

    func testAFirstContactNeedsBothKeysAsSixtyFourHexAndAnAccountId() {
        XCTAssertEqual(InvitationFinisher.trust(userId: theirId, sharing: s, signing: g, pins: [:], seals: { .none }),
                       .firstContact)
        for (sharing, signing) in [(s, "dd"), (String(s.dropLast()), g), (s, String(repeating: "zz", count: 32)), ("", g)] {
            if case .refused = InvitationFinisher.trust(userId: theirId, sharing: sharing, signing: signing,
                                                        pins: [:], seals: { .none }) {} else {
                XCTFail("\(sharing.count) / \(signing)")
            }
        }
        for id in ["zoe-id", "", "{\(theirId)}"] {
            if case .refused = InvitationFinisher.trust(userId: id, sharing: s, signing: g, pins: [:],
                                                        seals: { .none }) {} else {
                XCTFail("\(id) is not an account id: never a first contact")
            }
        }
    }

    func testThePagesPinsBlobIsReadAsThePageReadsIt() throws {
        let blob = """
        {"\(theirId)":{"sharingPubkeyHex":"\(s.uppercased())","signingPubkeyHex":"\(g)","firstPinnedAt":1,"lastVerifiedAt":2},
         "11111111-1111-4111-8111-111111111111":{"sharingPubkeyHex":"\(InvitationFinisher.conflictKeyHex)",
            "signingPubkeyHex":"\(InvitationFinisher.conflictKeyHex)","firstPinnedAt":1,"lastVerifiedAt":1,"conflict":true}}
        """
        let pins = try XCTUnwrap(InvitationFinisher.parsePins(blob))
        XCTAssertEqual(pins[theirId], pin(s))
        XCTAssertEqual(pins["11111111-1111-4111-8111-111111111111"]?.conflict, true)
        XCTAssertEqual(InvitationFinisher.parsePins("{}"), [:])
    }

    func testABlobThatIsNotThePagesReadsAsNothing() {
        for blob in ["", "[]", "null", "7", "{\"not-an-id\":{\"sharingPubkeyHex\":\"a\",\"signingPubkeyHex\":\"b\"}}",
                     "{\"\(theirId)\":{\"signingPubkeyHex\":\"b\"}}", "{\"\(theirId)\":\"pin\"}"] {
            XCTAssertNil(InvitationFinisher.parsePins(blob), blob)
        }
    }

    func testSpellingsOfOneContactFoldAsThePageFoldsThem() throws {
        let bare = theirId.replacingOccurrences(of: "-", with: "")
        let same = "{\"\(theirId)\":{\"sharingPubkeyHex\":\"\(s)\",\"signingPubkeyHex\":\"\(g)\"},"
            + "\"\(bare.uppercased())\":{\"sharingPubkeyHex\":\"\(s)\",\"signingPubkeyHex\":\"\(g)\"}}"
        XCTAssertEqual(try XCTUnwrap(InvitationFinisher.parsePins(same))[theirId], pin(s))
        let other = "{\"\(theirId)\":{\"sharingPubkeyHex\":\"\(s)\",\"signingPubkeyHex\":\"\(g)\"},"
            + "\"\(bare)\":{\"sharingPubkeyHex\":\"\(g)\",\"signingPubkeyHex\":\"\(g)\"}}"
        XCTAssertEqual(try XCTUnwrap(InvitationFinisher.parsePins(other))[theirId]?.conflict, true)
        // Anything in `conflict` but false or null stops a seal.
        for (value, conflict) in [("true", true), ("false", false), ("null", false), ("1", true), ("\"yes\"", true)] {
            let blob = "{\"\(theirId)\":{\"sharingPubkeyHex\":\"\(s)\",\"signingPubkeyHex\":\"\(g)\",\"conflict\":\(value)}}"
            XCTAssertEqual(try XCTUnwrap(InvitationFinisher.parsePins(blob))[theirId]?.conflict, conflict, value)
        }
    }

    // MARK: - Whole passes, against a stub server

    private let me = "5f2b8e2a-3c1d-4e5f-9a6b-7c8d9e0f1a2b"
    private let base = "https://api-note.test"
    private let sodium = Sodium()
    private var dir: URL!
    private var files: FinisherFiles!
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("finish-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        files = FinisherFiles(directory: dir.appendingPathComponent("stores"))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    /// The owner: a vault key, a signing seed and a sharing key pair.
    private struct Owner {
        let vault = Data(Sodium().randomBytes.buf(length: 32)!)
        let seed = Data(Sodium().randomBytes.buf(length: 32)!)
        let sharingPubHex = deriveSharingPublicKey(privateKey: Data(Sodium().randomBytes.buf(length: 32)!))!
        var signingPubHex: String {
            Sodium().sign.keyPair(seed: Array(seed))!.publicKey.map { String(format: "%02x", $0) }.joined()
        }
    }

    /// Somebody invited: their account and keys as the directory publishes them.
    private struct Invitee {
        let email: String
        let userId = UUID().uuidString.lowercased()
        let priv = Data(Sodium().randomBytes.buf(length: 32)!)
        let signingHex = Sodium().sign.keyPair()!.publicKey.map { String(format: "%02x", $0) }.joined()
        var sharingHex: String { deriveSharingPublicKey(privateKey: priv)! }
        var keys: Keys { Keys(userId: userId, sharingPub: sharingHex, signingPub: signingHex) }
    }

    /// A note of the owner's: its content key, wrapped under `vault`.
    private struct OwnedNote {
        let id: String
        let contentKey: Data
        let wrap: WrappedKey
        var generation: Int64?
        init(vault: Data, generation: Int64? = 3) {
            id = UUID().uuidString.lowercased()
            let key = generateContentKey()
            contentKey = key
            wrap = try! wrapWithVault(contentKey: key, vaultKey: vault)
            self.generation = generation
        }
    }

    /// The stub server: the owner's unfinished shares, the notes, the
    /// directory, and whatever finishes arrive.
    private final class Server: FinisherTransport, @unchecked Sendable {
        var owner = ""
        var rows: [[String: Any]]? = []
        var notes: [String: OwnedNote] = [:]
        var directory: [String: Invitee] = [:]
        var lookupFails = false
        /// The answer to a finish (status, error_code), by item id; 200 by default.
        var finishAnswer: (String, [String: Any]) -> (Int, String?) = { _, _ in (200, nil) }
        private let lock = NSLock()
        private var seen: [URLRequest] = []

        var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return seen }
        var finishes: [(item: String, body: [String: Any])] {
            requests.filter { $0.httpMethod == "POST" && $0.url!.path.hasSuffix("/share") }.map { r in
                (String(r.url!.path.split(separator: "/")[3]),
                 (try? JSONSerialization.jsonObject(with: r.httpBody ?? Data())) as? [String: Any] ?? [:])
            }
        }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            lock.lock(); seen.append(request); lock.unlock()
            let path = request.url!.path
            let (status, body) = answer(request.httpMethod ?? "GET", path, request.httpBody)
            let data = try JSONSerialization.data(withJSONObject: body)
            return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }

        private func answer(_ method: String, _ path: String, _ body: Data?) -> (Int, Any) {
            let parts = path.split(separator: "/").map(String.init)
            switch (method, path) {
            case ("GET", "/api/v1/shares/unfinished"):
                guard let rows else { return (500, ["success": false, "error": "down"]) }
                return (200, ["success": true, "data": rows])
            case ("POST", "/api/v1/users/public-keys"):
                if lookupFails { return (502, ["success": false, "error": "auth unreachable"]) }
                let emails = ((try? JSONSerialization.jsonObject(with: body ?? Data())) as? [String: Any])?["emails"] as? [String] ?? []
                let users: [[String: Any]] = emails.map { email in
                    guard let who = directory[email] else {
                        return ["email": email, "user_id": NSNull(), "sharing_public_key": NSNull(), "signing_public_key": NSNull()]
                    }
                    return ["email": email, "user_id": who.userId, "sharing_public_key": who.sharingHex,
                            "signing_public_key": who.signingHex]
                }
                return (200, ["success": true, "data": ["users": users]])
            case ("GET", _) where parts.count == 4 && parts[2] == "items":
                guard let note = notes[parts[3]] else { return (404, ["success": false, "error": "not found"]) }
                var item: [String: Any] = [
                    "id": note.id, "user_id": owner, "item_type": 1, "deleted": false,
                    "wrapped_content_key": note.wrap.wrappedKeyB64, "wrapped_content_key_nonce": note.wrap.nonceB64,
                ]
                item["content_key_generation"] = note.generation.map { NSNumber(value: $0) } ?? NSNull()
                return (200, ["success": true, "data": item])
            case ("POST", _) where parts.count == 5 && parts[4] == "share":
                let json = (try? JSONSerialization.jsonObject(with: body ?? Data())) as? [String: Any] ?? [:]
                let (status, code) = finishAnswer(parts[3], json)
                if (200..<300).contains(status) { return (status, ["success": true, "data": ["share_id": UUID().uuidString]]) }
                var refusal: [String: Any] = ["success": false, "error": "refused"]
                if let code { refusal["error_code"] = code }
                return (status, refusal)
            default:
                return (404, ["success": false, "error": "no route"])
            }
        }
    }

    private func shareRow(_ note: OwnedNote, to email: String, permission: String = "view",
                          change: (inout [String: Any]) -> Void = { _ in }) -> [String: Any] {
        var r: [String: Any] = [
            "share_id": UUID().uuidString.lowercased(), "item_id": note.id, "item_type": 1, "notebook_id": NSNull(),
            "recipient_email": email, "permission": permission, "single": true, "claimed": true,
            "invite_expires_at": NSNull(), "expired": false, "created_at": "2026-11-12T00:00:00Z",
        ]
        change(&r)
        return r
    }

    private func sealStore() -> SealStore {
        SealStore(files: files, lock: AppGroupLock(url: dir.appendingPathComponent("seals.lock")))
    }

    private func keepPins(_ blob: String?) {
        XCTAssertTrue(KeptPinsMirror.write(blob, for: me, in: files))
    }

    private func pinsBlob(_ pins: [String: (sharing: String, signing: String, conflict: Bool)]) -> String {
        var object: [String: Any] = [:]
        for (id, p) in pins {
            var record: [String: Any] = ["sharingPubkeyHex": p.sharing, "signingPubkeyHex": p.signing,
                                         "firstPinnedAt": 1_700_000_000, "lastVerifiedAt": 1_700_000_000]
            if p.conflict { record["conflict"] = true }
            object[id] = record
        }
        return String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    private func pass(_ server: Server, owner: Owner, seed: Data?? = .none, previous: (() async -> [Data])? = nil,
                      local: [String: String] = [:], deadline: TimeInterval = 20,
                      stillSignedIn: @escaping () -> Bool = { true }) async -> InvitationFinisher.Report {
        server.owner = me
        let material = InvitationFinisher.Material(
            me: me, sharerPublicKeyHex: owner.sharingPubHex, signingSeed: seed ?? owner.seed, vaultKey: owner.vault,
            previousVaultKeys: previous ?? { [] })
        let now = clock
        return await InvitationFinisher.pass(
            InvitationFinisher.Session(account: me, apiBase: base, token: "the-token", material: material,
                                       stillSignedIn: stillSignedIn),
            stores: InvitationFinisher.Stores(keptPins: { KeptPinsMirror.read($0, in: self.files) },
                                              seals: sealStore(), tried: TriedStore(files: files)),
            localNotebookOf: { local[$0] }, transport: server,
            deadline: now.addingTimeInterval(deadline), now: { now })
    }

    /// The request body, field by field: a FINISH that states its generation,
    /// the address exactly as listed, the owner's key as 64 hex, a wrap that
    /// opens for the reader only and a signature that verifies as the page's
    /// under that generation. One fresh read of the item gave the wrap and the
    /// generation. Every request carries the owner's token.
    func testAFinishIsSealedSignedAndSentAsThePageSendsIt() async throws {
        let owner = Owner()
        let zoe = Invitee(email: "zoe@example.test")
        let note = OwnedNote(vault: owner.vault, generation: 3)
        let server = Server()
        server.notes = [note.id: note]
        server.directory = [zoe.email: zoe]
        server.rows = [shareRow(note, to: "Zoe@Example.test", permission: "edit")]
        keepPins("{}")

        let report = await pass(server, owner: owner)
        XCTAssertEqual(report.finished.map(\.itemId), [note.id])
        XCTAssertEqual(report.outcomes, [.done: 1])
        XCTAssertEqual(server.requests.map { "\($0.httpMethod!) \($0.url!.path)" }, [
            "GET /api/v1/shares/unfinished",
            "POST /api/v1/users/public-keys",
            "GET /api/v1/items/\(note.id)",
            "POST /api/v1/items/\(note.id)/share",
        ])
        for request in server.requests {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer the-token")
            XCTAssertLessThanOrEqual(request.timeoutInterval, 8)
        }
        let lookup = try XCTUnwrap(JSONSerialization.jsonObject(with: server.requests[1].httpBody!) as? [String: Any])
        XCTAssertEqual(lookup["emails"] as? [String], ["zoe@example.test"], "lower-cased")

        let body = try XCTUnwrap(server.finishes.first?.body)
        XCTAssertEqual(Set(body.keys), ["email", "permission", "wrapped_key", "wrap_signature", "sharer_public_key",
                                        "finish", "content_key_generation"])
        XCTAssertEqual(body["email"] as? String, "Zoe@Example.test", "exactly as listed")
        XCTAssertEqual(body["permission"] as? String, "edit")
        let finish = try XCTUnwrap(body["finish"] as? NSNumber)
        XCTAssertTrue(CFGetTypeID(finish) == CFBooleanGetTypeID() && finish.boolValue, "finish: true, a JSON boolean")
        XCTAssertEqual((body["content_key_generation"] as? NSNumber)?.int64Value, 3)
        XCTAssertEqual(body["sharer_public_key"] as? String, owner.sharingPubHex)
        XCTAssertTrue(InvitationFinisher.isHex(owner.sharingPubHex, length: 64))
        XCTAssertEqual(owner.sharingPubHex, owner.sharingPubHex.lowercased())

        let wrapped = try XCTUnwrap(body["wrapped_key"] as? String)
        XCTAssertEqual(openSeal(wrappedB64: wrapped, privateKey: zoe.priv), note.contentKey, "opens for the reader")
        XCTAssertNil(openSeal(wrappedB64: wrapped, privateKey: Data(sodium.randomBytes.buf(length: 32)!)))
        let signature = try XCTUnwrap(body["wrap_signature"] as? String)
        XCTAssertTrue(InvitationFinisher.isHex(signature, length: 128))
        XCTAssertEqual(signature, signature.lowercased())
        let verdict = try verifyNoteShareWrapGen(
            signingPubkeyHex: owner.signingPubHex, signatureHex: signature,
            params: NoteShareWrapParams(senderUserId: me, recipientUserId: zoe.userId, itemId: note.id,
                                        contentKeyVersion: 3, wrappedKeyB64: wrapped))
        XCTAssertTrue(verdict.verified)
        XCTAssertEqual(verdict.effectiveGeneration, 3, "signed under the item's generation, not legacy 0")
    }

    /// A row's permission goes as the page sends it; an item with no
    /// generation is at the base generation, 1, and is signed under it.
    func testANoteWithNoGenerationIsSignedUnderOneAndAViewStaysView() async throws {
        let owner = Owner()
        let zoe = Invitee(email: "zoe@example.test")
        let note = OwnedNote(vault: owner.vault, generation: nil)
        let server = Server()
        server.notes = [note.id: note]
        server.directory = [zoe.email: zoe]
        server.rows = [shareRow(note, to: zoe.email, permission: "view")]
        keepPins("{}")
        _ = await pass(server, owner: owner)
        let body = try XCTUnwrap(server.finishes.first?.body)
        XCTAssertEqual((body["content_key_generation"] as? NSNumber)?.int64Value, 1)
        XCTAssertEqual(body["permission"] as? String, "view")
        let verdict = try verifyNoteShareWrapGen(
            signingPubkeyHex: owner.signingPubHex, signatureHex: body["wrap_signature"] as! String,
            params: NoteShareWrapParams(senderUserId: me, recipientUserId: zoe.userId, itemId: note.id,
                                        contentKeyVersion: 1, wrappedKeyB64: body["wrapped_key"] as! String))
        XCTAssertEqual(verdict.effectiveGeneration, 1)
    }

    // Trust row 1: no kept pins, or pins that can't be read, finish nothing.

    func testWithNoKeptPinsNothingIsFinishedAndNothingIsAsked() async {
        let owner = Owner()
        let note = OwnedNote(vault: owner.vault)
        let server = Server()
        server.notes = [note.id: note]
        server.directory = ["zoe@example.test": Invitee(email: "zoe@example.test")]
        server.rows = [shareRow(note, to: "zoe@example.test")]
        let absent = await pass(server, owner: owner)
        XCTAssertEqual(absent.finished, [])
        XCTAssertNotNil(absent.stopped)
        XCTAssertTrue(server.requests.isEmpty, "not even the list")

        for garbage in ["{\"v\":1}", "{\"v\":2,\"pins\":null}", "not json", "{\"v\":1,\"pins\":7}"] {
            XCTAssertTrue(files.write(.keptPins, me, Data(garbage.utf8)))
            let unreadable = await pass(server, owner: owner)
            XCTAssertEqual(unreadable.finished, [], garbage)
        }
        keepPins("{\"not-an-id\":{}}")
        let unparseable = await pass(server, owner: owner)
        XCTAssertEqual(unparseable.finished, [])
        // A keep with no pins blob at all: only an older page sends one (a
        // current one sends "{}" for an account that pinned nobody). No record.
        keepPins(nil)
        let older = await pass(server, owner: owner)
        XCTAssertEqual(older.finished, [])
        XCTAssertEqual(older.stopped, "the page kept no record of its pins")
        XCTAssertTrue(server.requests.isEmpty)
        XCTAssertEqual(sealStore().read(me), .none)
    }

    // A sign-out or another account's sign-in during a pass: nothing more is
    // recorded or sent, and nothing is saved.

    func testAnAccountThatSignsOutDuringAPassStopsItAndNothingIsSaved() async {
        let owner = Owner()
        let zoe = Invitee(email: "zoe@example.test")
        let ann = Invitee(email: "ann@example.test")
        let first = OwnedNote(vault: owner.vault)
        let second = OwnedNote(vault: owner.vault)
        let third = OwnedNote(vault: owner.vault)
        let server = Server()
        server.notes = [first.id: first, second.id: second, third.id: third]
        server.directory = [zoe.email: zoe, ann.email: ann]
        server.rows = [shareRow(first, to: zoe.email), shareRow(second, to: zoe.email), shareRow(third, to: ann.email)]
        keepPins("{}")
        var signedIn = true
        // The first finish fails (so it would be kept as tried), and the account
        // signs out while it is out.
        server.finishAnswer = { _, _ in
            signedIn = false
            return (503, nil)
        }
        let report = await pass(server, owner: owner, stillSignedIn: { signedIn })
        XCTAssertTrue(report.accountChanged)
        XCTAssertEqual(report.stopped, InvitationFinisher.Report.accountChangedReason)
        XCTAssertEqual(server.finishes.count, 1, "nothing sent after the sign-out")
        XCTAssertEqual(report.outcomes, [.failed: 1])
        XCTAssertTrue(TriedStore(files: files).load(me).isEmpty, "the tried-at is not saved")
        XCTAssertEqual(sealStore().read(me), .seals([ShellSeal(
            userId: zoe.userId, sharingPublicKey: zoe.sharingHex, signingPublicKey: zoe.signingHex,
            sealedAt: Int64(clock.timeIntervalSince1970 * 1000))]), "Ann's first contact is never recorded")
    }

    func testNoSealIsRecordedAndNothingSentForAnAccountNoLongerSignedIn() async {
        let owner = Owner()
        let zoe = Invitee(email: "zoe@example.test")
        let note = OwnedNote(vault: owner.vault)
        let server = Server()
        server.notes = [note.id: note]
        server.directory = [zoe.email: zoe]
        server.rows = [shareRow(note, to: zoe.email)]
        keepPins("{}")
        // Still signed in when the pass starts the share; not by the time its
        // first contact would be recorded.
        var asks = 0
        let report = await pass(server, owner: owner, stillSignedIn: {
            asks += 1
            return asks <= 1
        })
        XCTAssertEqual(report.outcomes, [.accountChanged: 1])
        XCTAssertTrue(report.accountChanged)
        XCTAssertTrue(server.finishes.isEmpty)
        XCTAssertEqual(sealStore().read(me), .none)
        XCTAssertTrue(TriedStore(files: files).load(me).isEmpty)
    }

    func testAPinnedShareIsNotSentForAnAccountThatSignedOutWhileItWasSealed() async {
        let owner = Owner()
        let zoe = Invitee(email: "zoe@example.test")
        let note = OwnedNote(vault: owner.vault)
        let server = Server()
        server.notes = [note.id: note]
        server.directory = [zoe.email: zoe]
        server.rows = [shareRow(note, to: zoe.email)]
        keepPins(pinsBlob([zoe.userId: (zoe.sharingHex, zoe.signingHex, false)]))
        var asks = 0
        let report = await pass(server, owner: owner, stillSignedIn: {
            asks += 1
            return asks <= 1
        })
        XCTAssertEqual(report.outcomes, [.accountChanged: 1])
        XCTAssertTrue(server.finishes.isEmpty, "checked again just before the finish goes")
    }

    // Trust row 2: a kept pin decides; a conflict or another key is not sealed to.

    func testAKeptPinWithTheSameKeyFinishesAndOneWithAnotherKeyOrAConflictDoesNot() async throws {
        let owner = Owner()
        let zoe = Invitee(email: "zoe@example.test")
        let note = OwnedNote(vault: owner.vault)
        let server = Server()
        server.notes = [note.id: note]
        server.directory = [zoe.email: zoe]
        server.rows = [shareRow(note, to: zoe.email)]

        let other = String(repeating: "ef", count: 32)
        for (pinned, conflict) in [(other, false), (zoe.sharingHex, true)] {
            keepPins(pinsBlob([zoe.userId: (pinned, zoe.signingHex, conflict)]))
            let mirrored = try XCTUnwrap(files.read(.keptPins, me) == .absent ? nil : files.read(.keptPins, me))
            try? FileManager.default.removeItem(at: files.url(.tried, me)!)
            let report = await pass(server, owner: owner)
            XCTAssertEqual(report.finished, [], "conflict \(conflict)")
            XCTAssertEqual(report.outcomes, [.keyChanged: 1])
            XCTAssertTrue(server.finishes.isEmpty, "nothing sent")
            XCTAssertEqual(files.read(.keptPins, me), mirrored, "the kept pins are never written")
        }
        XCTAssertEqual(sealStore().read(me), .none, "and no seal is made")

        // The same key, in another case: sealed to, and no seal recorded (it is pinned).
        keepPins(pinsBlob([zoe.userId.uppercased(): (zoe.sharingHex.uppercased(), zoe.signingHex, false)]))
        try? FileManager.default.removeItem(at: files.url(.tried, me)!)
        let report = await pass(server, owner: owner)
        XCTAssertEqual(report.finished.count, 1)
        XCTAssertEqual(server.finishes.count, 1)
        XCTAssertEqual(sealStore().read(me), .none)
    }

    // Trust row 3: no pin, but a pending seal.

    func testAPendingSealWithTheSameKeyFinishesWithoutASecondSealAndAnotherKeyDoesNot() async {
        let owner = Owner()
        let zoe = Invitee(email: "zoe@example.test")
        let note = OwnedNote(vault: owner.vault)
        let server = Server()
        server.notes = [note.id: note]
        server.directory = [zoe.email: zoe]
        server.rows = [shareRow(note, to: zoe.email)]
        keepPins("{}")

        let earlier = ShellSeal(userId: zoe.userId, sharingPublicKey: String(repeating: "ef", count: 32),
                                signingPublicKey: zoe.signingHex, sealedAt: 1)
        let recorded = await sealStore().record(earlier, for: me)
        XCTAssertEqual(recorded, .recorded)
        let refused = await pass(server, owner: owner)
        XCTAssertEqual(refused.outcomes, [.keyChanged: 1])
        XCTAssertTrue(server.finishes.isEmpty)

        let cleared = await sealStore().clear(me, upTo: 1, pins: [zoe.userId: InvitationFinisher.KeptPin(
            sharingPubkeyHex: String(repeating: "ef", count: 32), signingPubkeyHex: zoe.signingHex, conflict: false)])
        XCTAssertTrue(cleared)
        let same = ShellSeal(userId: zoe.userId, sharingPublicKey: zoe.sharingHex, signingPublicKey: zoe.signingHex,
                             sealedAt: 2)
        let again = await sealStore().record(same, for: me)
        XCTAssertEqual(again, .recorded)
        try? FileManager.default.removeItem(at: files.url(.tried, me)!)
        let finished = await pass(server, owner: owner)
        XCTAssertEqual(finished.outcomes, [.done: 1])
        XCTAssertEqual(sealStore().read(me), .seals([same]), "no second seal")
    }

    // Trust row 4: a first contact is recorded FIRST, then sealed and sent.

    func testAFirstContactIsRecordedAsASealBeforeAnythingIsSent() async throws {
        let owner = Owner()
        let zoe = Invitee(email: "zoe@example.test")
        let note = OwnedNote(vault: owner.vault)
        let server = Server()
        server.notes = [note.id: note]
        server.directory = [zoe.email: zoe]
        server.rows = [shareRow(note, to: zoe.email)]
        // Someone else is pinned; Zoe is not.
        keepPins(pinsBlob(["11111111-1111-4111-8111-111111111111": (String(repeating: "ab", count: 32),
                                                                      String(repeating: "ab", count: 32), false)]))
        let store = sealStore()
        var sealsWhenSent: SealRead?
        server.finishAnswer = { _, _ in
            sealsWhenSent = store.read(self.me)
            return (200, nil)
        }
        let report = await pass(server, owner: owner)
        XCTAssertEqual(report.outcomes, [.done: 1])
        let expected = ShellSeal(userId: zoe.userId, sharingPublicKey: zoe.sharingHex, signingPublicKey: zoe.signingHex,
                                 sealedAt: Int64(clock.timeIntervalSince1970 * 1000))
        XCTAssertEqual(sealsWhenSent, .seals([expected]), "the seal was there when the finish went")
        XCTAssertEqual(store.read(me), .seals([expected]))
    }

    func testAFirstContactWhoseKeysAreNotKeysIsNeitherSealedToNorRecorded() async {
        let owner = Owner()
        let note = OwnedNote(vault: owner.vault)
        let server = Server()
        server.notes = [note.id: note]
        server.rows = [shareRow(note, to: "zoe@example.test")]
        keepPins("{}")
        final class Odd: FinisherTransport {
            let inner: FinisherTransport
            init(_ inner: FinisherTransport) { self.inner = inner }
            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                guard request.url!.path == "/api/v1/users/public-keys" else { return try await inner.send(request) }
                let body: [String: Any] = ["success": true, "data": ["users": [[
                    "email": "zoe@example.test", "user_id": "0a1b2c3d-4e5f-4061-8728-394a5b6c7d8e",
                    "sharing_public_key": String(repeating: "ab", count: 32), "signing_public_key": "dd"]]]]
                return (try JSONSerialization.data(withJSONObject: body),
                        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }
        server.owner = me
        let material = InvitationFinisher.Material(me: me, sharerPublicKeyHex: owner.sharingPubHex,
                                                   signingSeed: owner.seed, vaultKey: owner.vault)
        let now = clock
        let report = await InvitationFinisher.pass(
            InvitationFinisher.Session(account: me, apiBase: base, token: "t", material: material),
            stores: InvitationFinisher.Stores(keptPins: { KeptPinsMirror.read($0, in: self.files) },
                                              seals: sealStore(), tried: TriedStore(files: files)),
            localNotebookOf: { _ in nil }, transport: Odd(server),
            deadline: now.addingTimeInterval(20), now: { now })
        XCTAssertEqual(report.outcomes, [.keyChanged: 1])
        XCTAssertTrue(server.finishes.isEmpty)
        XCTAssertEqual(sealStore().read(me), .none)
    }

    // MARK: - Stops, outcomes and what is kept between passes

    func testA402StopsTheWholePass() async {
        let owner = Owner()
        let zoe = Invitee(email: "zoe@example.test")
        let notes = (0..<3).map { _ in OwnedNote(vault: owner.vault) }
        let server = Server()
        server.notes = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) })
        server.directory = [zoe.email: zoe]
        server.rows = notes.map { shareRow($0, to: zoe.email) }
        server.finishAnswer = { _, _ in (402, "premium_required_sharing") }
        keepPins("{}")
        let report = await pass(server, owner: owner)
        XCTAssertEqual(server.finishes.count, 1, "nothing after the first refusal")
        XCTAssertEqual(report.outcomes, [.upgrade: 1])
        XCTAssertEqual(report.stopped, "the plan does not include sharing")
        XCTAssertEqual(Array(TriedStore(files: files).load(me).keys), [server.rows![0]["share_id"] as! String])
    }

    func testTheServersTwoConflictsAreToldApartAndTriedAgainLater() async {
        let owner = Owner()
        let zoe = Invitee(email: "zoe@example.test")
        let gone = OwnedNote(vault: owner.vault)
        let stale = OwnedNote(vault: owner.vault)
        let server = Server()
        server.notes = [gone.id: gone, stale.id: stale]
        server.directory = [zoe.email: zoe]
        server.rows = [shareRow(gone, to: zoe.email), shareRow(stale, to: zoe.email)]
        server.finishAnswer = { item, _ in (409, item == gone.id ? "share_not_unfinished" : "share_generation_stale") }
        keepPins("{}")
        let report = await pass(server, owner: owner)
        XCTAssertEqual(report.outcomes, [.gone: 1, .stale: 1])
        XCTAssertEqual(TriedStore(files: files).load(me).count, 2)
        XCTAssertEqual(InvitationFinisher.outcome(status: 409, errorCode: "other"), .failed)
        XCTAssertEqual(InvitationFinisher.outcome(status: 429, errorCode: nil), .failed)
        XCTAssertEqual(InvitationFinisher.outcome(status: 503, errorCode: nil), .failed)
        XCTAssertEqual(InvitationFinisher.outcome(status: nil, errorCode: nil), .failed)
        XCTAssertEqual(InvitationFinisher.outcome(status: 201, errorCode: nil), .done)
    }

    /// The tried-at is kept between passes: a share that did not go is left
    /// for ten minutes, by a later pass too (an extension has no memory).
    func testTheTriedAtIsKeptBetweenPassesAndAShareThatWentIsForgotten() async {
        let owner = Owner()
        let zoe = Invitee(email: "zoe@example.test")
        let failing = OwnedNote(vault: owner.vault)
        let going = OwnedNote(vault: owner.vault)
        let server = Server()
        server.notes = [failing.id: failing, going.id: going]
        server.directory = [zoe.email: zoe]
        let failingRow = shareRow(failing, to: zoe.email)
        server.rows = [failingRow, shareRow(going, to: zoe.email)]
        server.finishAnswer = { item, _ in item == failing.id ? (503, nil) : (200, nil) }
        keepPins("{}")
        let first = await pass(server, owner: owner)
        XCTAssertEqual(first.outcomes, [.done: 1, .failed: 1])
        XCTAssertEqual(Array(TriedStore(files: files).load(me).keys), [failingRow["share_id"] as! String])

        server.rows = [failingRow]
        clock = clock.addingTimeInterval(5 * 60)
        let soon = await pass(server, owner: owner)
        XCTAssertEqual(soon.outcomes, [:])
        XCTAssertEqual(server.finishes.count, 2, "not tried again within ten minutes")

        clock = clock.addingTimeInterval(5 * 60)
        server.finishAnswer = { _, _ in (200, nil) }
        let later = await pass(server, owner: owner)
        XCTAssertEqual(later.outcomes, [.done: 1])
        XCTAssertTrue(TriedStore(files: files).load(me).isEmpty, "a share that went is forgotten")
    }

    /// A wrap that cannot be signed is never sent: without a seed nothing is
    /// read or sealed.
    func testWithoutASigningKeyNothingIsSent() async {
        let owner = Owner()
        let zoe = Invitee(email: "zoe@example.test")
        let note = OwnedNote(vault: owner.vault)
        let server = Server()
        server.notes = [note.id: note]
        server.directory = [zoe.email: zoe]
        server.rows = [shareRow(note, to: zoe.email)]
        keepPins("{}")
        let report = await pass(server, owner: owner, seed: .some(nil))
        XCTAssertEqual(report.outcomes, [.cannotSign: 1])
        XCTAssertTrue(server.finishes.isEmpty)
        XCTAssertFalse(server.requests.contains { $0.url!.path.hasPrefix("/api/v1/items/") })
    }

    /// The note's key opens with the current vault key, or one of an identity
    /// recovered from before a password reset: asked for only then.
    func testANoteFromBeforeAPasswordResetOpensWithAnEarlierVaultKey() async {
        let owner = Owner()
        let oldVault = generateContentKey()
        let zoe = Invitee(email: "zoe@example.test")
        let note = OwnedNote(vault: oldVault)
        let server = Server()
        server.notes = [note.id: note]
        server.directory = [zoe.email: zoe]
        server.rows = [shareRow(note, to: zoe.email)]
        keepPins("{}")
        let without = await pass(server, owner: owner)
        XCTAssertEqual(without.outcomes, [.notHere: 1])

        try? FileManager.default.removeItem(at: files.url(.tried, me)!)
        var asked = 0
        let with = await pass(server, owner: owner, previous: { asked += 1; return [generateContentKey(), oldVault] })
        XCTAssertEqual(with.outcomes, [.done: 1])
        XCTAssertEqual(asked, 1)
        XCTAssertNotNil(openSeal(wrappedB64: server.finishes.last!.body["wrapped_key"] as! String, privateKey: zoe.priv))
    }

    /// Every note in a notebook is left to the page, which reads the standing
    /// lists: by the server's notebook_id, and by this device's copy.
    func testEveryNoteInANotebookIsLeftToThePage() async {
        let owner = Owner()
        let zoe = Invitee(email: "zoe@example.test")
        let inBook = OwnedNote(vault: owner.vault)
        let inLocalBook = OwnedNote(vault: owner.vault)
        let alone = OwnedNote(vault: owner.vault)
        let server = Server()
        server.notes = [inBook.id: inBook, inLocalBook.id: inLocalBook, alone.id: alone]
        server.directory = [zoe.email: zoe]
        server.rows = [shareRow(inBook, to: zoe.email) { $0["notebook_id"] = UUID().uuidString },
                       shareRow(inLocalBook, to: zoe.email), shareRow(alone, to: zoe.email)]
        keepPins("{}")
        let report = await pass(server, owner: owner, local: [inLocalBook.id: UUID().uuidString])
        XCTAssertEqual(report.finished.map(\.itemId), [alone.id])
        XCTAssertEqual(server.finishes.map(\.item), [alone.id])
    }

    /// No answer from the directory is not "no account": nothing is tried.
    func testADirectoryThatDoesNotAnswerConcludesNothing() async {
        let owner = Owner()
        let note = OwnedNote(vault: owner.vault)
        let server = Server()
        server.notes = [note.id: note]
        server.rows = [shareRow(note, to: "zoe@example.test")]
        server.lookupFails = true
        keepPins("{}")
        let report = await pass(server, owner: owner)
        XCTAssertEqual(report.stopped, "the directory did not answer")
        XCTAssertTrue(TriedStore(files: files).load(me).isEmpty)
        server.rows = nil
        let noList = await pass(server, owner: owner)
        XCTAssertNotNil(noList.stopped)
    }

    /// Someone else's note, a deleted one, or one that is not a note: not here.
    func testOnlyTheOwnersOwnNoteIsSealed() async {
        let owner = Owner()
        let zoe = Invitee(email: "zoe@example.test")
        let note = OwnedNote(vault: owner.vault)
        let server = Server()
        server.notes = [note.id: note]
        server.directory = [zoe.email: zoe]
        server.rows = [shareRow(note, to: zoe.email)]
        keepPins("{}")
        server.owner = "11111111-1111-4111-8111-111111111111"
        let material = InvitationFinisher.Material(me: me, sharerPublicKeyHex: owner.sharingPubHex,
                                                   signingSeed: owner.seed, vaultKey: owner.vault)
        let api = FinisherAPI(base: base, token: "t", transport: server, deadline: clock.addingTimeInterval(20),
                              now: { [clock] in clock })
        let outcome = await InvitationFinisher.finish(
            InvitationFinisher.UnfinishedShare(json: server.rows![0])!, keys: zoe.keys, material: material, pins: [:],
            seals: sealStore(), account: me, api: api, now: { 1 })
        XCTAssertEqual(outcome, .notHere)
        XCTAssertTrue(server.finishes.isEmpty)
    }

    /// The server's rows, read strictly: a row that is not one is skipped, the
    /// rest are kept.
    func testTheServersListIsReadRowByRow() async {
        let server = Server()
        server.rows = [
            ["share_id": "a", "item_id": "b", "item_type": 1, "recipient_email": "x@y.z", "permission": "view",
             "claimed": true, "expired": false],
            ["share_id": "c", "item_id": "d", "item_type": 1, "recipient_email": "x@y.z", "permission": "view",
             "claimed": "yes", "expired": false],
            ["share_id": "e", "item_id": "f", "item_type": true, "recipient_email": "x@y.z", "permission": "view",
             "claimed": true, "expired": false],
        ]
        let api = FinisherAPI(base: base, token: "t", transport: server, deadline: Date().addingTimeInterval(20),
                              now: Date.init)
        let rows = await api.unfinished()
        XCTAssertEqual(rows?.map(\.shareId), ["a"])
        XCTAssertNil(rows?.first?.single, "absent: not said, and not finished")
    }
}
