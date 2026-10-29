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

/// Single SDK-backed `CryptoManager` instance. The same Rust mobile SDK the
/// Track iOS app uses, exposed via uniffi.
///
/// A `KeyStorageCallback` is registered so the SDK auto-persists the imported
/// X25519 sharing key + Ed25519 signing seed and reloads them on cold start
/// (`loadPersistedKeys`); without it the signing key would vanish on every
/// relaunch. The vault key + per-item content keys still live in
/// `KeychainService`; those never touch the SDK's stored bundle.
enum SDKCrypto {
    static let cryptoManager: PingolinNoteSDK.CryptoManager = {
        let manager = PingolinNoteSDK.CryptoManager()
        manager.registerSecureStorage(storage: KeychainKeyStorageCallback())
        prepare(manager)
        return manager
    }()

    /// A wipe a sign-out couldn't finish is paid before anything is loaded.
    /// While it stays owed nothing is loaded (the SDK refuses to anyway), and
    /// the store waits for the next clear: the next sign-in's. `load` is a
    /// seam for tests.
    static func prepare(
        _ manager: PingolinNoteSDK.CryptoManager,
        _ defaults: UserDefaults = .standard,
        load: (PingolinNoteSDK.CryptoManager) -> Void = SDKCrypto.load
    ) {
        if OwedWipe.isOwed(defaults), !OwedWipe.clear(manager, defaults) { return }
        load(manager)
    }

    /// Loads the stored keys. A load that fails is not handled here: what it
    /// found is `keyStoreStatus()`, which `KeyStoreRecovery` acts on.
    static func load(_ manager: PingolinNoteSDK.CryptoManager) {
        do {
            _ = try manager.loadPersistedKeys()
        } catch {
            #if DEBUG
            print("[Note] Failed to load persisted SDK keys: \(manager.keyStoreStatus().load)")
            #endif
        }
    }
}

/// A wipe of the SDK's key store that the platform refused (the SDK's
/// `deleteFailed`): a sign-out cleared the keys in memory, but the
/// previous account's entries may still be on disk. It is owed until a
/// `clearAllKeys()` leaves the store `.loaded` (known, and empty). Until then
/// the SDK loads and writes nothing, so no later account's store exists for
/// the owed wipe to delete. Kept in UserDefaults, not the Keychain whose
/// delete just failed; it names nothing but the debt.
enum OwedWipe {
    static let defaultsKey = "sdk.keyStore.wipeOwed"

    static func isOwed(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: defaultsKey)
    }

    /// `clearAllKeys()`, and whether the store is empty after it. EVERY clear
    /// goes through here, so a refused delete is always recorded, and a clear
    /// that went through pays what was owed.
    @discardableResult
    static func clear(_ manager: PingolinNoteSDK.CryptoManager, _ defaults: UserDefaults = .standard) -> Bool {
        manager.clearAllKeys()
        return note(manager.keyStoreStatus().load, defaults)
    }

    @discardableResult
    static func note(_ load: KeyStoreLoad, _ defaults: UserDefaults = .standard) -> Bool {
        switch load {
        case .loaded:
            defaults.removeObject(forKey: defaultsKey)
            return true
        case .deleteFailed:
            defaults.set(true, forKey: defaultsKey)
            return false
        case .notLoaded, .nothingStored, .readFailed, .doesNotDecode:
            return false
        }
    }
}
