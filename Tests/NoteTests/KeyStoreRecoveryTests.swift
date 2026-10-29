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

/// What the app does with the SDK key store's state. Note's own notes never
/// go through that store, so a store that fails to load never signs
/// anybody out:
/// - it doesn't decode → a notice once per launch; the next explicit
///   sign-in loads it again and, if it still doesn't decode, clears it
///   before the account's keys are imported;
/// - the platform couldn't read it → no notice, one load after the unlock,
///   never cleared.
@MainActor
final class KeyStoreRecoveryTests: XCTestCase {

    /// The SDK as the recovery sees it: a status that the calls change the way
    /// the SDK's do, and a log of the calls.
    private final class FakeStore {
        var load: KeyStoreLoad
        var afterLoad: KeyStoreLoad?
        var seedUnreadable = false
        var entriesUnreadable = false
        var dropFails = false
        var owed = false
        var clearFails = false
        var calls: [String] = []

        init(_ load: KeyStoreLoad, afterLoad: KeyStoreLoad? = nil) {
            self.load = load
            self.afterLoad = afterLoad
        }

        var store: KeyStoreRecovery.Store {
            KeyStoreRecovery.Store(
                status: { [unowned self] in
                    KeyStoreStatus(load: load, signingSeedUnreadable: seedUnreadable, entriesUnreadable: entriesUnreadable)
                },
                load: { [unowned self] in
                    calls.append("load")
                    if let afterLoad { load = afterLoad }
                },
                clear: { [unowned self] in
                    calls.append("clear")
                    if clearFails {
                        load = .deleteFailed
                        owed = true
                    } else {
                        load = .loaded
                        owed = false
                    }
                    entriesUnreadable = false
                },
                dropUnreadableEntries: { [unowned self] in
                    calls.append("drop")
                    if dropFails { throw MobileError.StorageError(message: "the key store can't be read") }
                    entriesUnreadable = false
                },
                wipeOwed: { [unowned self] in owed }
            )
        }
    }

    private func recovery(_ fake: FakeStore, waits: (() async -> Void)? = nil) -> KeyStoreRecovery {
        let recovery = KeyStoreRecovery()
        recovery.store = fake.store
        recovery.waitUntilUnlocked = waits ?? {}
        return recovery
    }

    /// Lets the recovery's own task run.
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    // MARK: - At launch

    func testAStoreThatDoesNotDecodeGetsTheNoticeAndNothingElse() async {
        let fake = FakeStore(.doesNotDecode)
        let recovery = recovery(fake)
        recovery.atLaunch()
        await settle()
        XCTAssertTrue(recovery.showsSyncNotice)
        XCTAssertEqual(fake.calls, [], "nothing is cleared or loaded again at launch; only a sign-in clears")
    }

    func testTheNoticeIsGivenOncePerLaunch() {
        let fake = FakeStore(.doesNotDecode)
        let recovery = recovery(fake)
        recovery.atLaunch()
        recovery.showsSyncNotice = false  // dismissed
        recovery.atLaunch()
        XCTAssertFalse(recovery.showsSyncNotice)
    }

    func testAStoreThePlatformCouldNotReadIsLoadedOnceAfterTheUnlock() async {
        let fake = FakeStore(.readFailed, afterLoad: .loaded)
        var waits = 0
        let recovery = recovery(fake, waits: { waits += 1 })
        recovery.atLaunch()
        recovery.atLaunch()
        await settle()
        XCTAssertEqual(waits, 1)
        XCTAssertEqual(fake.calls, ["load"], "one load, and never a clear")
        XCTAssertFalse(recovery.showsSyncNotice)
    }

    func testAStoreThatReadsAfterTheUnlockButDoesNotDecodeGetsTheNotice() async {
        let fake = FakeStore(.readFailed, afterLoad: .doesNotDecode)
        let recovery = recovery(fake)
        recovery.atLaunch()
        XCTAssertFalse(recovery.showsSyncNotice)
        await settle()
        XCTAssertTrue(recovery.showsSyncNotice)
        XCTAssertEqual(fake.calls, ["load"])
    }

    func testTheLoadWaitsForTheUnlock() async {
        let fake = FakeStore(.readFailed, afterLoad: .loaded)
        let unlocked = AsyncStream<Void>.makeStream()
        let recovery = recovery(fake, waits: { for await _ in unlocked.stream { return } })
        recovery.atLaunch()
        await settle()
        XCTAssertEqual(fake.calls, [], "not before the unlock")
        unlocked.continuation.yield()
        await settle()
        XCTAssertEqual(fake.calls, ["load"])
    }

    func testAnythingElseAtLaunchDoesNothing() async {
        for load in [KeyStoreLoad.loaded, .nothingStored, .notLoaded, .deleteFailed] {
            let fake = FakeStore(load)
            fake.seedUnreadable = true
            fake.entriesUnreadable = true
            let recovery = recovery(fake)
            recovery.atLaunch()
            await settle()
            XCTAssertFalse(recovery.showsSyncNotice, "\(load)")
            XCTAssertEqual(fake.calls, [], "\(load)")
        }
    }

    // MARK: - At an explicit sign-in

    func testASignInClearsAStoreThatStillDoesNotDecode() {
        let fake = FakeStore(.doesNotDecode)
        let recovery = recovery(fake)
        recovery.atLaunch()
        recovery.beforeSignInImport()
        XCTAssertEqual(fake.calls, ["load", "clear"], "loaded again first, cleared only then")
        XCTAssertFalse(recovery.showsSyncNotice, "cleared: the notice goes")
    }

    func testASignInKeepsAStoreThatDecodesAfterTheReload() {
        let fake = FakeStore(.doesNotDecode, afterLoad: .loaded)
        let recovery = recovery(fake)
        recovery.beforeSignInImport()
        XCTAssertEqual(fake.calls, ["load"])
    }

    func testASignInNeverClearsAStoreThePlatformCouldNotRead() {
        let fake = FakeStore(.readFailed)
        fake.entriesUnreadable = true
        let recovery = recovery(fake)
        recovery.beforeSignInImport()
        XCTAssertEqual(fake.calls, ["load"], "no clear and no drop: nothing was read")
    }

    func testASignInDropsTheEntriesThatDidNotRead() {
        let fake = FakeStore(.loaded)
        fake.entriesUnreadable = true
        let recovery = recovery(fake)
        recovery.beforeSignInImport()
        XCTAssertEqual(fake.calls, ["load", "drop"])
    }

    func testADropThatFailsDoesNotStopTheSignIn() {
        let fake = FakeStore(.loaded)
        fake.entriesUnreadable = true
        fake.dropFails = true
        let recovery = recovery(fake)
        recovery.beforeSignInImport()
        XCTAssertEqual(fake.calls, ["load", "drop"])
    }

    func testASignInWithAHealthyStoreOnlyLoadsIt() {
        for load in [KeyStoreLoad.loaded, .nothingStored] {
            let fake = FakeStore(load)
            let recovery = recovery(fake)
            recovery.beforeSignInImport()
            XCTAssertEqual(fake.calls, ["load"], "\(load)")
        }
    }

    // MARK: - A wipe a sign-out couldn't finish (the SDK's deleteFailed)

    func testASignInPaysAnOwedWipeFirst() {
        let fake = FakeStore(.deleteFailed)
        fake.owed = true
        let recovery = recovery(fake)
        recovery.beforeSignInImport()
        XCTAssertEqual(fake.calls, ["clear", "load"], "paid before anything is loaded")
        XCTAssertFalse(fake.owed)
    }

    func testASignInWithAWipeStillOwedLoadsNothing() {
        let fake = FakeStore(.deleteFailed)
        fake.owed = true
        fake.clearFails = true
        let recovery = recovery(fake)
        recovery.beforeSignInImport()
        XCTAssertEqual(fake.calls, ["clear"], "nothing loaded; the sign-in's keys stay in memory")
        XCTAssertTrue(fake.owed)
    }

    func testARecoveryClearThatIsRefusedStaysOwed() {
        let fake = FakeStore(.doesNotDecode)
        fake.clearFails = true
        let recovery = recovery(fake)
        recovery.beforeSignInImport()
        XCTAssertEqual(fake.calls, ["load", "clear"])
        XCTAssertTrue(fake.owed)
    }

    // MARK: - Where the app calls it

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func body(of source: String, from start: String, to end: String) throws -> String {
        let s = try XCTUnwrap(source.range(of: start), start)
        let e = try XCTUnwrap(source.range(of: end, range: s.upperBound..<source.endIndex), end)
        return String(source[s.upperBound..<e.lowerBound])
    }

    /// The sign-in recovers the store BEFORE the account's keys go into the
    /// SDK, and the launch acts on a restored session, never signing it out.
    func testTheAppCallsItBeforeTheImportsAndAtLaunch() throws {
        let auth = try source("App/Managers/AuthManager.swift")
        let derive = try body(of: auth, from: "private func storeSignInKeys(", to: "enum VaultDerivationError")
        let recover = try XCTUnwrap(derive.range(of: "KeyStoreRecovery.shared.beforeSignInImport()"))
        let importKey = try XCTUnwrap(derive.range(of: "importPrivateKey("))
        let importSeed = try XCTUnwrap(derive.range(of: "importSigningPrivateKey("))
        XCTAssertLessThan(recover.lowerBound, importKey.lowerBound)
        XCTAssertLessThan(recover.lowerBound, importSeed.lowerBound)

        let launch = try body(of: auth, from: "func checkExistingSession() async {", to: "static func storedAccessToken(")
        let atLaunch = try XCTUnwrap(launch.range(of: "KeyStoreRecovery.shared.atLaunch()"))
        let restore = try XCTUnwrap(launch.range(of: "case .restore:"))
        XCTAssertLessThan(restore.lowerBound, atLaunch.lowerBound)

        let recovery = try source("App/Services/KeyStoreRecovery.swift")
        XCTAssertFalse(recovery.contains("AuthManager.shared"), "the recovery never touches the session")
        XCTAssertFalse(recovery.contains("expireSession"))
    }

    func testTheNoticeOffersTheUsualSignOut() throws {
        let shell = try source("App/Views/WebShellView.swift")
        let alert = try body(of: shell, from: "KeyStoreRecovery.syncNoticeText,", to: "if model.loadFailed {")
        XCTAssertTrue(alert.contains("model.pageReady || model.loadFailed"), "never over the splash")
        XCTAssertTrue(alert.contains("Button(\"Sign Out\", role: .destructive)"))
        XCTAssertTrue(alert.contains("model.showSignOutConfirm = true"), "the usual Logout confirmation")
        XCTAssertTrue(alert.contains("Button(\"OK\", role: .cancel)"))
    }
}
