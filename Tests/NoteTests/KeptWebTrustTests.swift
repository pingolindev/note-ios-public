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

/// The iOS half of kept trust. The page hands its pins, floors and owners to
/// the shell after every change and gets them back at the same account's
/// next sign-in (the web editor's keptTrust.ts); the shell keeps them
/// outside WebKit, answers only for the signed-in account, never calls an
/// unreadable store empty, takes one last keep before a sign-out or an
/// expiry ends the page — while the bridge still answers that account —
/// keeps an expiry's website data, and empties it before another account's
/// page loads.
final class KeptWebTrustTests: XCTestCase {

    private let me = "5f2b8e2a-3c1d-4e5f-9a6b-7c8d9e0f1a2b"
    private let other = "0a1b2c3d-4e5f-4061-8728-394a5b6c7d8e"
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "kept-web-trust-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    @MainActor
    private func store(readable: Bool = true) -> KeptWebTrustStore {
        KeptWebTrustStore(defaults: defaults, dataReadable: { readable })
    }

    // MARK: - The store

    @MainActor
    func testACopyBelongsToTheAccountInItsOneFormAndAccountsStayApart() {
        let s = store()
        XCTAssertTrue(s.keep(me.uppercased(), pins: "{\"p\":1}", floors: nil, owners: "{\"o\":2}"))
        XCTAssertEqual(s.get(me), .copy(pins: "{\"p\":1}", floors: nil, owners: "{\"o\":2}"))
        XCTAssertEqual(s.get(me.replacingOccurrences(of: "-", with: "")), .copy(pins: "{\"p\":1}", floors: nil, owners: "{\"o\":2}"))
        XCTAssertEqual(s.get(other), .none, "another account has nothing of mine")
        XCTAssertNotNil(defaults.object(forKey: "note_kept_web_trust.\(me)"), "kept under the one form")
    }

    @MainActor
    func testANullDropsItsBlobAndAllNullRemovesTheCopy() {
        let s = store()
        XCTAssertTrue(s.keep(me, pins: "a", floors: "b", owners: "c"))
        XCTAssertTrue(s.keep(me, pins: "a", floors: nil, owners: "c"))
        XCTAssertEqual(s.get(me), .copy(pins: "a", floors: nil, owners: "c"))
        XCTAssertTrue(s.keep(me, pins: nil, floors: nil, owners: nil))
        XCTAssertEqual(s.get(me), .none)
    }

    @MainActor
    func testNothingOverOneMegabyteIsKeptAndTheEdgeIs() {
        let s = store()
        let edge = String(repeating: "x", count: KeptWebTrustStore.maxBlobBytes)
        XCTAssertTrue(s.keep(me, pins: edge, floors: nil, owners: nil))
        XCTAssertFalse(s.keep(me, pins: nil, floors: edge + "x", owners: nil))
        XCTAssertFalse(s.keep(me, pins: nil, floors: nil, owners: String(repeating: "é", count: KeptWebTrustStore.maxBlobBytes / 2 + 1)),
                       "the cap counts UTF-8 bytes")
        XCTAssertEqual(s.get(me), .copy(pins: edge, floors: nil, owners: nil), "a refused keep changes nothing")
    }

    @MainActor
    func testAStoreThatCantBeReadIsUnreadableNeverNone() {
        XCTAssertTrue(store().keep(me, pins: "a", floors: nil, owners: nil))
        let locked = store(readable: false)
        XCTAssertEqual(locked.get(me), .unreadable, "before the first unlock")
        XCTAssertEqual(locked.get(other), .unreadable, "even where nothing is kept")
        XCTAssertFalse(locked.keep(me, pins: "b", floors: nil, owners: nil))
        defaults.set(["pins": 7], forKey: "note_kept_web_trust.\(other)")
        XCTAssertEqual(store().get(other), .unreadable, "an entry of the wrong shape")
        defaults.set(["pins": "a", "keys": "b"], forKey: "note_kept_web_trust.\(other)")
        XCTAssertEqual(store().get(other), .unreadable, "an entry with a field the page never sends")
        XCTAssertEqual(store().get("not-an-id"), .unreadable)
        XCTAssertFalse(store().keep("not-an-id", pins: "a", floors: nil, owners: nil))
    }

    @MainActor
    func testForgetTakesEverySpellingOfOneAccountAndNobodyElses() {
        let s = store()
        XCTAssertTrue(s.keep(me, pins: "mine", floors: nil, owners: nil))
        XCTAssertTrue(s.keep(other, pins: "theirs", floors: nil, owners: nil))
        defaults.set(["pins": "old"], forKey: "note_kept_web_trust.\(me.uppercased())")
        s.forget(me.replacingOccurrences(of: "-", with: ""))
        XCTAssertEqual(s.get(me), .none)
        XCTAssertNil(defaults.object(forKey: "note_kept_web_trust.\(me.uppercased())"))
        XCTAssertEqual(s.get(other), .copy(pins: "theirs", floors: nil, owners: nil))
    }

    // MARK: - The bridge's two ops

    @MainActor
    private func keys(userId: String? = "5f2b8e2a-3c1d-4e5f-9a6b-7c8d9e0f1a2b",
                      sharingKey: String? = Data(repeating: 1, count: 32).base64EncodedString(),
                      store s: KeptWebTrustStore) -> WebKeyBridge.KeySource {
        WebKeyBridge.KeySource(
            sharingPrivateKeyBase64: { sharingKey },
            signingSeedBase64: { nil },
            userId: { userId },
            previousVaultKeys: { [] },
            keptTrust: { s.get($0) },
            keepTrust: { s.keep($0, pins: $1, floors: $2, owners: $3) }
        )
    }

    @MainActor
    func testKeptTrustAnswersCopyNoneAndUnreadableNamingTheAccountInItsOneForm() async throws {
        let s = store()
        let k = keys(userId: me.uppercased(), store: s)
        let none = try await WebKeyBridge.handle(["op": "keptTrust", "v": 1, "account": me], keys: k).get()
        XCTAssertEqual(none as NSDictionary, ["v": 1, "account": me, "state": "none"] as NSDictionary)
        XCTAssertTrue(s.keep(me, pins: "P", floors: nil, owners: "O"))
        let copy = try await WebKeyBridge.handle(["op": "keptTrust", "v": 1, "account": me], keys: k).get()
        XCTAssertEqual(copy as NSDictionary,
                       ["v": 1, "account": me, "state": "copy", "pins": "P", "floors": NSNull(), "owners": "O"] as NSDictionary)
        // Asked under another spelling, the reply still names the account in its one form.
        let respelled = try await WebKeyBridge.handle(["op": "keptTrust", "v": 1, "account": me.uppercased()], keys: k).get()
        XCTAssertEqual(respelled["account"] as? String, me)
        let locked = keys(userId: me, store: store(readable: false))
        let unreadable = try await WebKeyBridge.handle(["op": "keptTrust", "v": 1, "account": me], keys: locked).get()
        XCTAssertEqual(unreadable as NSDictionary, ["v": 1, "state": "unreadable"] as NSDictionary,
                       "never 'none', and no account")
    }

    @MainActor
    func testKeepTrustKeepsStringsAndNullsForThisAccount() async throws {
        let s = store()
        let kept = try await WebKeyBridge.handle(
            ["op": "keepTrust", "v": 1, "account": me, "pins": "P", "floors": NSNull(), "owners": "O"],
            keys: keys(store: s)).get()
        XCTAssertEqual(kept as NSDictionary, ["v": 1, "state": "kept"] as NSDictionary)
        XCTAssertEqual(s.get(me), .copy(pins: "P", floors: nil, owners: "O"))
        let absent = try await WebKeyBridge.handle(["op": "keepTrust", "v": 1, "account": me, "pins": "Q"],
                                                   keys: keys(store: s)).get()
        XCTAssertEqual(absent["state"] as? String, "kept")
        XCTAssertEqual(s.get(me), .copy(pins: "Q", floors: nil, owners: nil), "an absent blob is a null")
    }

    @MainActor
    func testAnotherAccountOrNoAccountIsRefusedAndNothingOfTheirsIsGivenOrWritten() async {
        let s = store()
        XCTAssertTrue(s.keep(other, pins: "theirs", floors: nil, owners: nil))
        for account: Any in [other, "not-an-id", 7] {
            let read = await WebKeyBridge.handle(["op": "keptTrust", "v": 1, "account": account], keys: keys(store: s))
            XCTAssertEqual(read.failure, .notThisAccount, "\(account)")
            let write = await WebKeyBridge.handle(["op": "keepTrust", "v": 1, "account": account, "pins": "mine"],
                                                  keys: keys(store: s))
            XCTAssertEqual(write.failure, .notThisAccount, "\(account)")
        }
        let none = await WebKeyBridge.handle(["op": "keptTrust", "v": 1], keys: keys(store: s))
        XCTAssertEqual(none.failure, .notThisAccount)
        XCTAssertEqual(s.get(other), .copy(pins: "theirs", floors: nil, owners: nil))
        XCTAssertEqual(s.get(me), .none)
    }

    /// Why the last keep must run before `.userId` or the sharing key
    /// goes: without them the page's keep is refused.
    @MainActor
    func testSignedOutTheOpsAreRefused() async {
        let s = store()
        for k in [keys(userId: nil, store: s), keys(sharingKey: nil, store: s)] {
            let read = await WebKeyBridge.handle(["op": "keptTrust", "v": 1, "account": me], keys: k)
            XCTAssertEqual(read.failure, .signedOut)
            let write = await WebKeyBridge.handle(["op": "keepTrust", "v": 1, "account": me, "pins": "P"], keys: k)
            XCTAssertEqual(write.failure, .signedOut)
        }
        XCTAssertEqual(s.get(me), .none)
    }

    @MainActor
    func testOnlyVersionOneNonStringBlobsAndOversizeAreRefused() async {
        let s = store()
        for v: Any? in [nil, "1", 2, true] {
            var req: [String: Any] = ["op": "keptTrust", "account": me]
            if let v { req["v"] = v }
            let r = await WebKeyBridge.handle(req, keys: keys(store: s))
            XCTAssertEqual(r.failure, .invalidRequest, "v = \(String(describing: v))")
        }
        let notString = await WebKeyBridge.handle(["op": "keepTrust", "v": 1, "account": me, "floors": ["a": 1]],
                                                  keys: keys(store: s))
        XCTAssertEqual(notString.failure, .invalidRequest)
        let huge = String(repeating: "x", count: KeptWebTrustStore.maxBlobBytes + 1)
        let oversize = await WebKeyBridge.handle(["op": "keepTrust", "v": 1, "account": me, "owners": huge],
                                                 keys: keys(store: s))
        XCTAssertEqual(oversize.failure, .notKept)
        XCTAssertEqual(s.get(me), .none)
        let unknown = await WebKeyBridge.handle(["op": "exportTrust", "v": 1, "account": me], keys: keys(store: s))
        XCTAssertEqual(unknown.failure, .unknownOp)
    }

    /// The page leaves bridge mode for any marker but version 1
    /// (the web editor's keyBridge.ts), so the kept-trust ops
    /// can't come with a bump.
    @MainActor
    func testTheMarkerStaysVersionOne() throws {
        XCTAssertEqual(WebKeyBridge.version, 1)
        let keys = WebAppKeyHandoff.Keys(vaultKeyB64: "VkFVTFQ=", sharingPubB64: "UFVC", signPublicB64: nil)
        let script = try XCTUnwrap(WebAppKeyHandoff.buildScript(keys: keys, origin: "https://note.pingolindev.com"))
        XCTAssertTrue(script.contains("window.__pingolinKeyBridge=Object.freeze({version:1,"))
    }

    // MARK: - The last keep and the end of a session

    @MainActor
    func testTheLastKeepIsBoundedEvenWhenThePageNeverAnswers() async {
        let start = Date()
        let never = await WebShellModel.bounded(0.3) {
            try? await Task.sleep(for: .seconds(30))
            return true
        }
        XCTAssertFalse(never)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        let quick = await WebShellModel.bounded(5) { true }
        XCTAssertTrue(quick)
    }

    @MainActor
    func testWithNoPageTheLastKeepReturnsAtOnce() async {
        let start = Date()
        let kept = await WebShellModel.shared.keepTrustNow(timeout: 5)
        XCTAssertFalse(kept)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }

    @MainActor
    func testOnlyAnExpiryOrARefusalKeepsThePagesData() {
        XCTAssertTrue(AuthManager.SessionEnd.expired.keepsWebsiteData)
        XCTAssertTrue(AuthManager.SessionEnd.refused.keepsWebsiteData)
        XCTAssertFalse(AuthManager.SessionEnd.signedOut.keepsWebsiteData)
        XCTAssertFalse(AuthManager.SessionEnd.erased.keepsWebsiteData)
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// The body of `func <name>` up to the next `\n    }\n` at its depth.
    private func body(_ text: String, _ signature: String) throws -> String {
        let start = try XCTUnwrap(text.range(of: signature), "no \(signature)")
        let rest = text[start.upperBound...]
        let end = try XCTUnwrap(rest.range(of: "\n    }\n"), "no end of \(signature)")
        return String(rest[..<end.lowerBound])
    }

    private func assertOrder(_ text: String, _ marks: [String], _ what: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        var at = text.startIndex
        for mark in marks {
            guard let r = text.range(of: mark, range: at..<text.endIndex) else {
                return XCTFail("\(what): \(mark) missing or out of order", file: file, line: line)
            }
            at = r.upperBound
        }
    }

    /// Each last keep runs while the bridge still answers the
    /// outgoing account — before `.userId` or the sharing key goes.
    @MainActor
    func testTheOrderOfEveryEndOfASession() throws {
        let auth = try source("App/Managers/AuthManager.swift")
        let logout = try body(auth, "func logout(ending: SessionEnd = .signedOut) async {")
        assertOrder(logout, ["sessionEnd = ending",
                             "if ending == .signedOut { await lastWebKeep() }",
                             "await SyncService.shared.pushPendingChanges()",
                             "await switchAccountCleanup()",
                             "keychain.deleteAll()",
                             "isAuthenticated = false"], "logout")

        let expire = try body(auth, "private func expireSession() {")
        assertOrder(expire, ["sessionEnd = .expired", "isAuthenticated = false"], "expireSession")
        XCTAssertFalse(expire.contains("delete(key: .userId"), "an expiry keeps .userId for the last keep")
        XCTAssertFalse(expire.contains("delete(key: .sharingPrivateKey"), "and the sharing key")
        XCTAssertFalse(expire.contains("deleteAll"))
        XCTAssertFalse(expire.contains("switchAccountCleanup"))

        let refused = try body(auth, "private func failPartialLogin() {")
        assertOrder(refused, ["sessionEnd = .refused", "isAuthenticated = false"], "failPartialLogin")

        let erase = try body(auth, "func deleteAccount(")
        assertOrder(erase, ["let erased = keychain.getString(for: .userId)",
                            "await logout(ending: .erased)",
                            "if let erased { KeptWebTrustStore.shared.forget(erased) }"], "deleteAccount")

        assertOrder(auth, ["if step == .switchThenSave {",
                           "await switchAccountCleanup()",
                           "\n            await WebShellDataStore.wipeAsync()\n",
                           "try keychain.save(id, for: .userId)",
                           "        isAuthenticated = true\n"], "the switch")

        let shell = try source("App/Views/WebShellView.swift")
        let end = try body(shell, "func endSession(keepData: Bool) async {")
        assertOrder(end, ["if keepData { _ = await keepTrustNow() }", "teardown(keepData: keepData)"], "endSession")
        assertOrder(shell, ["await authManager.logout()", "WebShellModel.shared.teardown(keepData: false)"], "the shell's sign-out")
        let teardown = try body(shell, "func teardown(keepData: Bool = false) {")
        XCTAssertTrue(teardown.contains("if !keepData { WebShellDataStore.wipe() }"))

        let root = try source("App/Views/RootView.swift")
        assertOrder(root, ["let keepData = authManager.sessionEnd.keepsWebsiteData",
                           "await WebShellModel.shared.endSession(keepData: keepData)"], "RootView")
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let f) = self { return f }
        return nil
    }
}
