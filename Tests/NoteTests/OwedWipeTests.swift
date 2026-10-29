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

/// A wipe of the SDK's key store that the platform refused at a sign-out is
/// owed, and paid before anything is loaded (the SDK's deleteFailed).
/// Against the real SDK, with a key store whose delete can be made to fail.
final class OwedWipeTests: XCTestCase {
    private let suite = "OwedWipeTests"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private final class Store: KeyStorageCallback, @unchecked Sendable {
        var deleteFails = false
        var log: [String] = []
        func storeKeys(data: StoredKeyData) throws { log.append("store") }
        func loadKeys() throws -> StoredKeyData? { log.append("load"); return nil }
        func deleteKeys() throws {
            log.append("delete")
            if deleteFails { throw StorageCallbackError.Failed }
        }
    }

    private func manager(_ store: Store) -> CryptoManager {
        let manager = CryptoManager()
        manager.registerSecureStorage(storage: store)
        return manager
    }

    func testARefusedDeleteIsOwed() {
        let store = Store()
        store.deleteFails = true
        let manager = manager(store)
        XCTAssertFalse(OwedWipe.clear(manager, defaults))
        XCTAssertEqual(manager.keyStoreStatus().load, .deleteFailed)
        XCTAssertTrue(OwedWipe.isOwed(defaults))
    }

    func testAClearThatGoesThroughPaysIt() {
        defaults.set(true, forKey: OwedWipe.defaultsKey)
        let manager = manager(Store())
        XCTAssertTrue(OwedWipe.clear(manager, defaults))
        XCTAssertEqual(manager.keyStoreStatus().load, .loaded)
        XCTAssertFalse(OwedWipe.isOwed(defaults))
    }

    func testAnOwedWipeIsPaidBeforeTheLoad() {
        defaults.set(true, forKey: OwedWipe.defaultsKey)
        let store = Store()
        SDKCrypto.prepare(manager(store), defaults)
        XCTAssertEqual(store.log, ["delete", "load"])
        XCTAssertFalse(OwedWipe.isOwed(defaults))
    }

    func testAWipeStillOwedLoadsNothing() {
        defaults.set(true, forKey: OwedWipe.defaultsKey)
        let store = Store()
        store.deleteFails = true
        let manager = manager(store)
        var appLoads = 0
        SDKCrypto.prepare(manager, defaults, load: { _ in appLoads += 1 })
        // The app doesn't even ask: the SDK would refuse a load while
        // .deleteFailed, but that refusal is not what this rule rests on.
        XCTAssertEqual(appLoads, 0)
        XCTAssertEqual(store.log, ["delete"], "the previous account's entries are never loaded")
        XCTAssertTrue(OwedWipe.isOwed(defaults))
        XCTAssertEqual(manager.keyStoreStatus().load, .deleteFailed)
    }

    func testNothingOwedJustLoads() {
        let store = Store()
        SDKCrypto.prepare(manager(store), defaults)
        XCTAssertEqual(store.log, ["load"])
    }

    /// Every clear in the app goes through OwedWipe, so a refused delete is
    /// always recorded: the sign-out's and the recovery's.
    func testEveryClearGoesThroughOwedWipe() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let app = root.appendingPathComponent("App")
        guard let walk = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil) else {
            return XCTFail("no App directory")
        }
        var callers: [String] = []
        for case let file as URL in walk where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.components(separatedBy: "\n") where line.contains("clearAllKeys()") {
                let code = line.trimmingCharacters(in: .whitespaces)
                if code.hasPrefix("//") { continue }
                callers.append("\(file.lastPathComponent): \(code)")
            }
        }
        XCTAssertEqual(callers, ["SDKCrypto.swift: manager.clearAllKeys()"])
        let auth = try String(contentsOf: app.appendingPathComponent("Managers/AuthManager.swift"), encoding: .utf8)
        XCTAssertTrue(auth.contains("OwedWipe.clear(SDKCrypto.cryptoManager)"), "the sign-out's clear")
        let recovery = try String(contentsOf: app.appendingPathComponent("Services/KeyStoreRecovery.swift"), encoding: .utf8)
        XCTAssertTrue(recovery.contains("clear: { _ = OwedWipe.clear(SDKCrypto.cryptoManager) }"), "the recovery's clear")
    }
}
