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
import os
#if NOTE_TESTS
// The unit tests compile this file too, and reach the rules it shares with
// the app (`InvitationFinisher` and the stores) through the app module.
@testable import Note
#endif

/// The notification extension's run of the finisher (`InvitationFinisher`),
/// for the server's `finish_shares` alert: the owner's phone finishes the
/// shares an invitation left, even when the app was swiped away.
///
/// Who is signed in, and with what, is read afresh on every run: an extension
/// process can outlive several notifications. The account must be the same in
/// the Keychain, in the token and in what the app last mirrored to the app
/// group (`FinisherBridge`), or nothing runs. The keys are the app's Keychain
/// items (the extension shares its keychain group) and are only read; a token
/// that has run out is refreshed behind the app's own lock
/// (`ExtensionSessionRefresh`). One pass at a time, here or in the app
/// (`AppGroupLock.finish()`).
///
/// Every step checks the deadline, so the banner is never late.
enum BackgroundFinish {
    static let log = Logger(subsystem: "com.pingolin.note.NotificationExtension", category: "finish")

    /// How long the run may take before the banner is shown anyway. iOS allows
    /// a service extension about 30 seconds; no share is started in the last
    /// two (`InvitationFinisher.startMargin`).
    static let budget: TimeInterval = 20

    /// Everything a run reads from outside itself, behind one seam: live, the
    /// shared keychain, the app group and the network; in a test, scratch
    /// stores and a stub server.
    struct Environment {
        var keychain: (KeychainService.Key) -> KeychainService.Read
        var shared: () -> UserDefaults?
        var files: () -> FinisherFiles?
        var sealLock: () -> AppGroupLock?
        var passLock: () -> AppGroupLock?
        /// A refreshed token when the stored one has run out.
        var refreshedToken: (_ authBase: String?) async -> String? = { _ in nil }
        /// The vault keys of identities recovered from before a password reset.
        var previousVaultKeys: (_ token: String, _ authBase: String?, _ deadline: Date) async -> [Data] = { _, _, _ in [] }
        var transport: FinisherTransport
        var now: () -> Date

        static var live: Environment {
            Environment(
                keychain: { KeychainService.shared.read($0) },
                shared: { FinisherBridge.sharedDefaults },
                files: { FinisherFiles.appGroup() },
                sealLock: { AppGroupLock.seals() },
                passLock: { AppGroupLock.finish() },
                refreshedToken: { authBase in
                    await ExtensionSessionRefresh.token(
                        now: Date(), margin: 30, authBase: authBase, lock: AppGroupLock.refresh(),
                        transport: URLSessionFinisherTransport(), store: .keychain)
                },
                previousVaultKeys: { token, authBase, deadline in
                    await ExtensionPreviousVaultKeys.load(
                        token: token, authBase: authBase, deadline: deadline, transport: URLSessionFinisherTransport(),
                        now: Date.init, keychain: { KeychainService.shared.read($0) })
                },
                transport: URLSessionFinisherTransport(),
                now: Date.init)
        }
    }

    struct Result {
        var report = InvitationFinisher.Report()
        /// The app's notification detail level, as it last mirrored it.
        var detail: String?
        /// The app's token had run out, and a refreshed one was used.
        var refreshed = false
        /// The run's account was not the one signed in here by the time the
        /// banner went: nobody is named on it.
        var accountChanged = false
    }

    /// Whether `me` is still the account signed in here, by the Keychain's word
    /// and the app's.
    static func signedIn(as me: String, env: Environment) -> Bool {
        guard case .found(let stored) = env.keychain(.userId), CanonicalId.of(stored) == me else { return false }
        return CanonicalId.of(FinisherBridge.read(env.shared()).account) == me
    }

    static func run(deadline: Date, env: Environment) async -> Result {
        var result = Result()
        func stop(_ why: String) -> Result {
            result.report.stopped = why
            log.info("finish: nothing done: \(why, privacy: .public)")
            return result
        }
        let mirrored = FinisherBridge.read(env.shared())
        result.detail = mirrored.detail

        // Who is signed in here, in their one form: the Keychain's, the app's
        // and the token's word for it name the same account, or nothing runs.
        guard case .found(let stored) = env.keychain(.userId), let me = CanonicalId.of(stored) else {
            return stop("not signed in")
        }
        guard CanonicalId.of(mirrored.account) == me, let apiBase = mirrored.apiBase, URL(string: apiBase) != nil else {
            return stop("the app has not run since this account signed in")
        }
        guard case .found(var token) = env.keychain(.accessToken), let first = TokenClaims(token) else {
            return stop("no session")
        }
        if first.expiresAt <= env.now().addingTimeInterval(30) {
            guard let fresh = await env.refreshedToken(mirrored.authBase), TokenClaims(fresh) != nil else {
                return stop("the session token has run out")
            }
            token = fresh
            result.refreshed = true
        }
        guard let claims = TokenClaims(token), CanonicalId.of(claims.subject) == me else {
            return stop("the token is for another account")
        }

        let authBase = mirrored.authBase
        let earlier = EarlierVaultKeys { [token] in await env.previousVaultKeys(token, authBase, deadline) }
        guard let material = InvitationFinisher.material(me: me, keychain: env.keychain,
                                                         previousVaultKeys: { await earlier.value() }) else {
            return stop("the keys could not be read")
        }
        guard let files = env.files() else { return stop("no app group") }
        guard let lock = env.passLock(), let held = await lock.acquire(timeout: 1) else {
            return stop("another pass is running")
        }
        defer { held.release() }

        let stores = InvitationFinisher.Stores(
            keptPins: { KeptPinsMirror.read($0, in: files) },
            seals: SealStore(files: files, lock: env.sealLock()),
            tried: TriedStore(files: files))
        result.report = await InvitationFinisher.pass(
            InvitationFinisher.Session(account: me, apiBase: apiBase, token: token, material: material,
                                       stillSignedIn: { signedIn(as: me, env: env) }),
            stores: stores,
            // No local copy of the notes here: the server's notebook_id is all
            // there is, and a note in any notebook is left to the page.
            localNotebookOf: { _ in nil },
            transport: env.transport, deadline: deadline, now: env.now)
        // Signed out, or another account, by now: the banner names nobody (the
        // server's words go as they came).
        result.accountChanged = result.report.accountChanged || !signedIn(as: me, env: env)
        log.info("finish: \(InvitationFinisher.summary(result.report), privacy: .public)")
        return result
    }
}

/// The earlier vault keys, asked for at most once per run, and only when a
/// note's key does not open with the current one.
actor EarlierVaultKeys {
    private let load: () async -> [Data]
    private var loaded: [Data]?

    init(_ load: @escaping () async -> [Data]) {
        self.load = load
    }

    func value() async -> [Data] {
        if let loaded { return loaded }
        let keys = await load()
        loaded = keys
        return keys
    }
}
