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
import UserNotifications
import Sodium
import PingolinNoteSDK
@testable import Note

/// The shell around the finisher: the stores the app and its notification
/// extension share, the page's two seal ops on the key bridge, the push that
/// starts it, the extension's run (who is signed in, which token, one pass at
/// a time), the session refresh both processes take turns at, and the banner.
final class FinishInvitationsShellTests: XCTestCase {

    private let me = "5f2b8e2a-3c1d-4e5f-9a6b-7c8d9e0f1a2b"
    private let other = "0a1b2c3d-4e5f-4061-8728-394a5b6c7d8e"
    private let zoeId = "6b1c2d3e-4f50-4a61-8b72-9c8d0e1f2a3b"
    private var dir: URL!
    private var files: FinisherFiles!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("finish-shell-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        files = FinisherFiles(directory: dir.appendingPathComponent("stores"))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func store() -> SealStore {
        SealStore(files: files, lock: AppGroupLock(url: dir.appendingPathComponent("seals.lock")))
    }

    private func seal(_ id: String, _ sharing: String = String(repeating: "ab", count: 32), at: Int64) -> ShellSeal {
        ShellSeal(userId: id, sharingPublicKey: sharing, signingPublicKey: String(repeating: "cd", count: 32), sealedAt: at)
    }

    // MARK: - The seal store

    private func pinned(_ sharing: String = String(repeating: "ab", count: 32),
                        conflict: Bool = false) -> InvitationFinisher.KeptPin {
        InvitationFinisher.KeptPin(sharingPubkeyHex: sharing, signingPubkeyHex: String(repeating: "cd", count: 32),
                                   conflict: conflict)
    }

    func testSealsAreRecordedOncePerPersonAndAccountsStayApart() async {
        let s = store()
        XCTAssertEqual(s.read(me), .none)
        let first = await s.record(seal(zoeId, at: 1000), for: me)
        XCTAssertEqual(first, .recorded)
        let again = await s.record(seal(zoeId.uppercased(), String(repeating: "AB", count: 32), at: 2000), for: me)
        XCTAssertEqual(again, .alreadyThere, "the same person and key, in any spelling")
        let otherKey = await s.record(seal(zoeId, String(repeating: "ef", count: 32), at: 3000), for: me)
        XCTAssertEqual(otherKey, .otherKeys)
        XCTAssertEqual(s.read(me), .seals([seal(zoeId, at: 1000)]))
        XCTAssertEqual(s.read(other), .none, "another account has nothing of mine")
        XCTAssertEqual(s.read(me.uppercased()), .seals([seal(zoeId, at: 1000)]), "the account in any spelling")
    }

    func testClearingLetsGoOfWhatThePageFoldedAndKeepsWhatCameLater() async {
        let s = store()
        let both = [zoeId: pinned(), other: pinned()]
        _ = await s.record(seal(zoeId, at: 1000), for: me)
        _ = await s.record(seal(other, at: 2000), for: me)
        let some = await s.clear(me, upTo: 1000, pins: both)
        XCTAssertTrue(some)
        XCTAssertEqual(s.read(me), .seals([seal(other, at: 2000)]))
        let rest = await s.clear(me, upTo: 5000, pins: both)
        XCTAssertTrue(rest)
        XCTAssertEqual(s.read(me), .none)
        XCTAssertNil(files.url(.seals, me).flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil })
        let nothing = await s.clear(me, upTo: 1, pins: both)
        XCTAssertTrue(nothing)
    }

    /// A seal goes only once the copy of the page's pins holds its person (a
    /// pin or a conflict): until then the finisher would find them in neither
    /// store, whatever the time the page names.
    func testClearingLetsGoOnlyOfSealsWhosePersonTheCopyHolds() async {
        let s = store()
        let ann = "11111111-1111-4111-8111-111111111111"
        _ = await s.record(seal(zoeId, at: 1000), for: me)
        _ = await s.record(seal(other, at: 1500), for: me)
        _ = await s.record(seal(ann, at: 1200), for: me)
        let none = await s.clear(me, upTo: 5000, pins: [:])
        XCTAssertTrue(none)
        XCTAssertEqual(s.read(me), .seals([seal(zoeId, at: 1000), seal(other, at: 1500), seal(ann, at: 1200)]),
                       "no copy, or one that holds nobody: nothing goes")
        let some = await s.clear(me, upTo: 5000, pins: [zoeId: pinned(), other: pinned()])
        XCTAssertTrue(some)
        XCTAssertEqual(s.read(me), .seals([seal(ann, at: 1200)]))
    }

    /// A seal for someone the copy pins at ANOTHER key was not folded: the page
    /// could not fold it (its pins were not loaded) and cleared anyway, and the
    /// conflict it should have made is not there. It stays, whatever its time.
    /// At its own key (in any case), or as a conflict, it goes.
    func testASealForSomeonePinnedAtAnotherKeyIsNotLetGo() async {
        let s = store()
        let ann = "11111111-1111-4111-8111-111111111111"
        let ef = String(repeating: "ef", count: 32)
        _ = await s.record(seal(zoeId, at: 1000), for: me)
        _ = await s.record(seal(other, ef, at: 1100), for: me)
        _ = await s.record(seal(ann, at: 1200), for: me)
        let cleared = await s.clear(me, upTo: 5000, pins: [
            zoeId: pinned(String(repeating: "AB", count: 32)),
            other: pinned(),
            ann: pinned(InvitationFinisher.conflictKeyHex, conflict: true),
        ])
        XCTAssertTrue(cleared)
        XCTAssertEqual(s.read(me), .seals([seal(other, ef, at: 1100)]),
                       "only the seal at another key than the pin's stays")
    }

    /// The page's fold makes a conflict when EITHER key differs (`foldPins`):
    /// a pin at the seal's sharing key but another signing key, and no
    /// conflict, was not folded, and the seal stays. Both keys the seal's (in
    /// any case), or a conflict: it goes.
    func testASealWhoseSigningKeyDiffersFromThePinsIsNotLetGo() async {
        let s = store()
        let ann = "11111111-1111-4111-8111-111111111111"
        let k = String(repeating: "ab", count: 32)
        let g1 = String(repeating: "01", count: 32)
        let g2 = String(repeating: "02", count: 32)
        func sealed(_ id: String, at: Int64) -> ShellSeal {
            ShellSeal(userId: id, sharingPublicKey: k, signingPublicKey: g2, sealedAt: at)
        }
        for (id, at) in [(zoeId, Int64(1000)), (other, 1100), (ann, 1200)] {
            let recorded = await s.record(sealed(id, at: at), for: me)
            XCTAssertEqual(recorded, .recorded)
        }
        let cleared = await s.clear(me, upTo: 5000, pins: [
            zoeId: InvitationFinisher.KeptPin(sharingPubkeyHex: k, signingPubkeyHex: g1, conflict: false),
            other: InvitationFinisher.KeptPin(sharingPubkeyHex: k.uppercased(), signingPubkeyHex: g2.uppercased(),
                                              conflict: false),
            ann: pinned(InvitationFinisher.conflictKeyHex, conflict: true),
        ])
        XCTAssertTrue(cleared)
        XCTAssertEqual(s.read(me), .seals([sealed(zoeId, at: 1000)]), "only the seal at another signing key stays")
    }

    func testASealStoreThatCantBeReadIsNeverNone() async {
        let s = store()
        XCTAssertTrue(files.write(.seals, me, Data("{\"user_id\":1}".utf8)))
        XCTAssertEqual(s.read(me), .unreadable)
        let recorded = await s.record(seal(zoeId, at: 1), for: me)
        XCTAssertEqual(recorded, .failed, "nothing is added to what can't be read")
        let cleared = await s.clear(me, upTo: 10, pins: [zoeId: pinned()])
        XCTAssertFalse(cleared)
        XCTAssertTrue(files.write(.seals, me, Data("[{\"user_id\":\"\(zoeId)\",\"sharing_public_key\":\"a\"}]".utf8)))
        XCTAssertEqual(s.read(me), .unreadable, "an entry that is not a seal")
        XCTAssertEqual(s.read("not-an-id"), .unreadable)
    }

    /// While the other process holds the seal lock, nothing is changed here.
    func testASealIsRecordedOnlyHoldingTheLock() async throws {
        let lock = AppGroupLock(url: dir.appendingPathComponent("seals.lock"))
        let acquired = await lock.acquire(timeout: 1)
        let held = try XCTUnwrap(acquired)
        var s = store()
        s.wait = 0.2
        let blocked = await s.record(seal(zoeId, at: 1), for: me)
        XCTAssertEqual(blocked, .failed)
        held.release()
        let recorded = await s.record(seal(zoeId, at: 1), for: me)
        XCTAssertEqual(recorded, .recorded)
    }

    /// The account is asked again once the seal lock is held (waiting for it
    /// can take seconds): signed out and erased meanwhile, which removed its
    /// seals, nothing is written back.
    func testASealIsNotWrittenBackForAnAccountErasedWhileItWaitedForTheLock() async {
        let s = store()
        let ann = "11111111-1111-4111-8111-111111111111"
        let earlier = await s.record(seal(ann, at: 1), for: me)
        XCTAssertEqual(earlier, .recorded)
        // The sign-out and the erasure, while the record waited: the seals are gone.
        files.forget(me)
        let lockPath = dir.appendingPathComponent("seals.lock").path
        var askedHoldingTheLock: [Bool] = []
        let result = await s.record(seal(zoeId, at: 2), for: me, stillSignedIn: {
            askedHoldingTheLock.append(!Self.lockIsFree(lockPath))
            return false
        })
        XCTAssertEqual(result, .accountChanged)
        XCTAssertEqual(askedHoldingTheLock, [true], "asked once, with the lock held")
        XCTAssertEqual(s.read(me), .none, "the erased account's seals are not written back")
        XCTAssertNil(files.url(.seals, me).flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil })
        let stillHere = await s.record(seal(zoeId, at: 3), for: me, stillSignedIn: { true })
        XCTAssertEqual(stillHere, .recorded)
    }

    /// Whether another holder could take the lock at `path` now (a probe,
    /// released at once).
    private static func lockIsFree(_ path: String) -> Bool {
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return false }
        flock(fd, LOCK_UN)
        return true
    }

    func testTheTriedAtIsKeptPerAccount() {
        let tried = TriedStore(files: files)
        XCTAssertEqual(tried.load(me), [:])
        tried.save(me, ["s1": 1_000, "s2": 2_000])
        XCTAssertEqual(tried.load(me), ["s1": 1_000, "s2": 2_000])
        XCTAssertEqual(tried.load(other), [:])
        tried.save(me, [:])
        XCTAssertNil(files.url(.tried, me).flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil })
        let pruned = InvitationFinisher.Tried(["old": 0, "new": InvitationFinisher.retryMs])
            .pruned(now: InvitationFinisher.retryMs)
        XCTAssertEqual(pruned, ["new": InvitationFinisher.retryMs])
    }

    func testTheKeptPinsCopySaysNullForAPageWithNoPinsAndAbsentForNoKeep() {
        XCTAssertEqual(KeptPinsMirror.read(me, in: files), .absent)
        XCTAssertTrue(KeptPinsMirror.write("{\"p\":1}", for: me.uppercased(), in: files))
        XCTAssertEqual(KeptPinsMirror.read(me, in: files), .kept("{\"p\":1}"))
        XCTAssertTrue(KeptPinsMirror.write(nil, for: me, in: files))
        XCTAssertEqual(KeptPinsMirror.read(me, in: files), .kept(nil))
        XCTAssertEqual(KeptPinsMirror.read(other, in: files), .absent)
    }

    // MARK: - The kept trust feeds the copy, and an erasure takes everything

    @MainActor
    func testEveryKeepCopiesThePinsAndAnErasureTakesTheAccountsStores() async {
        let suite = "finish-shell-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let kept = KeptWebTrustStore(defaults: defaults, mirror: files, dataReadable: { true })
        XCTAssertTrue(kept.keep(me, pins: "{\"a\":1}", floors: "F", owners: nil))
        XCTAssertEqual(KeptPinsMirror.read(me, in: files), .kept("{\"a\":1}"))
        XCTAssertTrue(kept.keep(me, pins: nil, floors: "F", owners: nil))
        XCTAssertEqual(KeptPinsMirror.read(me, in: files), .kept(nil), "as kept: no pins blob")
        XCTAssertFalse(kept.keep(me, pins: String(repeating: "x", count: KeptWebTrustStore.maxBlobBytes + 1),
                                 floors: nil, owners: nil))
        XCTAssertEqual(KeptPinsMirror.read(me, in: files), .absent, "a keep that did not land leaves no copy")
        let locked = KeptWebTrustStore(defaults: defaults, mirror: files, dataReadable: { false })
        XCTAssertTrue(kept.keep(me, pins: "{\"a\":1}", floors: nil, owners: nil))
        XCTAssertFalse(locked.keep(me, pins: "{\"a\":2}", floors: nil, owners: nil))
        XCTAssertEqual(KeptPinsMirror.read(me, in: files), .absent, "nor one that could not be stored")

        XCTAssertTrue(kept.keep(me, pins: "{\"a\":1}", floors: nil, owners: nil))
        XCTAssertTrue(kept.keep(other, pins: "{\"b\":2}", floors: nil, owners: nil))
        _ = await store().record(seal(zoeId, at: 1), for: me)
        TriedStore(files: files).save(me, ["s": 1])
        kept.forget(me.replacingOccurrences(of: "-", with: ""))
        XCTAssertEqual(KeptPinsMirror.read(me, in: files), .absent)
        XCTAssertEqual(store().read(me), .none)
        XCTAssertEqual(TriedStore(files: files).load(me), [:])
        XCTAssertEqual(KeptPinsMirror.read(other, in: files), .kept("{\"b\":2}"), "nobody else's")
    }

    /// An erasure removes the seals holding the lock every change to them
    /// takes: it waits for a holder (the extension writing a seal) to finish,
    /// and erases then.
    @MainActor
    func testAnErasureWaitsForTheSealLockAndStillErases() async throws {
        let suite = "finish-shell-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let lock = AppGroupLock(url: dir.appendingPathComponent("seals.lock"))
        let kept = KeptWebTrustStore(defaults: defaults, mirror: files, sealLock: lock, dataReadable: { true })
        let recorded = await store().record(seal(zoeId, at: 1), for: me)
        XCTAssertEqual(recorded, .recorded)
        let acquired = await lock.acquire(timeout: 1)
        let theExtension = try XCTUnwrap(acquired)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { theExtension.release() }
        let start = Date()
        kept.forget(me)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.25, "it waited for the holder")
        XCTAssertEqual(store().read(me), .none)
    }

    // MARK: - The copy only a keep after the page's latest adopt makes

    /// The bridge over a real store whose copy of the pins goes to the scratch
    /// app group, wired as `WebKeyBridge.live` wires the shared one.
    @MainActor
    private func bridged(_ kept: KeptWebTrustStore, userId: String? = nil) -> WebKeyBridge.KeySource {
        WebKeyBridge.KeySource(
            sharingPrivateKeyBase64: { Data(repeating: 1, count: 32).base64EncodedString() },
            signingSeedBase64: { nil },
            userId: { userId ?? "5f2b8e2a-3c1d-4e5f-9a6b-7c8d9e0f1a2b" },
            previousVaultKeys: { [] },
            keptTrust: { kept.get($0) },
            keepTrust: { kept.keep($0, pins: $1, floors: $2, owners: $3) },
            takeSeals: { self.store().read($0) },
            clearSeals: { account, upTo in
                await self.store().clear(account, upTo: upTo, pins: KeptPinsMirror.pins(account, in: self.files))
            },
            dropKeptPins: { kept.dropPinsCopy($0) })
    }

    @MainActor
    private func scratchDefaults() -> UserDefaults {
        let suite = "finish-shell-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    /// An adopt drops the copy before it is answered, whatever it is answered,
    /// and when it is refused: a page whose adopt got no answer in time sends
    /// no keeps, and its own pins would run ahead of an older copy.
    @MainActor
    func testEveryAdoptDropsTheCopyUntilAKeepLands() async throws {
        let defaults = scratchDefaults()
        let kept = KeptWebTrustStore(defaults: defaults, mirror: files, dataReadable: { true })
        let k = bridged(kept)
        let keep: [String: Any] = ["op": "keepTrust", "v": 1, "account": me, "pins": "{}", "floors": NSNull(),
                                   "owners": NSNull()]
        let adopts: [[String: Any]] = [
            ["op": "keptTrust", "v": 1, "account": me],
            ["op": "keptTrust", "v": 2, "account": me],
            ["op": "keptTrust", "v": 1, "account": other],
            ["op": "keptTrust", "v": 1],
        ]
        for adopt in adopts {
            _ = try await WebKeyBridge.handle(keep, keys: k).get()
            XCTAssertEqual(KeptPinsMirror.read(me, in: files), .kept("{}"), "a keep that lands writes the copy")
            _ = await WebKeyBridge.handle(adopt, keys: k)
            XCTAssertEqual(KeptPinsMirror.read(me, in: files), .absent, "\(adopt)")
        }
        // Answered "unreadable" (before the first unlock): dropped too.
        _ = try await WebKeyBridge.handle(keep, keys: k).get()
        let locked = KeptWebTrustStore(defaults: defaults, mirror: files, dataReadable: { false })
        let answer = try await WebKeyBridge.handle(["op": "keptTrust", "v": 1, "account": me], keys: bridged(locked)).get()
        XCTAssertEqual(answer["state"] as? String, "unreadable")
        XCTAssertEqual(KeptPinsMirror.read(me, in: files), .absent)
        // Answered with the copy: dropped, and the page's keep that follows writes it.
        let copy = try await WebKeyBridge.handle(["op": "keptTrust", "v": 1, "account": me], keys: k).get()
        XCTAssertEqual(copy["state"] as? String, "copy")
        XCTAssertEqual(KeptPinsMirror.read(me, in: files), .absent)
        _ = try await WebKeyBridge.handle(keep, keys: k).get()
        XCTAssertEqual(KeptPinsMirror.read(me, in: files), .kept("{}"))
    }

    @MainActor
    func testAKeepThatFailsDropsTheCopy() async throws {
        let kept = KeptWebTrustStore(defaults: scratchDefaults(), mirror: files, dataReadable: { true })
        let k = bridged(kept)
        let good: [String: Any] = ["op": "keepTrust", "v": 1, "account": me, "pins": "{\"p\":1}"]
        let bad: [[String: Any]] = [
            ["op": "keepTrust", "v": 1, "account": me, "floors": ["a": 1]],
            ["op": "keepTrust", "v": 1, "account": me,
             "pins": String(repeating: "x", count: KeptWebTrustStore.maxBlobBytes + 1)],
            ["op": "keepTrust", "v": 1, "account": other, "pins": "{}"],
            ["op": "keepTrust", "v": true, "account": me, "pins": "{}"],
        ]
        for keep in bad {
            _ = try await WebKeyBridge.handle(good, keys: k).get()
            XCTAssertEqual(KeptPinsMirror.read(me, in: files), .kept("{\"p\":1}"))
            let refused = await WebKeyBridge.handle(keep, keys: k)
            XCTAssertNotNil(refused.failure)
            XCTAssertEqual(KeptPinsMirror.read(me, in: files), .absent, "\(keep["account"] ?? "")")
        }
    }

    /// The review's case: the page pinned someone itself at one key in a
    /// session whose adopt got no answer in time, so it sent no keep; the copy
    /// an earlier session kept does not hold them. The extension finishes
    /// nothing, rather than taking them for a first contact at another key.
    @MainActor
    func testAfterAnAdoptWithNoKeepTheExtensionFinishesNothing() async throws {
        let now = Date()
        let (keychain, defaults, server, _) = scene(now: now)
        let kept = KeptWebTrustStore(defaults: scratchDefaults(), mirror: files, dataReadable: { true })
        _ = try await WebKeyBridge.handle(["op": "keepTrust", "v": 1, "account": me, "pins": "{}"],
                                          keys: bridged(kept)).get()
        _ = await WebKeyBridge.handle(["op": "keptTrust", "v": 1, "account": me], keys: bridged(kept))
        let run = await BackgroundFinish.run(deadline: now.addingTimeInterval(20),
                                             env: environment(keychain, defaults, server, now: now))
        XCTAssertEqual(run.report.stopped, "the app keeps no copy of the page's pins for this account")
        XCTAssertTrue(server.requests.isEmpty)
    }

    // MARK: - The bridge's two seal ops

    private func keys(userId: String? = "5f2b8e2a-3c1d-4e5f-9a6b-7c8d9e0f1a2b",
                      take: @escaping (String) async -> SealRead = { _ in .none },
                      clear: @escaping (String, Double) async -> Bool = { _, _ in true }) -> WebKeyBridge.KeySource {
        WebKeyBridge.KeySource(
            sharingPrivateKeyBase64: { Data(repeating: 1, count: 32).base64EncodedString() },
            signingSeedBase64: { nil },
            userId: { userId },
            previousVaultKeys: { [] },
            takeSeals: take,
            clearSeals: clear)
    }

    func testTakeSealsAnswersSealsNoneAndUnreadableNamingTheAccountInItsOneForm() async throws {
        let one = seal(zoeId, at: 1_800_000_000_123)
        var askedFor: [String] = []
        let k = keys(userId: me.uppercased(), take: { askedFor.append($0); return .seals([one]) })
        let seals = try await WebKeyBridge.handle(["op": "takeSeals", "v": 1, "account": me], keys: k).get()
        XCTAssertEqual(seals as NSDictionary, [
            "v": 1, "account": me, "state": "seals",
            "seals": [["user_id": zoeId, "sharing_public_key": String(repeating: "ab", count: 32),
                       "signing_public_key": String(repeating: "cd", count: 32), "sealed_at": 1_800_000_000_123]],
        ] as NSDictionary)
        XCTAssertEqual(askedFor, [me], "the account in its one form")
        let respelled = try await WebKeyBridge.handle(["op": "takeSeals", "v": 1, "account": me.uppercased()], keys: k).get()
        XCTAssertEqual(respelled["account"] as? String, me)

        let none = try await WebKeyBridge.handle(["op": "takeSeals", "v": 1, "account": me],
                                                 keys: keys(take: { _ in .none })).get()
        XCTAssertEqual(none as NSDictionary, ["v": 1, "account": me, "state": "none"] as NSDictionary)
        let empty = try await WebKeyBridge.handle(["op": "takeSeals", "v": 1, "account": me],
                                                  keys: keys(take: { _ in .seals([]) })).get()
        XCTAssertEqual(empty["state"] as? String, "none")
        let unreadable = try await WebKeyBridge.handle(["op": "takeSeals", "v": 1, "account": me],
                                                       keys: keys(take: { _ in .unreadable })).get()
        XCTAssertEqual(unreadable as NSDictionary, ["v": 1, "account": me, "state": "unreadable"] as NSDictionary)
    }

    func testClearSealsLetsGoUpToTheTimeTheAccountNames() async throws {
        var cleared: [(String, Double)] = []
        let k = keys(clear: { cleared.append(($0, $1)); return true })
        let reply = try await WebKeyBridge.handle(["op": "clearSeals", "v": 1, "account": me.uppercased(),
                                                   "upTo": NSNumber(value: 1_800_000_000_123 as Int64)], keys: k).get()
        XCTAssertEqual(reply as NSDictionary, ["v": 1, "account": me, "state": "cleared"] as NSDictionary)
        XCTAssertEqual(cleared.map { $0.0 }, [me])
        XCTAssertEqual(cleared.map { $0.1 }, [1_800_000_000_123])

        for bad: Any? in [nil, "1000", NSNumber(value: true), NSNumber(value: -1), NSNumber(value: Double.infinity)] {
            var request: [String: Any] = ["op": "clearSeals", "v": 1, "account": me]
            if let bad { request["upTo"] = bad }
            let r = await WebKeyBridge.handle(request, keys: k)
            XCTAssertEqual(r.failure, .invalidRequest, "\(String(describing: bad))")
        }
        XCTAssertEqual(cleared.count, 1)
        let refused = await WebKeyBridge.handle(["op": "clearSeals", "v": 1, "account": me, "upTo": 5],
                                                keys: keys(clear: { _, _ in false }))
        XCTAssertEqual(refused.failure, .notCleared)
    }

    func testTheSealOpsAreOnlyForTheSignedInAccountAndVersionOne() async {
        var touched = false
        let k = keys(take: { _ in touched = true; return .none }, clear: { _, _ in touched = true; return true })
        for account: Any in [other, "not-an-id", 7] {
            let take = await WebKeyBridge.handle(["op": "takeSeals", "v": 1, "account": account], keys: k)
            XCTAssertEqual(take.failure, .notThisAccount, "\(account)")
            let clear = await WebKeyBridge.handle(["op": "clearSeals", "v": 1, "account": account, "upTo": 1], keys: k)
            XCTAssertEqual(clear.failure, .notThisAccount, "\(account)")
        }
        let noAccount = await WebKeyBridge.handle(["op": "takeSeals", "v": 1], keys: k)
        XCTAssertEqual(noAccount.failure, .notThisAccount)
        for v: Any? in [nil, "1", 2, true] {
            var request: [String: Any] = ["op": "takeSeals", "account": me]
            if let v { request["v"] = v }
            let r = await WebKeyBridge.handle(request, keys: k)
            XCTAssertEqual(r.failure, .invalidRequest, "v = \(String(describing: v))")
        }
        let signedOut = await WebKeyBridge.handle(["op": "takeSeals", "v": 1, "account": me], keys: keys(userId: nil))
        XCTAssertEqual(signedOut.failure, .signedOut)
        XCTAssertFalse(touched, "nothing was read or cleared for any of them")
    }

    /// The real store behind the two ops: what the page is handed, and what is
    /// left after it lets go of what it folded.
    func testThePageTakesAndClearsTheRealStore() async throws {
        let s = store()
        _ = await s.record(seal(zoeId, at: 1000), for: me)
        _ = await s.record(seal(other, at: 2000), for: me)
        let k = keys(take: { s.read($0) }, clear: { account, upTo in
            await s.clear(account, upTo: upTo, pins: KeptPinsMirror.pins(account, in: self.files))
        })
        let taken = try await WebKeyBridge.handle(["op": "takeSeals", "v": 1, "account": me], keys: k).get()
        XCTAssertEqual((taken["seals"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(s.read(me), .seals([seal(zoeId, at: 1000), seal(other, at: 2000)]), "taking deletes nothing")

        // The page folded both, but its keep has not landed: the copy holds
        // neither, and nothing goes.
        _ = try await WebKeyBridge.handle(["op": "clearSeals", "v": 1, "account": me, "upTo": 5000], keys: k).get()
        XCTAssertEqual(s.read(me), .seals([seal(zoeId, at: 1000), seal(other, at: 2000)]))

        // Its keep landed: Zoe pinned, the other a conflict. Up to 1000 goes.
        let conflict = InvitationFinisher.conflictKeyHex
        XCTAssertTrue(KeptPinsMirror.write("""
            {"\(zoeId)":{"sharingPubkeyHex":"\(String(repeating: "ab", count: 32))","signingPubkeyHex":"\(String(repeating: "cd", count: 32))"},
             "\(other)":{"sharingPubkeyHex":"\(conflict)","signingPubkeyHex":"\(conflict)","conflict":true}}
            """, for: me, in: files))
        _ = try await WebKeyBridge.handle(["op": "clearSeals", "v": 1, "account": me, "upTo": 1000], keys: k).get()
        let left = try await WebKeyBridge.handle(["op": "takeSeals", "v": 1, "account": me], keys: k).get()
        XCTAssertEqual((left["seals"] as? [[String: Any]])?.compactMap { $0["user_id"] as? String }, [other])
        _ = try await WebKeyBridge.handle(["op": "clearSeals", "v": 1, "account": me, "upTo": 2000], keys: k).get()
        XCTAssertEqual(s.read(me), .none, "a conflict holds its person too")
    }

    // MARK: - The push

    /// The note dispatcher's real alert: `aps` with the alert and
    /// mutable-content, the tickle's fields beside it.
    private let alert: [AnyHashable: Any] = [
        "aps": ["alert": ["title": "Pingolin Note", "body": "Someone you invited has joined Pingolin."],
                "mutable-content": 1],
        "type": "tickle", "kind": "finish_shares", "refId": "00000000-0000-0000-0000-000000000000",
    ]

    func testTheFinishSharesAlertIsRecognisedByItsKind() {
        XCTAssertTrue(FinishPush.isFinishShares(alert))
        XCTAssertEqual(PushNotificationManager.event(from: alert), .finishShares)
        for kind in ["sync", "share", "notebook_share", "identities", "reminder"] {
            let tickle: [AnyHashable: Any] = ["type": "tickle", "kind": kind]
            XCTAssertFalse(FinishPush.isFinishShares(tickle), kind)
            XCTAssertNotEqual(PushNotificationManager.event(from: tickle), .finishShares, kind)
        }
        XCTAssertFalse(FinishPush.isFinishShares([:]))
    }

    // MARK: - The banner

    private func finished(_ emails: [String]) -> [InvitationFinisher.UnfinishedShare] {
        emails.enumerated().map { InvitationFinisher.UnfinishedShare(shareId: "s\($0.offset)", itemId: "n\($0.offset)",
                                                                     recipientEmail: $0.element) }
    }

    func testTheBannerSaysWhoCanNowOpenWhat() {
        XCTAssertNil(FinishBanner.body(finished: [], detail: "titles"), "nothing finished: the server's words")
        XCTAssertEqual(FinishBanner.body(finished: finished(["Zoe@Example.test"]), detail: "titles"),
                       "Zoe@Example.test can now open the note you shared.")
        XCTAssertEqual(FinishBanner.body(finished: finished(["zoe@example.test", "ZOE@example.test"]), detail: nil),
                       "zoe@example.test can now open the notes you shared.")
        XCTAssertEqual(FinishBanner.body(finished: finished(["a@example.test", "b@example.test"]), detail: "full"),
                       "a@example.test and b@example.test can now open the notes you shared.")
        XCTAssertEqual(FinishBanner.body(finished: finished(["a@example.test", "b@example.test", "c@example.test"]),
                                         detail: "full"),
                       "a@example.test and 2 others can now open the notes you shared.")
        // Notes, not shares: one note shared with two people (its id in either spelling).
        let item = "c0ffee00-0000-4000-8000-0000000000aa"
        let oneNote = [InvitationFinisher.UnfinishedShare(shareId: "s1", itemId: item, recipientEmail: "a@example.test"),
                       InvitationFinisher.UnfinishedShare(shareId: "s2", itemId: item.uppercased(),
                                                          recipientEmail: "b@example.test")]
        XCTAssertEqual(FinishBanner.body(finished: oneNote, detail: "full"),
                       "a@example.test and b@example.test can now open the note you shared.")
        XCTAssertEqual(FinishBanner.body(finished: oneNote, detail: "generic"),
                       "2 people you invited can now open the note you shared.")
    }

    /// Generic notifications name nobody; and an address is shown only when it
    /// looks like one: the server's list is not the app's words.
    func testTheBannerNamesNobodyWhenGenericOrWhenTheAddressIsNotOne() {
        XCTAssertEqual(FinishBanner.body(finished: finished(["zoe@example.test"]), detail: "generic"),
                       "Someone you invited can now open the note you shared.")
        for odd in ["Call 0800 555 0100 now", "zoe@example", "z\u{202E}oe@example.test", "zoé@example.test",
                    String(repeating: "a", count: 250) + "@x.io"] {
            XCTAssertEqual(FinishBanner.body(finished: finished([odd]), detail: "full"),
                           "Someone you invited can now open the note you shared.", odd)
        }
        XCTAssertEqual(FinishBanner.body(finished: finished(["a@example.test", "not an address"]), detail: "full"),
                       "2 people you invited can now open the notes you shared.")
    }

    func testTheExtensionRewritesOnlyTheBodyAndKeepsTheServersAlertWhenNothingWasFinished() {
        let original = UNMutableNotificationContent()
        original.title = "Pingolin Note"
        original.body = "Someone you invited has joined Pingolin."
        original.userInfo = ["kind": "finish_shares"]
        var nothing = BackgroundFinish.Result()
        nothing.detail = "titles"
        XCTAssertEqual(NotificationService.banner(for: original, result: nothing).body, original.body)
        var one = BackgroundFinish.Result()
        one.report.finished = finished(["zoe@example.test"])
        one.detail = "titles"
        let rewritten = NotificationService.banner(for: original, result: one)
        XCTAssertEqual(rewritten.title, "Pingolin Note")
        XCTAssertEqual(rewritten.body, "zoe@example.test can now open the note you shared.")
        XCTAssertEqual(rewritten.userInfo["kind"] as? String, "finish_shares")
    }

    func testTheBannerIsDeliveredOnce() {
        var delivered: [String] = []
        let once = DeliverOnce { delivered.append($0.body) }
        let a = UNMutableNotificationContent(); a.body = "a"
        let b = UNMutableNotificationContent(); b.body = "b"
        XCTAssertTrue(once(a))
        XCTAssertFalse(once(b))
        XCTAssertEqual(delivered, ["a"])
    }

    // MARK: - The app's mirror

    func testTheAppGroupIsTheAppsOne() {
        XCTAssertEqual(FinisherBridgeKeys.suite, SharedAppGroup.identifier)
    }

    func testTheMirrorNamesTheSignedInAccountInItsOneFormAndSignOutRemovesIt() {
        let suite = "finish-bridge-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        FinisherBridge.publish(account: me.uppercased(), apiBase: "https://api", authBase: "https://auth",
                               detail: "titles", defaults: defaults)
        XCTAssertEqual(FinisherBridge.read(defaults), .init(account: me, apiBase: "https://api",
                                                            authBase: "https://auth", detail: "titles"))
        FinisherBridge.publishDetail("generic", defaults: defaults)
        XCTAssertEqual(FinisherBridge.read(defaults).detail, "generic")
        FinisherBridge.publish(account: nil, apiBase: "https://api", authBase: "https://auth", detail: "titles",
                               defaults: defaults)
        XCTAssertNil(FinisherBridge.read(defaults).account)
        FinisherBridge.publish(account: "not-an-id", apiBase: "x", authBase: "y", detail: "z", defaults: defaults)
        XCTAssertNil(FinisherBridge.read(defaults).account)
    }

    // MARK: - The extension's run

    private final class Keychain {
        var items: [KeychainService.Key: KeychainService.Read] = [:]
        func read(_ key: KeychainService.Key) -> KeychainService.Read { items[key] ?? .notFound }
    }

    private final class Recorder: FinisherTransport, @unchecked Sendable {
        var requests: [URLRequest] = []
        var answer: (URLRequest) -> (Int, Any) = { _ in (200, ["success": true, "data": []]) }
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            requests.append(request)
            let (status, body) = answer(request)
            return (try JSONSerialization.data(withJSONObject: body),
                    HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    private static func token(sub: String, expires: Date) -> String {
        func b64(_ object: [String: Any]) -> String {
            try! JSONSerialization.data(withJSONObject: object).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(b64(["alg": "RS256"])).\(b64(["sub": sub, "exp": Int(expires.timeIntervalSince1970)])).signature"
    }

    private func scene(now: Date) -> (Keychain, UserDefaults, Recorder, String) {
        let keychain = Keychain()
        let suite = "finish-run-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let vault = Data(Sodium().randomBytes.buf(length: 32)!)
        keychain.items = [
            .userId: .found(me.uppercased()),
            .accessToken: .found(Self.token(sub: me, expires: now.addingTimeInterval(3600))),
            .vaultKey: .found(vault.base64EncodedString()),
            .sharingPublicKey: .found(Data(repeating: 9, count: 32).base64EncodedString()),
            .signingPrivateKey: .found(Data(repeating: 7, count: 32).base64EncodedString()),
        ]
        FinisherBridge.publish(account: me, apiBase: "https://api-note.test", authBase: "https://api-auth.test",
                               detail: "titles", defaults: defaults)
        XCTAssertTrue(KeptPinsMirror.write("{}", for: me, in: files))
        return (keychain, defaults, Recorder(), suite)
    }

    private func environment(_ keychain: Keychain, _ defaults: UserDefaults, _ server: Recorder, now: Date,
                             passLock: AppGroupLock? = nil,
                             refreshed: @escaping (String?) async -> String? = { _ in nil }) -> BackgroundFinish.Environment {
        let lock = passLock ?? AppGroupLock(url: dir.appendingPathComponent("finish.lock"))
        return BackgroundFinish.Environment(
            keychain: { keychain.read($0) },
            shared: { defaults },
            files: { self.files },
            sealLock: { AppGroupLock(url: self.dir.appendingPathComponent("seals.lock")) },
            passLock: { lock },
            refreshedToken: refreshed,
            transport: server,
            now: { now })
    }

    func testTheRunAsksTheServerOnlyForTheAccountSignedInEverywhere() async {
        let now = Date()
        let (keychain, defaults, server, _) = scene(now: now)
        let ok = await BackgroundFinish.run(deadline: now.addingTimeInterval(20),
                                            env: environment(keychain, defaults, server, now: now))
        XCTAssertNil(ok.report.stopped)
        XCTAssertEqual(server.requests.map { $0.url!.absoluteString }, ["https://api-note.test/api/v1/shares/unfinished"])
        XCTAssertEqual(ok.detail, "titles")

        // Signed out here, another account mirrored, or a token for someone else: nothing is asked.
        keychain.items[.userId] = .notFound
        let signedOut = await BackgroundFinish.run(deadline: now.addingTimeInterval(20),
                                                   env: environment(keychain, defaults, server, now: now))
        XCTAssertEqual(signedOut.report.stopped, "not signed in")
        keychain.items[.userId] = .found(me)
        FinisherBridge.publish(account: other, apiBase: "https://api-note.test", authBase: "x", detail: "titles",
                               defaults: defaults)
        let mirroredOther = await BackgroundFinish.run(deadline: now.addingTimeInterval(20),
                                                       env: environment(keychain, defaults, server, now: now))
        XCTAssertEqual(mirroredOther.report.stopped, "the app has not run since this account signed in")
        FinisherBridge.publish(account: me, apiBase: "https://api-note.test", authBase: "x", detail: "titles",
                               defaults: defaults)
        keychain.items[.accessToken] = .found(Self.token(sub: other, expires: now.addingTimeInterval(3600)))
        let otherToken = await BackgroundFinish.run(deadline: now.addingTimeInterval(20),
                                                    env: environment(keychain, defaults, server, now: now))
        XCTAssertEqual(otherToken.report.stopped, "the token is for another account")
        keychain.items[.accessToken] = .unreadable(-25308)
        let locked = await BackgroundFinish.run(deadline: now.addingTimeInterval(20),
                                                env: environment(keychain, defaults, server, now: now))
        XCTAssertEqual(locked.report.stopped, "no session")
        XCTAssertEqual(server.requests.count, 1, "none of them asked anything")
    }

    func testATokenThatHasRunOutIsRefreshedFirstAndWithoutOneNothingRuns() async {
        let now = Date()
        let (keychain, defaults, server, _) = scene(now: now)
        keychain.items[.accessToken] = .found(Self.token(sub: me, expires: now.addingTimeInterval(10)))
        var asked: [String?] = []
        let none = await BackgroundFinish.run(deadline: now.addingTimeInterval(20), env: environment(
            keychain, defaults, server, now: now, refreshed: { asked.append($0); return nil }))
        XCTAssertEqual(none.report.stopped, "the session token has run out")
        XCTAssertEqual(asked, ["https://api-auth.test"])
        XCTAssertTrue(server.requests.isEmpty)

        let fresh = Self.token(sub: me, expires: now.addingTimeInterval(3600))
        let refreshed = await BackgroundFinish.run(deadline: now.addingTimeInterval(20), env: environment(
            keychain, defaults, server, now: now, refreshed: { _ in fresh }))
        XCTAssertTrue(refreshed.refreshed)
        XCTAssertEqual(server.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer \(fresh)")
    }

    /// Signed out, or another account, by the time the run ends (by the
    /// Keychain's word or the app's): the banner names nobody, and the pass
    /// saved nothing.
    func testAnAccountThatChangesDuringTheRunIsNamedOnNoBannerAndNothingIsSaved() async {
        let now = Date()
        let (keychain, defaults, server, _) = scene(now: now)
        server.answer = { _ in
            keychain.items[.userId] = .found(self.other)
            return (200, ["success": true, "data": []])
        }
        let switched = await BackgroundFinish.run(deadline: now.addingTimeInterval(20),
                                                  env: environment(keychain, defaults, server, now: now))
        XCTAssertTrue(switched.accountChanged)
        XCTAssertTrue(switched.report.accountChanged)
        XCTAssertEqual(switched.report.stopped, InvitationFinisher.Report.accountChangedReason)
        XCTAssertTrue(TriedStore(files: files).load(me).isEmpty)

        keychain.items[.userId] = .found(me)
        server.answer = { _ in
            FinisherBridge.publish(account: nil, apiBase: "https://api-note.test", authBase: "x", detail: "titles",
                                   defaults: defaults)
            return (200, ["success": true, "data": []])
        }
        let signedOut = await BackgroundFinish.run(deadline: now.addingTimeInterval(20),
                                                   env: environment(keychain, defaults, server, now: now))
        XCTAssertTrue(signedOut.accountChanged)

        var finishedForAnother = BackgroundFinish.Result()
        finishedForAnother.report.finished = finished(["zoe@example.test"])
        finishedForAnother.detail = "titles"
        finishedForAnother.accountChanged = true
        let original = UNMutableNotificationContent()
        original.body = "Someone you invited has joined Pingolin."
        XCTAssertEqual(NotificationService.banner(for: original, result: finishedForAnother).body, original.body,
                       "the server's words, whatever was finished")
    }

    func testOnePassAtATimeHereOrInTheApp() async throws {
        let now = Date()
        let (keychain, defaults, server, _) = scene(now: now)
        let lock = AppGroupLock(url: dir.appendingPathComponent("finish.lock"))
        let acquired = await lock.acquire(timeout: 1)
        let theApps = try XCTUnwrap(acquired)
        let busy = await BackgroundFinish.run(deadline: now.addingTimeInterval(20),
                                              env: environment(keychain, defaults, server, now: now, passLock: lock))
        XCTAssertEqual(busy.report.stopped, "another pass is running")
        XCTAssertTrue(server.requests.isEmpty)
        theApps.release()
        let free = await BackgroundFinish.run(deadline: now.addingTimeInterval(20),
                                              env: environment(keychain, defaults, server, now: now, passLock: lock))
        XCTAssertNil(free.report.stopped)
    }

    func testWithoutTheKeysOrTheKeptPinsNothingRuns() async {
        let now = Date()
        let (keychain, defaults, server, _) = scene(now: now)
        keychain.items[.vaultKey] = .unreadable(-25308)
        let noKeys = await BackgroundFinish.run(deadline: now.addingTimeInterval(20),
                                                env: environment(keychain, defaults, server, now: now))
        XCTAssertEqual(noKeys.report.stopped, "the keys could not be read")
        keychain.items[.vaultKey] = .found(Data(repeating: 3, count: 32).base64EncodedString())
        files.remove(.keptPins, me)
        let noPins = await BackgroundFinish.run(deadline: now.addingTimeInterval(20),
                                                env: environment(keychain, defaults, server, now: now))
        XCTAssertEqual(noPins.report.stopped, "the app keeps no copy of the page's pins for this account")
        XCTAssertTrue(server.requests.isEmpty)
    }

    /// The sharer's key is the app's stored public key as 64 hex, or derived
    /// from the private key for an account from before it was kept.
    func testTheSharersKeyIsTheStoredPublicKeyAsHex() {
        let pub = Data((0..<32).map { UInt8($0) })
        let stored: (KeychainService.Key) -> KeychainService.Read = {
            $0 == .sharingPublicKey ? .found(pub.base64EncodedString()) : .notFound
        }
        XCTAssertEqual(InvitationFinisher.sharerPublicKeyHex(stored),
                       "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
        let priv = Data(Sodium().randomBytes.buf(length: 32)!)
        let derived: (KeychainService.Key) -> KeychainService.Read = {
            $0 == .sharingPrivateKey ? .found(priv.base64EncodedString()) : .notFound
        }
        XCTAssertEqual(InvitationFinisher.sharerPublicKeyHex(derived), deriveSharingPublicKey(privateKey: priv))
        XCTAssertNil(InvitationFinisher.sharerPublicKeyHex { _ in .notFound })
    }

    // MARK: - The refresh both processes take turns at

    private final class Pair {
        var access: String?
        var refresh: String?
        var writes: [(String, String?)] = []
        var writeWorks = true
        /// What the n-th read finds: what another process wrote meanwhile
        /// (the 2nd read is the one under the lock, the 3rd the one just
        /// before the write).
        var atRead: [Int: (String?, String?)] = [:]
        private var reads = 0
        var store: ExtensionSessionRefresh.TokenStore {
            ExtensionSessionRefresh.TokenStore(
                read: {
                    self.reads += 1
                    if let next = self.atRead[self.reads] { (self.access, self.refresh) = next }
                    return (self.access, self.refresh)
                },
                write: { access, refresh in
                    guard self.writeWorks else { return false }
                    self.writes.append((access, refresh))
                    (self.access, self.refresh) = (access, refresh ?? self.refresh)
                    return true
                })
        }
    }

    func testTheExtensionRefreshesHoldingTheLockAndSavesBeforeUsing() async throws {
        let now = Date()
        let lock = AppGroupLock(url: dir.appendingPathComponent("refresh.lock"))
        let pair = Pair()
        pair.access = Self.token(sub: me, expires: now.addingTimeInterval(-5))
        pair.refresh = "refresh-1"
        let server = Recorder()
        let fresh = Self.token(sub: me, expires: now.addingTimeInterval(3600))
        server.answer = { _ in (200, ["success": true, "data": ["access_token": fresh, "refresh_token": "refresh-2"]]) }
        let token = await ExtensionSessionRefresh.token(now: now, margin: 30, authBase: "https://api-auth.test",
                                                        lock: lock, transport: server, store: pair.store)
        XCTAssertEqual(token, fresh)
        let request = try XCTUnwrap(server.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api-auth.test/api/v1/auth/refresh")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Refresh-Token"), "refresh-1")
        XCTAssertEqual(request.httpBody, Data("{}".utf8))
        XCTAssertEqual(pair.writes.map { $0.1 }, ["refresh-2"])

        // A stored token that is still good is used as it is.
        let quiet = Recorder()
        let good = await ExtensionSessionRefresh.token(now: now, margin: 30, authBase: "https://api-auth.test",
                                                       lock: lock, transport: quiet, store: pair.store)
        XCTAssertEqual(good, fresh)
        XCTAssertTrue(quiet.requests.isEmpty)
    }

    func testWhenTheAppRefreshedMeanwhileItsPairIsUsedAndNothingIsSent() async {
        let now = Date()
        let pair = Pair()
        pair.access = Self.token(sub: me, expires: now.addingTimeInterval(-5))
        pair.refresh = "refresh-1"
        let theirs = Self.token(sub: me, expires: now.addingTimeInterval(3600))
        pair.atRead[2] = (theirs, "refresh-app")
        let server = Recorder()
        let token = await ExtensionSessionRefresh.token(
            now: now, margin: 30, authBase: "https://api-auth.test",
            lock: AppGroupLock(url: dir.appendingPathComponent("refresh.lock")), transport: server, store: pair.store)
        XCTAssertEqual(token, theirs)
        XCTAssertTrue(server.requests.isEmpty)
        XCTAssertTrue(pair.writes.isEmpty)
    }

    /// The app signed out, or another account signed in (which does not take
    /// the refresh lock), while the refresh was out: its items are not
    /// overwritten with this pair, and the pair is not used.
    func testAPairIsWrittenOnlyOverTheSessionItWasRefreshedFrom() async {
        let now = Date()
        let pair = Pair()
        pair.access = Self.token(sub: me, expires: now.addingTimeInterval(-5))
        pair.refresh = "refresh-1"
        let theirs = Self.token(sub: other, expires: now.addingTimeInterval(3600))
        pair.atRead[3] = (theirs, "another-session")
        let server = Recorder()
        server.answer = { _ in (200, ["access_token": Self.token(sub: self.me, expires: now.addingTimeInterval(3600)),
                                      "refresh_token": "refresh-2"]) }
        let token = await ExtensionSessionRefresh.token(
            now: now, margin: 30, authBase: "https://api-auth.test",
            lock: AppGroupLock(url: dir.appendingPathComponent("refresh.lock")), transport: server, store: pair.store)
        XCTAssertNil(token)
        XCTAssertEqual(server.requests.count, 1, "the refresh went")
        XCTAssertTrue(pair.writes.isEmpty, "and was not written over the other session")
        XCTAssertEqual(pair.refresh, "another-session")

        // Signed out meanwhile: nothing to write over either.
        let gone = Pair()
        gone.access = Self.token(sub: me, expires: now.addingTimeInterval(-5))
        gone.refresh = "refresh-1"
        gone.atRead[3] = (nil, nil)
        let none = await ExtensionSessionRefresh.token(
            now: now, margin: 30, authBase: "https://api-auth.test",
            lock: AppGroupLock(url: dir.appendingPathComponent("refresh.lock")), transport: server, store: gone.store)
        XCTAssertNil(none)
        XCTAssertTrue(gone.writes.isEmpty)
    }

    func testAPairThatCantBeSavedIsNeverUsedAndTheLockHeldElsewhereStopsIt() async throws {
        let now = Date()
        let pair = Pair()
        pair.access = Self.token(sub: me, expires: now.addingTimeInterval(-5))
        pair.refresh = "refresh-1"
        pair.writeWorks = false
        let server = Recorder()
        server.answer = { _ in (200, ["access_token": "a.b.c", "refresh_token": "r2"]) }
        let lock = AppGroupLock(url: dir.appendingPathComponent("refresh.lock"))
        let unsaved = await ExtensionSessionRefresh.token(now: now, margin: 30, authBase: "https://api-auth.test",
                                                          lock: lock, transport: server, store: pair.store)
        XCTAssertNil(unsaved)

        pair.writeWorks = true
        let acquired = await lock.acquire(timeout: 1)
        let theApps = try XCTUnwrap(acquired)
        let waiting = Recorder()
        let busy = await ExtensionSessionRefresh.token(now: now, margin: 30, authBase: "https://api-auth.test",
                                                       lock: lock, transport: waiting, store: pair.store, wait: 0.2)
        XCTAssertNil(busy)
        XCTAssertTrue(waiting.requests.isEmpty)
        theApps.release()
        let noAuthBase = await ExtensionSessionRefresh.token(now: now, margin: 30, authBase: nil, lock: lock,
                                                             transport: waiting, store: pair.store)
        XCTAssertNil(noAuthBase)
    }

    func testTheRefreshRuleIsTheTrackApps() {
        XCTAssertFalse(SessionRefresh.anotherProcessRefreshed(before: "a", now: "a"))
        XCTAssertTrue(SessionRefresh.anotherProcessRefreshed(before: "a", now: "b"))
        XCTAssertFalse(SessionRefresh.anotherProcessRefreshed(before: "a", now: nil))
        XCTAssertFalse(SessionRefresh.anotherProcessRefreshed(before: "a", now: ""))
        XCTAssertFalse(SessionRefresh.anotherProcessRefreshed(before: "a", now: "none"))
    }

    /// The app's own refresh takes the same lock and reads the pair again
    /// under it (the source: it runs against the real auth server).
    func testTheAppsRefreshTakesTheSameLockAndReadsThePairAgain() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let api = try String(contentsOf: root.appendingPathComponent("App/Services/APIService.swift"), encoding: .utf8)
        let start = try XCTUnwrap(api.range(of: "private func performRefresh() async -> RefreshOutcome {"))
        let body = String(api[start.upperBound...].prefix(3000))
        let order = ["beginBackgroundTask", "AppGroupLock.refresh()", "lock?.acquire(timeout: AppGroupLock.appWait)",
                     "SessionRefresh.anotherProcessRefreshed(before: stored", "try await refreshToken(stored)"]
        var at = body.startIndex
        for mark in order {
            let r = try XCTUnwrap(body.range(of: mark, range: at..<body.endIndex), mark)
            at = r.upperBound
        }
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let f) = self { return f }
        return nil
    }
}
