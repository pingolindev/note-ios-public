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
import UIKit
import os

/// The app's own pass of the finisher (`InvitationFinisher`): after a silent
/// `sync` push, with what is left of the push's time, and for a
/// `finish_shares` alert that reaches the running app. The same rules and the
/// same stores as the notification extension's run (`BackgroundFinish`); what
/// the app adds is its own copy of the notes, so a note this device keeps in a
/// notebook is left to the page too, and the earlier vault keys it already
/// holds (`PreviousIdentityLoader`).
///
/// One pass at a time in this process, and one across this process and the
/// extension (`AppGroupLock.finish()`). The pass holds a lock in the app
/// group, so it runs inside a background task: iOS must not suspend the app
/// while it holds one.
@MainActor
enum InAppFinisher {
    private static let log = Logger(subsystem: "com.pingolin.note", category: "finish")

    /// No pass starts with less than this left before its deadline.
    static let minimumTime: TimeInterval = 6

    private static var running = false

    /// One pass, if there is time for one and nothing else is running it.
    @discardableResult
    static func run(until deadline: Date) async -> InvitationFinisher.Report? {
        guard !running, AuthManager.shared.isAuthenticated, deadline.timeIntervalSinceNow >= minimumTime else {
            return nil
        }
        running = true
        defer { running = false }
        let task = UIApplication.shared.beginBackgroundTask(withName: "finish-invitations")
        defer { if task != .invalid { UIApplication.shared.endBackgroundTask(task) } }

        let keychain = KeychainService.shared
        guard let me = CanonicalId.of(keychain.getString(for: .userId)) else { return nil }
        // A token good for the whole pass, from the app's own refresh (which
        // holds the refresh lock the extension takes too).
        guard await APIService.shared.refreshAccessTokenIfExpiring(within: 60) == .refreshed,
              let token = keychain.getString(for: .accessToken),
              let claims = TokenClaims(token), CanonicalId.of(claims.subject) == me
        else { return nil }
        let earlier: () async -> [Data] = {
            let loader = PreviousIdentityLoader.shared
            if !loader.isLoaded {
                let wait = max(0, min(8, deadline.timeIntervalSinceNow - 3))
                await PushNotificationManager.run({ _ = await loader.ensureLoaded() }, waitingAtMost: wait)
            }
            return loader.vaultKeys().compactMap { Data(base64Encoded: $0) }.filter { $0.count == 32 }
        }
        guard let material = InvitationFinisher.material(me: me, keychain: { keychain.read($0) },
                                                         previousVaultKeys: earlier),
              let files = FinisherFiles.appGroup(),
              let lock = AppGroupLock.finish(),
              let held = await lock.acquire(timeout: 1)
        else { return nil }
        defer { held.release() }

        let config = AppConfiguration.shared
        let report = await InvitationFinisher.pass(
            InvitationFinisher.Session(account: me, apiBase: config.apiBaseURL, token: token, material: material,
                                       userAgent: config.userAgent,
                                       // A sign-out or another account's sign-in meanwhile stops the pass.
                                       stillSignedIn: { CanonicalId.of(KeychainService.shared.getString(for: .userId)) == me }),
            stores: InvitationFinisher.Stores(
                keptPins: { KeptPinsMirror.read($0, in: files) },
                seals: SealStore(files: files, lock: AppGroupLock.seals()),
                tried: TriedStore(files: files)),
            localNotebookOf: { NoteStore.shared.fetchById($0)?.notebookId },
            transport: URLSessionFinisherTransport(), deadline: deadline, now: Date.init)
        log.info("finish: \(InvitationFinisher.summary(report), privacy: .public)")
        return report
    }

    /// One pass after the silent push's sync: with what is left of the push's
    /// time, of which the caller waits `seconds` from `start` in all.
    static func runAfterSync(startedAt start: Date, seconds: TimeInterval) async {
        let deadline = start.addingTimeInterval(seconds)
        let left = deadline.timeIntervalSinceNow
        guard left >= minimumTime else { return }
        await PushNotificationManager.run({ _ = await run(until: deadline) }, waitingAtMost: left)
    }
}
