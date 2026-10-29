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
import Network

/// Watches connectivity and kicks off an expedited `SyncService.sync()` the
/// moment the device comes back online — so a note created / edited offline
/// doesn't wait for the next foreground or launch to drain the outbox.
///
/// The iOS analog of note-android's `util/ConnectivityMonitor.kt`
/// (`onAvailable` → `SyncWorker.enqueueImmediateSync`). Uses
/// `NWPathMonitor`. Start it once from `NoteApp` (`.task`); the monitor
/// runs for the process lifetime.
@MainActor
final class ConnectivityMonitor: ObservableObject {
    static let shared = ConnectivityMonitor()
    private init() {}

    @Published private(set) var isOnline = false

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.pingolin.note.connectivity")
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                let wasOnline = self.isOnline
                self.isOnline = satisfied
                // Expedited flush on a regain (offline → online). Gated on an
                // authenticated session; the sync itself coalesces with any
                // launch / foreground sync already running (SyncService.isSyncing).
                if satisfied, !wasOnline, AuthManager.shared.isAuthenticated {
                    await SyncService.shared.sync()
                }
            }
        }
        monitor.start(queue: queue)
    }
}
