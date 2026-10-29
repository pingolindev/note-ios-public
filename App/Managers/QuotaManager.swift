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

/// Single source of truth for the user's subscription tier + usage.
/// Observers of `quota` re-render when a refresh lands; pre-action gates
/// consult `sharingEnabled` / `remindersEnabled` synchronously.
///
/// The server is still the authority — this cache is a hint so the UI
/// doesn't have to discover gates by bouncing off a 402. It's
/// refresh-on-demand rather than long-lived: on login, on app
/// foreground, after a purchase, and after any 402 the networking layer
/// catches. Cleared on sign-out so a stale "paid" can't leak across user
/// switches.
///
/// Mirrors note-android QuotaManager.
@MainActor
final class QuotaManager: ObservableObject {
    static let shared = QuotaManager()

    /// Latest known quota, or `nil` if we've never fetched (signed out,
    /// or first launch before the first refresh lands). Callers treat
    /// `nil` as "assume free" for gating — same as the server's fallback
    /// when auth is unreachable.
    @Published private(set) var quota: QuotaDto?

    private let api = APIService.shared
    private let keychain = KeychainService.shared
    private var inFlight = false

    private init() {}

    static let tierPaid = "paid"

    /// `true` when the active tier grants premium gates. `nil` quota
    /// (never fetched / signed out) reads as free.
    var isPaid: Bool { quota?.tier == Self.tierPaid }

    /// Gating helpers. A `nil` quota is treated as gated (free) so the
    /// UI fails safe to the explainer rather than letting an action
    /// round-trip into a 402 before the first refresh lands.
    var sharingEnabled: Bool { quota?.sharingEnabled ?? false }
    var remindersEnabled: Bool { quota?.remindersEnabled ?? false }

    /// Fire-and-forget refresh. Safe to call from any view lifecycle.
    /// Concurrent callers collapse to a single round-trip.
    func refresh() {
        Task { await refreshNow() }
    }

    /// Suspending variant for callers that want the latest tier before
    /// deciding how to surface something.
    func refreshNow() async {
        guard keychain.getString(for: .accessToken) != nil else {
            quota = nil
            return
        }
        if inFlight { return }
        inFlight = true
        defer { inFlight = false }
        do {
            quota = try await api.getQuota()
        } catch {
            // 401 gets sorted out by the refresh path on the next
            // request; quota stays stale meanwhile. Transient network
            // errors: keep the last-known value rather than clearing.
            #if DEBUG
            print("[Note] quota refresh failed: \(error)")
            #endif
        }
    }

    /// Drop cached state on sign-out so the next login starts clean.
    func clear() {
        quota = nil
    }
}
