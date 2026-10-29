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
import WebKit

/// Where the web shell keeps what the page stores — and keeping it out of
/// backups.
///
/// The Note web editor caches every note as decrypted plaintext in IndexedDB
/// (a documented trade-off, its `noteDb.ts`) and queues edits there until the
/// server confirms them. All of it lives under `Library/`, which iOS includes
/// in iCloud and Finder backups unless an app says otherwise — while the rest
/// of this app keeps plaintext and bearer tokens out of backups with
/// `…ThisDeviceOnly` Keychain items and `isExcludedFromBackup`
/// (SharedAppGroup). A backup is readable by Apple without Advanced Data
/// Protection, and restorable onto another phone by whoever holds the Apple
/// ID.
///
/// So:
///  - WebKit's data directories under `Library/` are marked
///    `isExcludedFromBackup` before any WebView exists, on every launch (the
///    attribute lives on the directory, so one WebKit recreates gets it again
///    next launch);
///  - the page stays on the DEFAULT store, which lives entirely inside those
///    directories. It is not moved or cleared on update: an edit made offline
///    exists only in that store's IndexedDB until it syncs, and moving the
///    page to another store and clearing the default one would delete such
///    edits outright;
///  - the shell puts no refresh token in any WebKit cookie (see
///    `WebShellModel.seedCookies`), and the key handoff sweeps the one key an
///    earlier page could have left in the store (`WebAppKeyHandoff`).
enum WebShellDataStore {
    /// Written only by earlier builds that used a dedicated store. Read so an
    /// install that ran one keeps that store — and whatever unsynced edits it
    /// holds — until its next sign-out.
    static let dedicatedIdentifierKey = "webShell.dataStoreIdentifier"

    /// Directories under `Library/` that WebKit (and CFNetwork's cookie
    /// storage) write to. On iOS 26 the default store keeps its IndexedDB
    /// and LocalStorage under `Library/WebKit/<bundle-id>/WebsiteData/`,
    /// its cookies in `Library/Cookies/Cookies.binarycookies`, and HSTS
    /// and the like in `Library/HTTPStorages`; an earlier build's
    /// dedicated store is one directory,
    /// `Library/WebKit/<bundle-id>/WebsiteDataStore/<id>/`.
    /// `Library/Caches` is never backed up.
    static let backupExcludedLibraryPaths = ["WebKit", "Cookies", "HTTPStorages"]

    /// The shell's store: the default store, or the dedicated one on an install
    /// that ran an earlier build with a dedicated store and has not signed out
    /// since.
    @MainActor
    static func store(defaults: UserDefaults = .standard) -> WKWebsiteDataStore {
        if let id = dedicatedIdentifier(defaults) {
            return WKWebsiteDataStore(forIdentifier: id)
        }
        return .default()
    }

    static func dedicatedIdentifier(_ defaults: UserDefaults = .standard) -> UUID? {
        defaults.string(forKey: dedicatedIdentifierKey).flatMap(UUID.init(uuidString:))
    }

    /// Run at launch, before any WebView exists.
    @MainActor
    static func prepareAtLaunch() {
        excludeWebKitDataFromBackup()
    }

    /// Mark WebKit's data directories excluded from backup, creating them when
    /// absent so the attribute is in place before WebKit writes the first byte.
    @discardableResult
    static func excludeWebKitDataFromBackup(
        library: URL? = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
    ) -> [URL] {
        guard let library else { return [] }
        var marked: [URL] = []
        for name in backupExcludedLibraryPaths {
            var dir = library.appendingPathComponent(name, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try dir.setResourceValues(values)
                marked.append(dir)
            } catch {
                #if DEBUG
                print("[Note] could not exclude \(name) from backup: \(error)")
                #endif
            }
        }
        return marked
    }

    /// End of a session: the store holds decrypted note content, so it is
    /// emptied. An install still on an earlier build's dedicated store
    /// empties that too and goes back to the default store here, where
    /// there is nothing left to strand.
    @MainActor
    static func wipe(defaults: UserDefaults = .standard, completion: @escaping () -> Void = {}) {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let dedicated = leaveDedicatedStore(defaults)
        WKWebsiteDataStore.default().removeData(ofTypes: types, modifiedSince: .distantPast) {
            guard let dedicated else { return completion() }
            dedicated.removeData(ofTypes: types, modifiedSince: .distantPast, completionHandler: completion)
        }
    }

    /// `wipe`, awaited: an account switch empties the page's data before the
    /// next account's page can load.
    @MainActor
    static func wipeAsync(defaults: UserDefaults = .standard) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            wipe(defaults: defaults) { continuation.resume() }
        }
    }

    /// Stop using an earlier build's dedicated store; returns it so the
    /// caller can empty it. nil on every other install.
    @MainActor
    static func leaveDedicatedStore(_ defaults: UserDefaults = .standard) -> WKWebsiteDataStore? {
        let dedicated = dedicatedIdentifier(defaults).map { WKWebsiteDataStore(forIdentifier: $0) }
        defaults.removeObject(forKey: dedicatedIdentifierKey)
        return dedicated
    }
}
