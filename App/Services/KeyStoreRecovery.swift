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

/// What this app does with the state of the SDK's key store.
///
/// Note's own notes never go through that store: the vault key and the seed
/// that signs share wraps live in `KeychainService` (NoteCrypto, WebKeyBridge).
/// The SDK holds the account's private key there for one thing, opening the
/// identities recovered from before a password reset
/// (`importPreviousIdentities`). So a store that fails to load never signs
/// anybody out, and the app stays usable:
/// - it doesn't decode: a notice once per launch, `syncNoticeText`, whose
///   Sign Out opens the usual Logout confirmation. The next explicit sign-in
///   clears the store, and the sign-in's import writes it whole.
/// - the platform couldn't read it: nothing is shown. It is loaded again once
///   the device is unlocked, and never cleared.
/// - a signing seed or entries that didn't read are kept as stored: logged.
///   Note signs nothing with the SDK's seed and keeps no circle state; the
///   next sign-in's import replaces the seed and drops the entries.
/// - a wipe a sign-out couldn't finish (`OwedWipe`) is paid first at the next
///   sign-in; while it stays owed, that sign-in's keys stay in memory.
@MainActor
final class KeyStoreRecovery: ObservableObject {
    static let shared = KeyStoreRecovery()

    /// The notice for a store that doesn't decode.
    nonisolated static let syncNoticeText = "Sync error. Please sign in again."

    /// The SDK's calls, behind a seam for tests.
    struct Store {
        var status: () -> KeyStoreStatus
        var load: () -> Void
        /// Through `OwedWipe`, so a refused delete is always recorded.
        var clear: () -> Void
        var dropUnreadableEntries: () throws -> Void
        var wipeOwed: () -> Bool

        static let sdk = Store(
            status: { SDKCrypto.cryptoManager.keyStoreStatus() },
            load: { SDKCrypto.load(SDKCrypto.cryptoManager) },
            clear: { _ = OwedWipe.clear(SDKCrypto.cryptoManager) },
            dropUnreadableEntries: { _ = try SDKCrypto.cryptoManager.dropUnreadableEntries() },
            wipeOwed: { OwedWipe.isOwed() }
        )
    }

    var store: Store = .sdk
    /// Returns once the device is unlocked (no time limit: this load is made
    /// once, after the unlock).
    var waitUntilUnlocked: @MainActor () async -> Void = { _ = await ProtectedData.waitUntilAvailable(atMost: nil) }

    /// The notice is up. Shown by WebShellView once the page has painted.
    @Published var showsSyncNotice = false
    private var noticeGivenThisLaunch = false
    private var loadAgainPending = false

    init() {}

    /// A session restored at launch (`AuthManager.checkExistingSession`). The
    /// first `status()` is what loads the store (`SDKCrypto.cryptoManager`).
    func atLaunch() {
        let status = store.status()
        switch status.load {
        case .doesNotDecode:
            giveTheNotice()
        case .readFailed:
            loadAgainWhenUnlocked()
        case .notLoaded, .nothingStored, .loaded, .deleteFailed:
            // deleteFailed: a wipe still owed, paid at the next sign-in.
            break
        }
        #if DEBUG
        if status.signingSeedUnreadable || status.entriesUnreadable {
            print("[Note] SDK key store keeps what didn't read: seed \(status.signingSeedUnreadable), entries \(status.entriesUnreadable)")
        }
        #endif
    }

    private func giveTheNotice() {
        guard !noticeGivenThisLaunch else { return }
        noticeGivenThisLaunch = true
        showsSyncNotice = true
    }

    /// One load after the unlock. A store that then reads but doesn't decode
    /// gets its notice; one that still can't be read waits for the next launch.
    private func loadAgainWhenUnlocked() {
        guard !loadAgainPending else { return }
        loadAgainPending = true
        Task { @MainActor in
            await waitUntilUnlocked()
            store.load()
            if store.status().load == .doesNotDecode { giveTheNotice() }
        }
    }

    /// An explicit sign-in, before the account's keys are imported into the
    /// SDK (`AuthManager.storeSignInKeys`). The store is loaded again.
    /// One that still doesn't decode is cleared, so the import writes it
    /// whole. Entries that didn't read are dropped. One the platform couldn't
    /// read is never cleared: the import then stays in memory. A wipe a
    /// sign-out couldn't finish is paid first; while it stays owed, nothing is
    /// loaded or written (the SDK refuses both) and the import stays in memory.
    func beforeSignInImport() {
        if store.wipeOwed() {
            store.clear()
            guard store.status().load == .loaded else { return }
        }
        store.load()
        let status = store.status()
        switch status.load {
        case .doesNotDecode:
            store.clear()
        case .readFailed, .deleteFailed:
            break
        case .notLoaded, .nothingStored, .loaded:
            if status.entriesUnreadable {
                do {
                    try store.dropUnreadableEntries()
                } catch {
                    #if DEBUG
                    print("[Note] SDK key store: dropping the entries that didn't read failed")
                    #endif
                }
            }
        }
        switch store.status().load {
        case .loaded, .nothingStored: showsSyncNotice = false
        case .notLoaded, .readFailed, .doesNotDecode, .deleteFailed: break
        }
    }
}
