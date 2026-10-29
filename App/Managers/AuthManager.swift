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
import PingolinNoteSDK
import Sodium
import WidgetKit
import UserNotifications

/// UserDefaults key: how many sign-ins on this install found the legacy
/// signing-key shape (counted only; nothing replaces it).
let legacySigningKeyCountKey = "signingKey.legacyShapeSeenCount"

@MainActor
final class AuthManager: ObservableObject {
    static let shared = AuthManager()

    /// Release-visible, never key material.
    private static let keysLog = Logger(subsystem: "com.pingolin.note", category: "keys")

    /// Tell the widgets whether anybody is signed in, and have them
    /// redraw: signed out they read and show no note.
    static func publishSignedIn(_ signedIn: Bool) {
        SharedAppGroup.isSignedIn = signedIn
        WidgetCenter.shared.reloadAllTimelines()
    }

    @Published private(set) var isAuthenticated = false {
        // The widgets' signed-in flag follows every set from here, not only a
        // change: a launch that finds no session sets false over the initial
        // false, and must still clear a flag the last run left true. A session
        // that ends while no scene is updating clears the widgets too, which
        // NoteApp's onChange alone can't promise.
        didSet { Self.publishSignedIn(isAuthenticated) }
    }

    /// How the last session ended, for the shell's teardown. A sign-out and an
    /// erasure empty the page's website data; an expiry keeps it, owned by the
    /// `.userId` an expiry keeps, with its unsynced edits; a refused sign-in
    /// changes nothing on this device, so it keeps it too. Set before
    /// `isAuthenticated` goes false, which is what RootView acts on.
    enum SessionEnd: Equatable {
        case signedOut, erased, expired, refused
        var keepsWebsiteData: Bool { self == .expired || self == .refused }
    }
    private(set) var sessionEnd: SessionEnd = .signedOut

    /// The shell's last keep of the page's kept trust before a sign-out wipes it,
    /// bounded on the shell's side. It runs FIRST in logout(): the bridge answers
    /// the page only while `.userId` and the sharing key are still there.
    var lastWebKeep: @MainActor () async -> Void = { _ = await WebShellModel.shared.keepTrustNow() }
    @Published private(set) var currentUser: User?
    @Published private(set) var isLoading = false
    /// True until `checkExistingSession()` has decided. RootView gates a
    /// neutral splash on it so a stored session does not flash through the
    /// LOGIN SCREEN on every cold start — `isAuthenticated` starts false and
    /// only flips after `getMe()` returns, so without it, for the length of
    /// that round trip, a signed-in user would be shown a sign-in form. Same
    /// flag, same reason, as the Track iOS app.
    @Published private(set) var isCheckingSession = true
    @Published private(set) var requires2FA = false
    /// Why the user is looking at the sign-in screen when it was not their
    /// choice — shown there once, then cleared by LoginView.
    @Published var signInNotice: String?

    /// Held between SRP step 2 and the code entry, in memory only.
    ///
    /// The password is here because Note derives its vault key from it, so the
    /// 2FA exchange has to finish the same key chain a password-only sign-in
    /// does. Never written to the keychain, and cleared on success, on
    /// cancellation and on logout - the window it exists in is one screen.
    private var pendingTwoFactorToken: String?
    private var pendingPassword: String?

    /// What the user still has to do about money after deleting their account,
    /// or nil when nothing is outstanding. Set by [deleteAccount] and raised at
    /// the root (NoteApp), NOT on the delete sheet: deleting logs out, which
    /// swaps the whole view tree for the sign-in screen and would take a
    /// sheet-level alert with it. The account no longer exists, so there is no
    /// second chance to say that Apple is still charging them.
    ///
    /// Deliberately NOT `private(set)` — the root alert's binding clears it on
    /// dismiss — and deliberately not cleared by `logout()`, because it has to
    /// outlive the session that just ended.
    @Published var postDeletionNotice: String?

    private let api = APIService.shared
    private let keychain = KeychainService.shared

    private init() {}

    func checkExistingSession() async {
        // FIRST STATEMENT on purpose: every exit from this function must clear
        // the flag, including the `guard` below that returns when there is no
        // stored token. Declared later, that path would leave the app sitting
        // on the splash forever with no way to sign in. The one exit that
        // keeps it is a wait for the first unlock that was cancelled: the next
        // check carries on behind the splash.
        var stillWaiting = false
        defer { if !stillWaiting { isCheckingSession = false } }
        #if DEBUG
        // XCUITest escape hatch: launching with -UITestCleanState wipes
        // the keychain slots this manager consults so tests targeting
        // the login screen never inherit a session from a prior run.
        if ProcessInfo.processInfo.arguments.contains("-UITestCleanState") {
            keychain.deleteAll()
        }
        #endif

        // Before the first unlock after a restart the Keychain can't be read
        // at all, and iOS can start the app then (see ProtectedData). That is
        // not "signed out": the splash stays until the device is unlocked, and
        // the token is read again.
        let token = await Self.storedAccessToken(
            read: { keychain.read(.accessToken) },
            waitUntilReadable: { await ProtectedData.waitUntilAvailable() }
        )
        switch Self.launchStep(for: token, waitCancelled: Task.isCancelled) {
        case .keepWaiting:
            stillWaiting = true
            return
        case .signedOut:
            isAuthenticated = false
            return
        case .restore:
            break
        }
        // The SDK's key store is loaded here, and a store that doesn't decode
        // gets its notice; nobody is signed out for it.
        KeyStoreRecovery.shared.atLaunch()
        // This account's id in its one canonical form (`CanonicalId`), read ONCE
        // before anything reads it: the stores' namespaces below, and
        // SyncService's and SharesInboxStore's acting-user reads.
        let storedAccount = Self.storedAccount(keychain.read(.userId))
        var storedId: String?
        switch storedAccount {
        case .notAnId:
            // A saved id that isn't a UUID is no account: the session ends like
            // an expiry, and the next sign-in treats it as another account's.
            expireSession()
            return
        case .id(let id, let rewrite):
            // Written back while the Keychain reads (the token just did).
            if rewrite { try? keychain.save(id, for: .userId) }
            storedId = id
        case .none, .unreadable:
            storedId = nil
        }
        // Bind the sender-key pin namespace AND the gen-floor rollback namespace
        // to the restored account before any share decryption runs, so account B
        // never inherits account A's pins or anti-rollback floors. The userId was
        // co-persisted with the access token at login, so it names the same
        // account getMe() below authenticates as. A read that failed is never
        // "no id": the stores are left as they are, and the next launch reads
        // again.
        if storedAccount != .unreadable {
            SenderKeyPinStore.shared.switchUser(storedId)
            NoteGenFloorStore.shared.switchUser(storedId)
        }
        if case .id = storedAccount {
            // What an older build kept under another spelling of this id joins
            // it. Only after a Keychain read that succeeded: the device has
            // been unlocked, so UserDefaults reads (before the first unlock it
            // reads as empty, which is never "nothing kept").
            SenderKeyPinStore.shared.adoptOtherSpellings()
            NoteGenFloorStore.shared.adoptOtherSpellings()
            // Retired content keys an earlier version kept: removed here too, so
            // an install that already holds them is cleaned.
            Self.dropRetiredContentKeys()
        }

        // OPTIMISTICALLY AUTHENTICATED, so the web shell can start loading NOW
        // rather than after the getMe() round trip below.
        //
        // Rendering the shell only once this function has returned would
        // serialise the ENTIRE web boot — document, chunks, WASM, first paint —
        // behind one auth request that the page does not need and does not wait
        // for itself. On a slow network that is seconds of splash, and the
        // worst case is far worse: a 401 goes through tryRefreshAccessToken ->
        // attestation -> retry, and APIService backs off `1 << attempt` seconds
        // between tries.
        //
        // Safe because a stored access token already implies this outcome in
        // every branch below: success sets it true, and so does a transient
        // failure (we deliberately trust the token and run offline). The ONE
        // path that does not is a definitive 401, and expireSession() flips it
        // back to false — which RootView already watches to tear the shell down
        // and show the login screen. So the optimism is corrected by the
        // existing machinery rather than by anything new.
        //
        // Set AFTER the three switchUser calls above, never before: they bind
        // the per-account namespaces, and the shell must not read a store that
        // still points at the previous account.
        isAuthenticated = true

        do {
            let me = try await api.getMe()
            // Fail closed on an identity mismatch. If the stored
            // access token authenticates as a DIFFERENT user than the userId
            // co-persisted at login (and bound to the per-account key stores above),
            // a partial login left them inconsistent — running as `me` here would
            // operate this session against the prior account's pins / gen-floors /
            // retained keys / vault key. Clear the tokens and force a clean re-login
            // (the cache + `.localDbKey` + `.userId` are preserved, so the login
            // that follows correctly wipes-or-keeps the store: account switch vs
            // same-user). login()'s rollback defer prevents this state arising, so
            // this is defense-in-depth. Compared in their one canonical form; a /me
            // id that isn't a UUID matches nothing.
            guard let meId = Self.meMatches(stored: storedId, me: me.id) else {
                expireSession()
                return
            }
            currentUser = User(id: meId, email: me.email, displayName: me.displayName,
                               recoveryEmail: me.recoveryEmail,
                               recoveryEmailVerified: me.recoveryEmailVerified,
                               guardianManaged: me.guardianManaged)
            isAuthenticated = true
        } catch {
            // Only a DEFINITIVE auth failure (401) wipes the session + keys. A
            // transient failure (offline, 5xx, timeout) must NOT — treating one as
            // a logout deletes every key on an airplane-mode launch, forcing a
            // network + full re-login. As in the Track iOS app: trust the stored
            // access token and proceed offline (currentUser stays nil; the UI
            // renders against cached data until reconnected).
            if let apiError = error as? APIError, apiError.status == 401 {
                // Session EXPIRY, not an explicit sign-out: the stored token is
                // definitively dead, but the user did NOT ask to log out — so we
                // must NOT run the full logout() wipe, which would destroy their
                // un-pushed offline outbox (a long-offline device whose session
                // lapsed would otherwise silently lose every queued edit on
                // reconnect, because logout()'s pushPendingChanges is skipped while
                // isAuthenticated is still false and then wipe() erases the dirty
                // rows). expireSession() clears only the dead tokens + drops to
                // unauthenticated, preserving the cache rows + `.localDbKey` so the
                // SAME user re-logging in can still drain their queue. An account
                // SWITCH is handled in login() (which wipes the prior user's store).
                expireSession()
            } else {
                // Transient failure (offline/5xx/timeout): keep the session so
                // the app works offline. Reconstruct currentUser from the
                // keychain so currentUser?.id is non-nil — otherwise anything
                // that keys off the acting user would see none for an offline
                // session.
                if currentUser == nil, let savedId = storedId {
                    currentUser = User(
                        id: savedId,
                        email: keychain.getString(for: .email) ?? "",
                        displayName: keychain.getString(for: .displayName)
                    )
                }
                isAuthenticated = true
            }
        }
    }

    /// The launch's read of the stored access token, waiting out the lock:
    /// the first read that isn't the lock's status, or the lock's status when
    /// the waiting task is cancelled or the device was already unlocked for
    /// more than `unlockedTries` reads. `waitUntilReadable` returns false when
    /// the device was already unlocked (see `ProtectedData`): the lock's
    /// status then isn't the first unlock's.
    static func storedAccessToken(
        read: () -> KeychainService.Read,
        waitUntilReadable: () async -> Bool,
        unlockedTries: Int = 10
    ) async -> KeychainService.Read {
        var token = read()
        var unlocked = 0
        while token == .unreadable(ProtectedData.lockedStatus), !Task.isCancelled {
            let waitedForTheUnlock = await waitUntilReadable()
            if !waitedForTheUnlock {
                unlocked += 1
                if unlocked > unlockedTries { break }
            }
            token = read()
        }
        return token
    }

    enum LaunchStep: Equatable {
        case restore, signedOut, keepWaiting
    }

    /// What the launch makes of the stored account id.
    enum StoredAccount: Equatable {
        /// None stored.
        case none
        /// A UUID, in its one form; `rewrite` when it was stored in another spelling.
        case id(String, rewrite: Bool)
        /// Stored, and not a UUID: no account.
        case notAnId
        /// The read failed: never "none". Nothing is written back or merged.
        case unreadable
    }

    nonisolated static func storedAccount(_ read: KeychainService.Read) -> StoredAccount {
        switch read {
        case .notFound:
            return .none
        case .unreadable:
            return .unreadable
        case .found(let raw):
            guard let id = CanonicalId.of(raw) else { return .notAnId }
            return .id(id, rewrite: id != raw)
        }
    }

    /// The account a sign-in's reply names, in its one form; nil when it names
    /// none that is a UUID, and the sign-in fails.
    nonisolated static func signInAccount(_ served: String?) -> String? {
        CanonicalId.of(served)
    }

    /// Whether a sign-in as `incoming` (in its one form) is another account
    /// than the one stored: compared in their one form, and a stored id that
    /// isn't a UUID is another account.
    nonisolated static func isAccountSwitch(prior: String?, incoming: String) -> Bool {
        guard let prior else { return false }
        return CanonicalId.of(prior) != incoming
    }

    /// What a sign-in may do once its keys have been opened, or not.
    enum SignInStep: Equatable {
        /// Nothing changes on this device: a switch or a first sign-in whose
        /// keys didn't open, or the same account with nothing to go on.
        case refuse
        /// Another account's data goes first, then this account's is saved.
        case switchThenSave
        /// This device's account, or a first sign-in on an empty device.
        case save
    }

    /// The gate. A switch is a stored id that isn't this account's (another, or
    /// no UUID at all), or no stored id while the cache holds rows (whose, nothing
    /// says). A switch or a first sign-in needs this sign-in's keys opened; only
    /// the same account may go on with the keys it holds.
    nonisolated static func signInStep(opened: Bool, prior: String?, incoming: String,
                                       holdsKeys: Bool, cacheHasRows: Bool) -> SignInStep {
        let sameAccount = CanonicalId.of(prior) == incoming
        if !opened && !(sameAccount && holdsKeys) { return .refuse }
        let accountSwitch = isAccountSwitch(prior: prior, incoming: incoming) || (prior == nil && cacheHasRows)
        return accountSwitch ? .switchThenSave : .save
    }

    /// This device holds a vault key and a sharing key.
    private func holdsSessionKeys() -> Bool {
        keychain.getString(for: .vaultKey) != nil && keychain.getString(for: .sharingPrivateKey) != nil
    }

    /// /me's id in its one form when it names the stored account (or none is
    /// stored); nil when it names another, or no UUID at all.
    nonisolated static func meMatches(stored: String?, me: String) -> String? {
        guard let meId = CanonicalId.of(me) else { return nil }
        if let stored, stored != meId { return nil }
        return meId
    }

    /// What the launch does with that read. Only the lock's status keeps
    /// waiting, and only when the wait for the unlock was cancelled. Any other
    /// status that isn't "not found", and the lock's status on a device that
    /// was unlocked all along, go to the sign-in screen, with nothing deleted:
    /// waiting on an unlock that may never come would keep the splash up for
    /// good.
    nonisolated static func launchStep(for token: KeychainService.Read, waitCancelled: Bool) -> LaunchStep {
        switch token {
        case .found:
            return .restore
        case .unreadable(let status) where status == ProtectedData.lockedStatus && waitCancelled:
            return .keepWaiting
        case .notFound, .unreadable:
            return .signedOut
        }
    }

    func login(email: String, password: String) async throws {
        isLoading = true
        defer { isLoading = false }

        // Client-side rate limit (mirrors android AuthRateLimiter):
        // 5 attempts then exponential backoff. Throws before we hit the
        // server so the user-visible message is consistent.
        try AuthRateLimiter.shared.check(email: email)

        let step2: SRPStep2Response
        do {
            step2 = try await runSRPHandshake(email: email, password: password)
        } catch let api as APIError where api.code == "email_not_verified" {
            // The password was right, and the address was never verified (the
            // auth server's 403): said as such, and not a failed try.
            throw AuthError.emailNotVerified
        } catch {
            AuthRateLimiter.shared.tally(email: email)
            throw error
        }

        if Self.isTwoFactorChallenge(step2) {
            // Hold the exchange token and the password in memory only, never in
            // the keychain. The password is needed AFTER the code is accepted,
            // because Note's vault key is derived from it with Argon2id and a
            // session without one is unusable — see the guard at the end of
            // finishLogin. track-ios drops the password at this point and
            // settles for a keyless session; Note cannot, because then no note
            // would decrypt.
            guard let token = step2.twoFactorToken else {
                throw AuthError.noAccessToken
            }
            // The only second step on offer is a passkey, which this app has no
            // way to perform: a code sheet here could never be answered. Say
            // what to do instead, and hold nothing.
            guard Self.canAnswerTwoFactor(step2.availableMethods) else {
                throw AuthError.twoFactorPasskeyOnly
            }
            pendingTwoFactorToken = token
            pendingPassword = password
            requires2FA = true
            return
        }

        guard let accessToken = step2.accessToken else {
            throw AuthError.noAccessToken
        }

        try await finishLogin(
            email: email,
            password: password,
            accessToken: accessToken,
            refreshToken: step2.refreshToken,
            serverUser: step2.user,
            serverKdf: step2.kdfParams,
            serverKeys: step2.encryptedKeys,
            serverSharingKey: step2.sharingPublicKey,
            serverSigningKey: step2.signingPublicKey
        )
    }

    /// Finish a login once an access token exists, whether it came from SRP
    /// step 2 or from the 2FA exchange.
    ///
    /// Split out so the 2FA path runs the SAME sequence rather than a reduced
    /// one. The vault-key derivation at the end is the reason: it needs the
    /// cleartext password, so a 2FA login that did not carry the password
    /// through would authenticate and then strand the account with no way to
    /// read its own notes.
    private func finishLogin(
        email: String,
        password: String,
        accessToken: String,
        refreshToken: String?,
        serverUser: User?,
        serverKdf: KdfParamsResponse?,
        serverKeys: EncryptedKeysResponse?,
        serverSharingKey: String?,
        serverSigningKey: String?
    ) async throws {
        try keychain.save(accessToken, for: .accessToken)
        if let refresh = refreshToken {
            try keychain.save(refresh, for: .refreshToken)
        }
        // Until the userId is committed below, this login holds
        // the INCOMING account's access token while the keychain still names the
        // PRIOR account (`.userId`). If it aborts in that window — getMe() throws,
        // or no id resolves at the guard below — a relaunch's checkExistingSession
        // would authenticate this token but bind every per-account store to the
        // prior userId (account B's session run on account A's identity + keys).
        // Roll the just-saved tokens back on any early exit so no orphaned token
        // outlives the aborted login. The switch cleanup below hasn't run yet, so
        // account A's key slots are untouched and A can still re-login cleanly.
        var identityCommitted = false
        defer {
            if !identityCommitted {
                keychain.delete(key: .accessToken)
                keychain.delete(key: .refreshToken)
            }
        }

        // The keys come from THIS reply — SRP step 2 or the 2FA exchange — as on
        // both Android apps, and never from /auth/me. The auth server sends the
        // encrypted blobs in `encrypted_keys` and the public keys at the top
        // level (`sharing_public_key`, `signing_public_key`); /me's copy of the
        // password-wrapped master key is not relied on. A reply without them
        // leaves no vault key, and the guard below fails the sign-in closed.
        let encryptedKeys = Self.signInKeys(
            serverKeys: serverKeys, sharingPublicKey: serverSharingKey, signingPublicKey: serverSigningKey
        )
        let kdfParams = serverKdf
        var userId = serverUser?.id
        var displayName = serverUser?.displayName

        // /me only for what the reply does not carry and is not a key: the
        // display name (and the id, should a reply ever omit it). Best-effort:
        // it decides nothing about the keys.
        if userId == nil || displayName == nil, let me = try? await api.getMe() {
            userId = userId ?? me.id
            displayName = displayName ?? me.displayName
        }

        // The account id is the server's word, taken only as a UUID and kept in
        // its one canonical form (`CanonicalId`): a reply naming none signs
        // nobody in, before anything is wiped or saved (the defer above removes
        // the tokens).
        guard let id = Self.signInAccount(userId) else { throw AuthError.noAccessToken }

        // PROVE, then WIPE, then SAVE. This account's keys are opened in memory
        // first. Nothing of the previous account's (cached rows, key slots, pins,
        // push state) is touched, and none of this one's keys are stored, until
        // they have opened and the gate below has passed: a cleanup run first,
        // followed by incoming keys that don't open, would leave both accounts'
        // data gone.
        //
        // Full vault-key chain (Sodium primitives, byte-identical to the web and
        // Android), while the password is still in scope:
        //
        //   derivedKey  = Argon2id(password, kdf_salt, kdf_params)
        //   masterKey   = secretbox.open(encrypted_master_key, derivedKey)
        //   sharingPriv = secretbox.open(encrypted_sharing_private_key, masterKey)
        //   vaultKey    = generichash(sharingPriv, key="pingolin-note-vault")
        var opened: SignInKeys? = nil
        if let keys = encryptedKeys, let kdf = kdfParams {
            do {
                opened = try await Self.openSignInKeys(password: password, keys: keys, kdf: kdf)
            } catch {
                Self.keysLog.error("This sign-in's keys didn't open: \(String(describing: error), privacy: .public)")
            }
        }
        // Whatever path this takes, the opened keys' bytes are zeroed.
        defer { opened?.wipe() }

        // Account-switch cleanup (pairs with expireSession's 401 outbox
        // preservation). A 401 session-expiry deliberately KEEPS the prior user's
        // offline outbox + KEY MATERIAL + `.localDbKey` so a same-user re-login
        // can drain it — which means a DIFFERENT user logging in here can find
        // account A's cached rows, derived keys, push/attestation state, and
        // in-memory shared-note plaintext all still present. Purge ALL of
        // it via the shared switchAccountCleanup() before installing B, so B never
        // reads A's cached notes, never encrypts under A's stale vault key, and
        // B's next sync never pushes A's queued edits under B's token. The
        // passphrase is preserved (cleanup does a plain wipe, not deleteAll +
        // reopen — that's logout's job), so the file/key/queue stay consistent.
        // A normal logout() already ran this cleanup AND cleared `.userId`, so
        // `prior` is nil there; a SAME-user re-login keeps the outbox. `.userId`
        // absent while the cache still holds rows (a partial or interrupted prior
        // teardown) is a switch too: never let this account inherit them.
        let prior = keychain.getString(for: .userId)
        let step = Self.signInStep(
            opened: opened != nil, prior: prior, incoming: id,
            holdsKeys: holdsSessionKeys(), cacheHasRows: NoteStore.shared.hasAnyRow()
        )
        // The gate. A switch or a first sign-in needs this account's keys opened
        // HERE; only the same account goes on with the keys it holds when a
        // re-derive fails. A refusal changes nothing on this device: the defer
        // above removes the tokens, and every key slot stays.
        if step == .refuse {
            failPartialLogin()
            throw AuthError.vaultKeyUnavailable
        }
        if step == .switchThenSave {
            await switchAccountCleanup()
            // Another account's page data, kept by an expiry, goes before
            // `.userId` names this account and before `isAuthenticated` shows the
            // shell: this account's page never loads over it.
            await WebShellDataStore.wipeAsync()
        }

        // `.userId` and the stores are bound first, after the gate and the cleanup
        // (as on Android).
        currentUser = User(id: id, email: serverUser?.email ?? email, displayName: displayName)
        try keychain.save(id, for: .userId)
        // Identity committed: token + userId now name the SAME account, so the
        // rollback defer above becomes a no-op.
        identityCommitted = true
        // Bind the sender-key pin store AND the gen-floor rollback store to this
        // account so a shared device keeps each account's TOFU pins and
        // anti-rollback floors isolated (account B must not inherit account A's).
        // Mirrors note-web loadPinnedKeysFromStorage(userId).
        SenderKeyPinStore.shared.switchUser(id)
        NoteGenFloorStore.shared.switchUser(id)
        // What an older build kept under another spelling of this id joins
        // it; the Keychain write just above proves the device is unlocked.
        SenderKeyPinStore.shared.adoptOtherSpellings()
        NoteGenFloorStore.shared.adoptOtherSpellings()
        // Persist non-secret profile fields so an offline launch can
        // rebuild currentUser without a network round-trip (see
        // checkExistingSession's transient branch).
        try? keychain.save(serverUser?.email ?? email, for: .email)
        if let dn = displayName { try? keychain.save(dn, for: .displayName) }

        if keychain.getString(for: .deviceId) == nil {
            try keychain.save(UUID().uuidString, for: .deviceId)
        }

        // Only now are this account's keys stored: after the cleanup, so none of
        // them can be wiped or left behind by a sign-in that doesn't go through,
        // and after `.userId` names this account, so a store that stops part-way
        // leaves this account with no keys (which the guard below refuses), never
        // this account's keys under the previous account's id. A store that
        // throws part-way is caught by the guard below.
        var stored: OpenedKeys? = nil
        if let opened {
            do {
                stored = try storeSignInKeys(opened)
            } catch {
                Self.keysLog.error("This sign-in's keys weren't stored: \(String(describing: error), privacy: .public)")
            }
        }

        // The signing key is checked, never replaced: there is no automatic
        // migration. A legacy shape is logged and counted, from the keys just
        // opened, never the server's word.
        if let stored {
            checkSigningKey(
                opened: stored,
                serverSigningPublicKey: serverSigningKey ?? encryptedKeys?.signingPublicKey
            )
        }

        // A note session is unusable AND unsafe without a vault key, and the
        // SHARING private key is required too, as in the Android app: the
        // web shell refuses to open without it (WebKeyBridge opens shares with
        // it). The gate above refused a sign-in with nothing to go on; this
        // catches a store that didn't take.
        guard holdsSessionKeys() else {
            failPartialLogin()
            throw AuthError.vaultKeyUnavailable
        }

        AuthRateLimiter.shared.clear(email: email)
        isAuthenticated = true
    }

    /// Exchange a typed code (an authenticator code or a backup code) for the
    /// real session, completing a login that stopped at the 2FA challenge.
    ///
    /// Runs the full `finishLogin` sequence with the password stashed at the
    /// challenge, so an account with two-factor on ends up with the same vault
    /// key, the same account-switch cleanup and the same signing-key check as
    /// one without it.
    ///
    /// A wrong code, or one just used, throws and leaves the challenge in place,
    /// so the next code goes out on the same attempt (the auth server keeps the
    /// attempt until its 5th wrong code). An attempt that is over or has ended
    /// is dropped; the sheet stays until the person has read why, and its OK
    /// goes back to the password (`twoFactorAttemptOpen`).
    func verify2FA(code: String) async throws {
        guard let token = pendingTwoFactorToken, let password = pendingPassword else {
            throw AuthError.twoFactorChallengeExpired
        }

        isLoading = true
        defer { isLoading = false }

        let response: Login2FAResponse
        do {
            response = try await api.verify2FA(twoFactorToken: token, code: code)
        } catch {
            guard let refusal = Self.twoFactorRefusal(error) else { throw error }
            if !refusal.keepsTheTwoFactorAttempt { dropTwoFactorAttempt() }
            throw refusal
        }
        // Accepted: the token is single-use, so the attempt is over whatever
        // happens next. A failure below is still said on the sheet.
        dropTwoFactorAttempt()
        try await finishLogin(
            email: response.user.email,
            password: password,
            accessToken: response.accessToken,
            refreshToken: response.refreshToken,
            serverUser: response.user,
            serverKdf: response.kdfParams,
            serverKeys: response.encryptedKeys,
            serverSharingKey: response.sharingPublicKey,
            serverSigningKey: response.signingPublicKey
        )

        clearTwoFactorChallenge()
    }

    /// Abandon a 2FA challenge — the user backed out of the code screen, or
    /// read why the attempt ended.
    func cancelTwoFactorChallenge() {
        clearTwoFactorChallenge()
    }

    /// Whether the challenge on screen still takes a code. False once the
    /// attempt is over (too many wrong codes, ended, or spent by an accepted
    /// code): the sheet's OK then goes back to the password.
    var twoFactorAttemptOpen: Bool { pendingTwoFactorToken != nil }

    private func clearTwoFactorChallenge() {
        dropTwoFactorAttempt()
        requires2FA = false
    }

    /// The attempt's token and password go; the sheet stays until the person
    /// has read why.
    private func dropTwoFactorAttempt() {
        pendingTwoFactorToken = nil
        pendingPassword = nil
    }

    /// The two-step sign-in's refusals, by the auth server's reply (as in the
    /// Track iOS app's `twoFactorRefusal`): a wrong code (401) and a code just
    /// used (400 `totp_replay`) are typed again on the same attempt; too many
    /// wrong codes (429, the attempt's 5th or the account's limit), an attempt
    /// that has ended (any other 400: it expired, or was already used; a 403,
    /// which comes after the code was taken) and an address never verified (403
    /// `email_not_verified`) mean signing in again. Anything else is said as any
    /// other failure, and keeps the attempt. In this app's words, never the
    /// server's.
    nonisolated static func twoFactorRefusal(_ error: Error) -> AuthError? {
        guard let api = error as? APIError, let status = api.status else { return nil }
        switch status {
        case 401: return .wrongTwoFactorCode
        case 429: return .twoFactorAttemptOver
        case 400: return api.code == "totp_replay" ? .twoFactorCodeJustUsed : .twoFactorAttemptEnded
        // After the code was taken: the attempt is spent.
        case 403: return api.code == "email_not_verified" ? .emailNotVerified : .twoFactorAttemptEnded
        default: return nil
        }
    }

    /// Roll back a login that authenticated (SRP succeeded) but could NOT
    /// complete the vault-key chain. Clears the session tokens so a
    /// relaunch's `checkExistingSession` — which only checks the access token —
    /// can't restore an authenticated-but-keyless session. Stays signed out; the
    /// user retries and re-derives.
    ///
    /// Every key slot stays: nothing of the incoming account's was stored
    /// before the gate, and what a 401 kept — the same account's keys and
    /// outbox, or another account's awaiting its own re-login — is not this
    /// sign-in's to delete.
    private func failPartialLogin() {
        sessionEnd = .refused
        keychain.delete(key: .accessToken)
        keychain.delete(key: .refreshToken)
        currentUser = nil
        isAuthenticated = false
        // Not the sheet: after an accepted code it says why, and its OK closes it.
        dropTwoFactorAttempt()
    }

    /// What storeSignInKeys stored, for the signing-key check.
    struct OpenedKeys {
        /// The X25519 sharing private key, when the server sent its blob.
        var sharingPrivateKey: Bytes?
        /// The Ed25519 seed this login opened and imported (the first 32 bytes
        /// of a 64-byte secret). nil when the blob is absent or would not open.
        var signingSeed: Bytes?
    }

    /// See `signingKeyVerdict`.
    enum SigningKeyVerdict: Equatable {
        /// The opened seed IS the sharing private key (the legacy mobile shape).
        case legacy
        /// A genuine key, and the server's record agrees.
        case matches
        /// A genuine key the server's record does not match: the record is
        /// wrong, not the key.
        case serverDisagrees
        /// Nothing opened this login.
        case noSigningKey
    }

    /// What this login does about what it found. There is no case that
    /// replaces or creates a key: a legacy shape is only logged and counted.
    enum SigningKeyResponse: Equatable {
        case nothing
        case logServerDisagreement
        case logAndCountLegacy
    }

    /// Classify the signing key this login OPENED — never trusting the server's
    /// `signing_public_key`, which is unauthenticated. The sharing key is
    /// compared in constant time.
    nonisolated static func signingKeyVerdict(
        signingSeed: Bytes?,
        sharingPrivateKey: Bytes?,
        serverVerifyingKeyHex: String
    ) -> SigningKeyVerdict {
        guard let seed = signingSeed else { return .noSigningKey }
        let sodium = Sodium()
        if let sharing = sharingPrivateKey, constantTimeEquals(seed, sharing) { return .legacy }
        guard let pair = sodium.sign.keyPair(seed: seed) else { return .serverDisagrees }
        let localHex = pair.publicKey.map { String(format: "%02x", $0) }.joined()
        return localHex == serverVerifyingKeyHex.lowercased() ? .matches : .serverDisagrees
    }

    nonisolated static func signingKeyResponse(_ verdict: SigningKeyVerdict) -> SigningKeyResponse {
        switch verdict {
        case .legacy: return .logAndCountLegacy
        case .serverDisagrees: return .logServerDisagreement
        case .matches, .noSigningKey: return .nothing
        }
    }

    /// Same length and bytes, in time that does not depend on where they differ.
    nonisolated static func constantTimeEquals(_ a: Bytes, _ b: Bytes) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in a.indices { diff |= a[i] ^ b[i] }
        return diff == 0
    }

    /// Act on a verdict: count a legacy shape (in `defaults`, under
    /// `legacySigningKeyCountKey`) and say what else to do. Never a rotation.
    @discardableResult
    nonisolated static func recordSigningKeyVerdict(
        _ verdict: SigningKeyVerdict,
        defaults: UserDefaults
    ) -> SigningKeyResponse {
        let response = signingKeyResponse(verdict)
        if response == .logAndCountLegacy {
            defaults.set(defaults.integer(forKey: legacySigningKeyCountKey) + 1, forKey: legacySigningKeyCountKey)
        }
        return response
    }

    /// Check the signing key this login opened. Never replaces or creates one
    /// (no app, and not the portal, migrates it automatically). A legacy shape
    /// is logged and counted; a server record that disagrees with a genuine key
    /// is logged, and the opened key stays in use.
    private func checkSigningKey(opened: OpenedKeys, serverSigningPublicKey: String?) {
        let serverHex = serverSigningPublicKey.map(hexFromServerSigningKey) ?? ""
        let verdict = Self.signingKeyVerdict(
            signingSeed: opened.signingSeed,
            sharingPrivateKey: opened.sharingPrivateKey,
            serverVerifyingKeyHex: serverHex
        )
        switch Self.recordSigningKeyVerdict(verdict, defaults: .standard) {
        case .nothing:
            return
        case .logServerDisagreement:
            Self.keysLog.warning("Server's signing_public_key differs from the key this login opened; keeping the opened key")
        case .logAndCountLegacy:
            let seen = UserDefaults.standard.integer(forKey: legacySigningKeyCountKey)
            Self.keysLog.warning("Signing key has the legacy shape (seed is the sharing key); not replaced (seen \(seen, privacy: .public)x)")
        }
    }

    /// Convert a server-supplied signing key to lowercase hex.
    /// Server may send hex (already-rotated accounts) or base64 (legacy
    /// blob). Try hex first (64 hex chars), otherwise base64-decode.
    private func hexFromServerSigningKey(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count == 64, trimmed.allSatisfy({ $0.isHexDigit }) {
            return trimmed.lowercased()
        }
        guard let bytes = Self.sodium.utils.base642bin(trimmed, variant: .ORIGINAL) else { return "" }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// SRP step1+step2 with the android-style one-shot retry: if step2
    /// throws a 401, the
    /// freshly-issued session may not be visible to the server yet —
    /// wait 500 ms and re-run the full handshake once.
    private func runSRPHandshake(email: String, password: String) async throws -> SRPStep2Response {
        do {
            return try await singleSRPAttempt(email: email, password: password)
        } catch let apiError as APIError where apiError.code.hasPrefix("http_401") || apiError.code == "unauthorized" {
            try await Task.sleep(nanoseconds: 500_000_000)
            return try await singleSRPAttempt(email: email, password: password)
        }
    }

    /// The X25519 public key for an opened sharing private key, as base64
    /// (the form everything here stores and hands to the page), through the
    /// SDK — never reimplemented. nil if it cannot be derived.
    nonisolated static func publicKeyB64(forSharingPrivateKey privateKey: Bytes) -> String? {
        let sodium = Sodium()
        guard let hex = deriveSharingPublicKey(privateKey: Data(privateKey)),
              let pub = sodium.utils.hex2bin(hex) else { return nil }
        return sodium.utils.bin2base64(pub, variant: .ORIGINAL)
    }

    /// Our sharing public key is the one DERIVED from the private key that
    /// opened; the served copy is only compared. Returns the key to keep and
    /// whether the served one disagreed; nil if none derives.
    nonisolated static func sharingPublicKeyToKeep(
        openedPrivateKey: Bytes,
        served: String?
    ) -> (key: String, servedDisagrees: Bool)? {
        guard let derived = publicKeyB64(forSharingPrivateKey: openedPrivateKey) else { return nil }
        return (derived, served.map { $0 != derived } ?? false)
    }

    /// The sign-in keys, from the reply alone: the sealed blobs from
    /// `encrypted_keys`, plus the served public keys (inside it, or at the
    /// reply's top level) — which are only compared with the keys derived from
    /// what opens, never used. Nothing here can come from /auth/me.
    nonisolated static func signInKeys(
        serverKeys: EncryptedKeysResponse?,
        sharingPublicKey: String?,
        signingPublicKey: String?
    ) -> EncryptedKeysResponse? {
        serverKeys.map { keys in
            EncryptedKeysResponse(
                masterKey: keys.masterKey,
                sharingPrivateKey: keys.sharingPrivateKey,
                signingPrivateKey: keys.signingPrivateKey,
                sharingPublicKey: keys.sharingPublicKey ?? sharingPublicKey,
                signingPublicKey: keys.signingPublicKey ?? signingPublicKey
            )
        }
    }

    private func singleSRPAttempt(email: String, password: String) async throws -> SRPStep2Response {
        let step1 = try await api.srpStep1(email: email)
        let proof = try srpComputeLoginProof(
            email: email,
            password: password,
            saltB64: step1.salt,
            bcryptSalt: step1.bcryptSalt ?? "",
            serverPublicB64: step1.serverPublic
        )
        let reply = try await api.srpStep2(
            sessionId: step1.sessionId,
            clientPublic: proof.clientPublic,
            clientProof: proof.clientProof
        )
        // Nothing in the reply is used — no tokens, no keys, no 2FA token —
        // unless the server proved it holds this account's verifier. This is
        // before login() looks at either branch.
        guard Self.serverProofMatches(proof, serverProof: reply.serverProof) else {
            throw AuthError.serverProofRejected
        }
        return reply
    }

    /// The SRP step-2 reply's `server_proof` (M2) for this attempt's A,
    /// M1 and K, in the encoding this client's M1 used (minimal: the SDK's
    /// client), checked by the SDK in constant time. A missing proof, or the
    /// SDK refusing our own values (a programming error), is a failure,
    /// logged.
    nonisolated static func serverProofMatches(_ proof: SrpLoginProof, serverProof: String?) -> Bool {
        guard let serverProof, !serverProof.isEmpty else { return false }
        do {
            return try srpVerifyServerProof(
                clientPublicB64: proof.clientPublic,
                clientProofB64: proof.clientProof,
                sessionKeyB64: proof.sessionKey,
                serverProofB64: serverProof,
                encoding: .minimal
            )
        } catch {
            Logger(subsystem: "com.pingolin.note", category: "keys")
                .error("Server proof could not be checked: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    private static let sodium = Sodium()
    private static let vaultPersonalization = Array("pingolin-note-vault".utf8)

    /// What a sign-in's password opened, in memory only: nothing is stored
    /// or imported until the gate has passed and, on an account switch, the
    /// previous account's data is gone. A class, so `wipe()` zeroes the one copy
    /// of each key; the base64 strings made to store them can't be zeroed.
    final class SignInKeys {
        fileprivate(set) var masterKey: Bytes
        fileprivate(set) var sharingPrivateKey: Bytes
        fileprivate(set) var vaultKey: Bytes
        /// The Ed25519 seed (the first 32 bytes of a 64-byte secret), when the
        /// signing blob opened; nil when it is absent or wouldn't open.
        fileprivate(set) var signingSeed: Bytes?
        /// The reply's sharing public key, only ever compared.
        let servedSharingPublicKey: String?

        init(masterKey: Bytes, sharingPrivateKey: Bytes, vaultKey: Bytes, signingSeed: Bytes?, servedSharingPublicKey: String?) {
            self.masterKey = masterKey
            self.sharingPrivateKey = sharingPrivateKey
            self.vaultKey = vaultKey
            self.signingSeed = signingSeed
            self.servedSharingPublicKey = servedSharingPublicKey
        }

        /// Zero every key byte this sign-in opened.
        func wipe() {
            for i in masterKey.indices { masterKey[i] = 0 }
            for i in sharingPrivateKey.indices { sharingPrivateKey[i] = 0 }
            for i in vaultKey.indices { vaultKey[i] = 0 }
            if signingSeed != nil {
                for i in signingSeed!.indices { signingSeed![i] = 0 }
            }
        }
    }

    /// Open this account's keys with its password, in memory: the master key
    /// (Argon2id), the X25519 sharing key, the note vault key derived from it,
    /// and the Ed25519 signing seed. Stores and imports nothing. Throws when the
    /// master key or the sharing key doesn't open (the reply must carry the
    /// sharing blob: a session can't open a share without it); a signing blob
    /// that doesn't open is only logged.
    static func openSignInKeys(
        password: String,
        keys: EncryptedKeysResponse,
        kdf: KdfParamsResponse
    ) async throws -> SignInKeys {
        let sodium = Self.sodium

        guard let saltBytes = sodium.utils.base642bin(kdf.salt, variant: .ORIGINAL) else {
            throw VaultDerivationError.invalidKdfSalt
        }
        // swift-sodium's `pwHash.hash` doesn't expose the parallelism
        // parameter — libsodium's high-level `crypto_pwhash` hardcodes
        // parallelism=1, which matches android (its Rust SDK uses the
        // same libsodium high-level path). We accept the server's
        // `kdf.parallelism` field as metadata only.
        //
        // Argon2id is the one genuinely expensive step here
        // (memMib-scale, hundreds of ms). Run it off the main actor so login
        // doesn't freeze the UI; the secretbox opens below are microseconds.
        let passwordBytes = Array(password.utf8)
        let opsLimit = Int(kdf.iterations)
        let memLimit = Int(kdf.memoryKib) * 1024
        let derived = await Task.detached(priority: .userInitiated) {
            sodium.pwHash.hash(
                outputLength: 32,
                passwd: passwordBytes,
                salt: saltBytes,
                opsLimit: opsLimit,
                memLimit: memLimit,
                alg: .Argon2ID13
            )
        }.value
        guard var derivedKey = derived else { throw VaultDerivationError.argon2Failed }
        defer { for i in derivedKey.indices { derivedKey[i] = 0 } }

        guard let mkN = sodium.utils.base642bin(keys.masterKey.nonce, variant: .ORIGINAL),
              let mkC = sodium.utils.base642bin(keys.masterKey.ciphertext, variant: .ORIGINAL),
              var masterKey = sodium.secretBox.open(authenticatedCipherText: mkC, secretKey: derivedKey, nonce: mkN)
        else { throw VaultDerivationError.masterKeyOpen }

        guard let spk = keys.sharingPrivateKey,
              let spkN = sodium.utils.base642bin(spk.nonce, variant: .ORIGINAL),
              let spkC = sodium.utils.base642bin(spk.ciphertext, variant: .ORIGINAL),
              var sharingPrivateKey = sodium.secretBox.open(authenticatedCipherText: spkC, secretKey: masterKey, nonce: spkN),
              sharingPrivateKey.count == 32
        else {
            for i in masterKey.indices { masterKey[i] = 0 }
            throw VaultDerivationError.sharingKeyOpen
        }

        guard let vaultKey = sodium.genericHash.hash(
            message: sharingPrivateKey,
            key: Self.vaultPersonalization,
            outputLength: 32
        ) else {
            for i in masterKey.indices { masterKey[i] = 0 }
            for i in sharingPrivateKey.indices { sharingPrivateKey[i] = 0 }
            throw VaultDerivationError.blake2bFailed
        }

        // Ed25519 signing seed, sealed under the master key (XSalsa20-Poly1305).
        // decryptWithKey hands back the plaintext's base64, which is the seed's,
        // and imports nothing — mirrors track-ios importSigningKey. Best-effort:
        // a legacy account may omit the blob or ship a seed that doesn't match its
        // published key; either way checkSigningKey logs it; nothing replaces it.
        var signingSeed: Bytes? = nil
        if let signingBlob = keys.signingPrivateKey,
           let masterKeyB64 = sodium.utils.bin2base64(masterKey, variant: .ORIGINAL) {
            do {
                let seedB64 = try SDKCrypto.cryptoManager.decryptWithKey(
                    encryptedData: PingolinNoteSDK.EncryptedData(
                        nonce: signingBlob.nonce,
                        ciphertext: signingBlob.ciphertext
                    ),
                    keyBase64: masterKeyB64
                )
                // Normalize a >=64-byte blob (full secret) to its 32-byte seed —
                // see WebAppKeyHandoff: the handoff and the SDK both assume a seed.
                signingSeed = sodium.utils.base642bin(normalizeSigningSeedB64(seedB64), variant: .ORIGINAL)
            } catch {
                Self.keysLog.warning("The signing seed didn't open: \(String(describing: error), privacy: .public)")
            }
        }
        return SignInKeys(
            masterKey: masterKey, sharingPrivateKey: sharingPrivateKey, vaultKey: vaultKey,
            signingSeed: signingSeed, servedSharingPublicKey: keys.sharingPublicKey
        )
    }

    /// Store and import what `openSignInKeys` opened: only after the gate, and
    /// after an account switch's cleanup. Returns what the signing-key check
    /// needs (the seed only when it was imported).
    private func storeSignInKeys(_ keys: SignInKeys) throws -> OpenedKeys {
        let sodium = Self.sodium
        var opened = OpenedKeys()
        guard let vaultKeyB64 = sodium.utils.bin2base64(keys.vaultKey, variant: .ORIGINAL),
              let masterKeyB64 = sodium.utils.bin2base64(keys.masterKey, variant: .ORIGINAL),
              let sharingPrivateKeyB64 = sodium.utils.bin2base64(keys.sharingPrivateKey, variant: .ORIGINAL)
        else { throw VaultDerivationError.base64EncodeFailed }
        try keychain.save(vaultKeyB64, for: .vaultKey)
        // Cache the masterKey + sharing-private-key. master is kept around
        // as a derivation byproduct; the sharing private key is what unseals
        // wrapped keys on incoming shares (libsodium crypto_box_seal_open).
        try keychain.save(masterKeyB64, for: .masterKey)
        // Before anything is imported into the SDK: its key store is loaded
        // again, and one that still doesn't decode is cleared so the imports
        // below write it whole. Never on a store the platform couldn't read.
        KeyStoreRecovery.shared.beforeSignInImport()
        try keychain.save(sharingPrivateKeyB64, for: .sharingPrivateKey)
        // Import into the SDK too (base64 of the raw X25519 scalar, the
        // same shape decryptWithKey yields) so the KeyStorageCallback
        // persists a complete StoredKeyData bundle — privateKey +
        // signing seed — that loadPersistedKeys can restore on cold
        // start. Mirrors note-android AuthViewModel.importPrivateKey at
        // login. note's own note crypto uses the free functions with
        // explicit keys, so this only feeds the signing-key path +
        // persistence; no other behavior changes.
        try? SDKCrypto.cryptoManager.importPrivateKey(privateKeyBase64: sharingPrivateKeyB64)
        // The sharing PUBLIC key is derived from the private key just opened,
        // never taken from the reply: the served copy is only compared, and a
        // disagreement logged.
        if let keep = Self.sharingPublicKeyToKeep(openedPrivateKey: keys.sharingPrivateKey, served: keys.servedSharingPublicKey) {
            try keychain.save(keep.key, for: .sharingPublicKey)
            if keep.servedDisagrees {
                Self.keysLog.warning("Server's sharing_public_key differs from the key derived from the opened private key; using the derived one")
            }
        }
        // The signing seed: cached for the page's share signing (`WebKeyBridge`)
        // and imported into the SDK so signingPublicKeyHex()/signWrap reflect the
        // account's published identity key — NOT the X25519 sharing scalar (a
        // curve mismatch). Best-effort.
        if let seed = keys.signingSeed, let seedB64 = sodium.utils.bin2base64(seed, variant: .ORIGINAL) {
            do {
                try keychain.save(seedB64, for: .signingPrivateKey)
                try SDKCrypto.cryptoManager.importSigningPrivateKey(secretSeedB64: seedB64)
                opened.signingSeed = seed
            } catch {
                Self.keysLog.warning("The signing seed wasn't imported: \(String(describing: error), privacy: .public)")
            }
        }
        opened.sharingPrivateKey = keys.sharingPrivateKey
        return opened
    }

    enum VaultDerivationError: LocalizedError {
        case invalidKdfSalt, argon2Failed, masterKeyOpen, sharingKeyOpen
        case blake2bFailed, base64EncodeFailed

        var errorDescription: String? {
            switch self {
            case .invalidKdfSalt: return "kdf_salt not valid base64"
            case .argon2Failed: return "Argon2id KDF failed"
            case .masterKeyOpen: return "Failed to decrypt master key (wrong password?)"
            case .sharingKeyOpen: return "Failed to decrypt sharing private key"
            case .blake2bFailed: return "BLAKE2b-keyed hash failed"
            case .base64EncodeFailed: return "Vault key base64 encoding failed"
            }
        }
    }

    func updateDisplayName(_ newName: String) async throws {
        let response = try await api.updateMe(displayName: newName)
        let saved = response.displayName ?? newName
        // The reply carries the new name and nothing else, so everything else
        // about the user — id, email, recovery-address state — is kept from
        // what we already hold. Renaming yourself must not downgrade a known
        // "recovery address verified" to "we haven't asked".
        guard let user = currentUser else { return }
        currentUser = User(id: user.id, email: user.email, displayName: saved,
                           recoveryEmail: user.recoveryEmail,
                           recoveryEmailVerified: user.recoveryEmailVerified)
        // Keep the offline-launch copy in step. `checkExistingSession`'s
        // transient branch rebuilds `currentUser` from these keychain fields
        // when the network is down, so a stale one would show the old name
        // until the next successful /auth/me.
        try? keychain.save(saved, for: .displayName)
    }

    /// Refresh only the recovery-address fields from `/auth/me`.
    ///
    /// Needed because `login()` builds `currentUser` from the SRP step2
    /// response, which carries no recovery fields. Without this the Settings
    /// row would read "Checking…" for the whole session after a fresh sign-in
    /// and only tell the truth after a relaunch, where `checkExistingSession`
    /// is the one path that calls `/auth/me`.
    ///
    /// Best-effort and non-destructive: a failure leaves the current state
    /// alone rather than downgrading a known answer to "unknown". The id guard
    /// mirrors `checkExistingSession` — a response for a different account
    /// must never be merged onto this one's profile.
    func refreshRecoveryStatus() async {
        guard isAuthenticated, let user = currentUser else { return }
        guard let me = try? await api.getMe(), CanonicalId.same(me.id, user.id) else { return }
        currentUser = User(id: user.id, email: user.email, displayName: user.displayName,
                           recoveryEmail: me.recoveryEmail,
                           recoveryEmailVerified: me.recoveryEmailVerified)
    }

    /// Session-EXPIRY teardown (a definitive 401 on a RESTORED session at
    /// launch), as distinct from an explicit user `logout()`. The stored tokens
    /// are dead, but this is NOT the user asking to sign out — so we must NOT
    /// destroy their un-pushed offline outbox (the dirty `NoteStore` rows) the
    /// way `logout()`'s `wipe()` + `keychain.deleteAll()` would. Clear ONLY the
    /// invalid tokens and drop to unauthenticated; `.userId`, `.localDbKey`, and
    /// the cache rows all survive. The SAME user re-logging in re-derives their
    /// keys and the post-login `sync()` drains the preserved outbox (SyncService's
    /// acting-user guards keep any pull/backfill write same-user-only, and the
    /// outbox it drains is that same user's). A DIFFERENT user logging in is
    /// handled by `login()`, which wipes the prior user's store before installing
    /// the new account, so B never reads or pushes A's queued notes.
    private func expireSession() {
        // The shell keeps the page's website data and runs its last keep first
        // (RootView → WebShellModel.endSession): neither `.userId` nor a key
        // goes here, so the bridge still answers the outgoing account's page.
        sessionEnd = .expired
        keychain.delete(key: .accessToken)
        keychain.delete(key: .refreshToken)
        currentUser = nil
        isAuthenticated = false
        clearTwoFactorChallenge()
    }

    /// The web shell found a session without the keys to open notes: no vault
    /// key or no sharing key in the Keychain. Loading the page anyway would
    /// mint a throwaway vault key; a sign-in derives the real ones. Ends the
    /// session like an expiry — the offline outbox is kept for the same user
    /// — and tells the sign-in screen why.
    func expireSessionForMissingKeys() {
        guard isAuthenticated else { return }
        signInNotice = AuthError.vaultKeyUnavailable.errorDescription
        expireSession()
    }

    /// Whether a two-factor challenge offering `availableMethods` can be
    /// answered here: this app has a 6-digit code entry only, i.e. TOTP. nil
    /// (a server that lists no methods) keeps the code entry.
    nonisolated static func canAnswerTwoFactor(_ availableMethods: [String]?) -> Bool {
        guard let availableMethods else { return true }
        return availableMethods.contains { $0.caseInsensitiveCompare("totp") == .orderedSame }
    }

    /// Whether SRP step 2 answered with a 2FA challenge instead of a session.
    /// The flag first — but a reply carrying an exchange token and no access
    /// token IS a challenge whatever the flag decoded to. A missed challenge
    /// falls through to "no access token"; the flag's key converts
    /// differently across Foundation versions (see `SRPStep2Response`).
    nonisolated static func isTwoFactorChallenge(_ step2: SRPStep2Response) -> Bool {
        step2.requires2fa == true || (step2.accessToken == nil && step2.twoFactorToken != nil)
    }

    /// Where an earlier version kept retired (pre-rotation) note content keys,
    /// vault-wrapped, in UserDefaults: under this key, and under `<key>.<id>`
    /// for each account, in whatever spelling of its id. Nothing reads them now.
    nonisolated static let retiredContentKeysKey = "note_retired_content_keys"

    /// Remove every one of those keys, so no account's retired content keys
    /// stay on the device: at sign-out, and at a launch that restores a session.
    nonisolated static func dropRetiredContentKeys(from defaults: UserDefaults = .standard) {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(retiredContentKeysKey) {
            defaults.removeObject(forKey: key)
        }
    }

    /// Cross-account cleanup shared by `logout()` and the account-SWITCH branch of
    /// `login()`. Purges every trace of the OUTGOING account — the
    /// decrypted read cache, derived key material, SDK keys, push / attestation /
    /// notification state, widget snapshot, and per-account crypto stores — so the
    /// incoming account can never inherit it. Deletes the outgoing account's KEY
    /// slots EXPLICITLY (not `deleteAll()`) so it is safe to call from `login()`
    /// AFTER the incoming account's session tokens are already saved: it must not
    /// touch access/refresh/userId/email/displayName. It does NOT push the outbox
    /// (logout does that first, while the session still lives) and does NOT
    /// destroy `.localDbKey` or drop to unauthenticated — each caller owns that
    /// final teardown (logout does deleteAll + reopen; login re-derives B's keys).
    private func switchAccountCleanup() async {
        // Deregister the APNs endpoint + drop local push bookkeeping while the
        // OUTGOING deviceId is still present (unregister() reads it and bails once
        // it's gone). Best-effort. On a post-expiry switch the outgoing session is
        // already dead so the server call no-ops, but the local reset still keeps
        // account A's push state out of account B.
        await PushNotificationManager.shared.unregister()
        PollingPushManager.shared.reset()
        // Crypto-shred the read-cache rows (decrypted body + titles) BEFORE the
        // key slots go, so account B can never read account A's cached notes. The
        // open DB queue is still valid here (the passphrase — `.localDbKey` — is
        // preserved; logout does the deleteAll + reopen re-key itself afterward).
        NoteStore.shared.wipe()
        // Delete the outgoing account's derived-key + device + attest + sync-cursor
        // slots. NOT the session tokens / userId / profile: login() owns those for
        // the incoming account (saved around this call), and logout() clears them
        // via the deleteAll() it runs after this returns.
        for key in [KeychainService.Key.masterKey, .vaultKey, .sharingPrivateKey,
                    .sharingPublicKey, .signingPrivateKey, .deviceId,
                    .attestKeyId, .attestCachedToken,
                    .syncCursor, .syncCursorId] {
            keychain.delete(key: key)
        }
        // The earlier-identity latch, its vault keys and the blobs held for the
        // union belong to the outgoing account. Reset here: otherwise, after a
        // sign-out and sign-in in one process, the next account would never fetch
        // its own earlier identities, and `vaultKeys()` would still return the
        // last account's until a restart. BEFORE the SDK wipe below: the reset is
        // also what makes a load still on the network drop its answer, so nothing
        // it imports lands after the wipe. The re-check's pending flag and window
        // go with them.
        PreviousIdentityLoader.shared.reset()
        IdentityRecheck.shared.clear()
        // Wipe the SDK's in-memory + persisted keys (X25519 sharing key + Ed25519
        // signing seed) so the outgoing user's keys don't linger in the SDK's
        // KeyStorageCallback slot, as in the Track iOS app. A delete the platform
        // refuses is owed, and paid before the next load.
        OwedWipe.clear(SDKCrypto.cryptoManager)
        // Clear the app-group widget snapshot + any pending share-extension draft
        // (both carry decrypted note titles / body snippets).
        SharedAppGroup.writeSnapshot([])
        SharedAppGroup.setPendingDraft(nil)
        WidgetCenter.shared.reloadAllTimelines()
        // Sweep decrypted attachment plaintext staged for QuickLook that a crash
        // left in tmp/ — still account-scoped decrypted content.
        AttachmentService.clearScratch()
        AttestationManager.shared.resetToken()
        // Reset the shared-notes inbox singleton so decrypted shared-note
        // titles/bodies + unwrapped content keys from account A don't linger in
        // memory for account B on the same device.
        SharesInboxStore.shared.reset()
        // Per-account TOFU sender-key pins and per-item anti-rollback floors —
        // account-scoped state that must not carry account A's values into
        // account B on a shared device. Mirrors note-android LocalDataWiper.
        SenderKeyPinStore.shared.reset()
        NoteGenFloorStore.shared.reset()
        // Retired content keys an earlier version kept, every account's.
        Self.dropRetiredContentKeys()
        // Per-note editor-mode pins. Note ids are not scoped to an account, so
        // a leftover pin would silently apply to whatever the incoming
        // account's note with that id happens to be. `resetAccountState` drops
        // the store's in-memory companions to that mirror — the cached metadata
        // item id, which `fetch` falls back to and would otherwise have B
        // PUT into A's row, and the unknown-field `extras` A's blob carried.
        NotebookMetadataStore.clearPinCache()
        NotebookMetadataStore.resetAccountState()
        // Purge decrypted content the OS still holds in Notification Center:
        // delivered banners (pinned-note titles, share invites) and pending
        // requests carry plaintext note titles. Without this they survive a switch.
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }

    // MARK: - Account Deletion

    /// Zero-knowledge SRP step-up. Proves possession of the password to the
    /// server WITHOUT transmitting it, returning a short-lived `reauth_token`
    /// for a sensitive action (currently account delete). Mirrors the login
    /// handshake — srpStep1 → srpComputeLoginProof → srpStep2 — but against the
    /// authenticated /auth/reauth/srp/* endpoints, which identify the user from
    /// the session rather than an emailed identity. A wrong password fails proof
    /// verification server-side and throws (401), the same failure surface as
    /// login.
    func reauthenticate(password: String) async throws -> String {
        // SRP binds the proof to the account's identity string, so the email
        // must match what the server uses. currentUser.email is the server's
        // canonical value (from /auth/me); fall back to a fresh /auth/me when
        // the in-memory user isn't loaded.
        let email: String
        if let cached = currentUser?.email {
            email = cached
        } else {
            email = try await api.getMe().email
        }

        let step1 = try await api.reauthStep1()
        let proof = try srpComputeLoginProof(
            email: email,
            password: password,
            saltB64: step1.salt,
            bcryptSalt: step1.bcryptSalt ?? "",
            serverPublicB64: step1.serverPublic
        )
        let step2: ReauthStep2Response
        do {
            step2 = try await api.reauthStep2(
                sessionId: step1.sessionId,
                clientPublic: proof.clientPublic,
                clientProof: proof.clientProof
            )
        } catch {
            throw Self.reauthRefusal(error)
        }
        // The reauth token is used only if the server proved it holds this
        // account's verifier.
        guard Self.serverProofMatches(proof, serverProof: step2.serverProof) else {
            throw AuthError.reauthServerProofRejected
        }
        return step2.reauthToken
    }

    /// The step-up's refusal as this app says it: a wrong password fails the
    /// proof server-side (401 `invalid_credentials`) and is
    /// `reauthWrongPassword`, never the server's words. Its other 401, an
    /// expired handshake, and everything else pass through, to be said as any
    /// other failure (`plainText`).
    nonisolated static func reauthRefusal(_ error: Error) -> Error {
        if let refused = error as? APIError, refused.status == 401, refused.code == "invalid_credentials" {
            return AuthError.reauthWrongPassword
        }
        return error
    }

    /// Permanently delete the current account (GDPR Article 17).
    ///
    /// The account is the AUTH-service account, not a per-app one: deleting it
    /// deletes the user and the data of every app hanging off it, so this
    /// destroys the user's Track data as well as their notes.
    /// DeleteAccountSheet says so before this is reached.
    ///
    /// Proves the password via a zero-knowledge SRP step-up
    /// ([reauthenticate]) — the raw password never leaves the device — then
    /// runs the same local cleanup logout() does, so the caller doesn't end up
    /// in a half-signed-out UI against an account that no longer exists.
    ///
    /// The caller must NOT try to show `billingNeedsAttention` itself: this
    /// logs out, which swaps the whole view tree and takes any sheet-level
    /// alert with it. The notice is published on `postDeletionNotice`
    /// and raised at the root instead (NoteApp).
    @discardableResult
    func deleteAccount(
        password: String,
        forfeitCreditBalance: Bool = false
    ) async throws -> DeleteAccountResponse {
        let token = try await reauthenticate(password: password)
        let result = try await api.deleteAccount(
            reauthToken: token,
            forfeitCreditBalance: forfeitCreditBalance
        )

        // Publish BEFORE the logout that replaces the view tree, so the root has
        // it to show. Deliberately not cleared by `logout()` — this outlives the
        // session on purpose, because the session is the thing that just ended.
        postDeletionNotice = Self.deletionNotice(
            billingNeedsAttention: result.billingNeedsAttention,
            appStoreRemaining: result.appStoreSubscriptionsRemaining,
            cancellationsFailed: result.subscriptionCancellationsFailed,
            dataErasure: result.dataErasure
        )

        // logout()'s outbox drain is a no-op worth keeping: it targets an
        // account the server has already erased, and every request it makes
        // fails against a revoked session. The local teardown after it — the
        // part that matters here — is identical either way, and sharing the one
        // path keeps a future addition to it from being missed on delete.
        // An erasure keeps nothing: no last keep of the page's trust, and the
        // kept copy goes AFTER the logout, once the bridge refuses the page.
        let erased = keychain.getString(for: .userId)
        await logout(ending: .erased)
        if let erased { KeptWebTrustStore.shared.forget(erased) }
        return result
    }

    /// What to tell somebody about their money after their account is gone.
    ///
    /// The two counts are INDEPENDENT and can both be non-zero: subscriptions
    /// are unique per (user, product), so one person can hold a Note
    /// subscription bought through the App Store and a Track one billed by
    /// Paddle. If the Paddle cancellation then fails, the server reports
    /// `appStoreSubscriptionsRemaining = 1` AND
    /// `subscriptionCancellationsFailed = 1`.
    ///
    /// Both parts are reported: told only about Apple, somebody in that
    /// position cancels with Apple, believes they are done, and goes on being
    /// billed by the provider nobody mentioned — with no account left to find
    /// out from.
    ///
    /// `static` so it can be exercised without standing up a live delete.
    nonisolated static func billingNotice(appStoreRemaining: Int, cancellationsFailed: Int) -> String {
        var parts: [String] = []

        if appStoreRemaining == 1 {
            parts.append("Your App Store subscription is still running. Apple will keep charging you until you cancel it yourself: open Settings, tap your name, then Subscriptions.")
        } else if appStoreRemaining > 1 {
            parts.append("Your \(appStoreRemaining) App Store subscriptions are still running. Apple will keep charging you until you cancel them yourself: open Settings, tap your name, then Subscriptions.")
        }

        if cancellationsFailed > 0 {
            if appStoreRemaining > 0 {
                // Say plainly that this is a DIFFERENT subscription, or it reads
                // as a restatement of the Apple one and gets ignored.
                parts.append("Separately, we could not cancel a subscription that is not billed through the App Store, so you may still be charged for that one too. Write to help@support.pingolin.com and we will stop it.")
            } else {
                parts.append("We could not cancel your subscription, so you may still be charged. Write to help@support.pingolin.com and we will stop it.")
            }
        }

        // Unreachable while billingNeedsAttention is (remaining > 0 || failed >
        // 0), but if the server ever widens that flag, say something rather
        // than showing a bare "Your account is deleted, but".
        if parts.isEmpty {
            return "Your account is deleted. Your subscription may need attention — write to help@support.pingolin.com and we will check it."
        }
        return "Your account is deleted.\n\n" + parts.joined(separator: "\n\n")
    }

    /// What to say about the erasure of the location and note data.
    ///
    /// `nil` when there is nothing to say. A queued erasure is not a failure —
    /// the outboxes retry until it goes through — but somebody who asked to be
    /// erased is entitled to know it has not finished yet.
    nonisolated static func erasureNotice(dataErasure: String) -> String? {
        switch dataErasure {
        case "queued":
            return "Your locations and notes could not be erased at that moment — one of the services was unreachable. The erasure is recorded and will be retried until it goes through. If you want to know that it has, write to privacy@mail.pingolin.com."
        case "failed":
            return "We could not record the erasure of your locations and notes, so it may not have happened. Write to privacy@mail.pingolin.com and we will complete it."
        default:
            // "completed" and "not_applicable" — nothing outstanding.
            return nil
        }
    }

    /// Everything the person still needs to know after their account is gone:
    /// money first, then data. Either half may be absent.
    ///
    /// Returns nil when nothing is outstanding, which is why the caller does
    /// not gate on `billingNeedsAttention` alone — an erasure that queued
    /// while the billing was clean still needs its notice.
    nonisolated static func deletionNotice(
        billingNeedsAttention: Bool,
        appStoreRemaining: Int,
        cancellationsFailed: Int,
        dataErasure: String
    ) -> String? {
        var parts: [String] = []
        if billingNeedsAttention {
            parts.append(billingNotice(appStoreRemaining: appStoreRemaining,
                                       cancellationsFailed: cancellationsFailed))
        }
        if let e = erasureNotice(dataErasure: dataErasure) {
            parts.append(e)
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    // MARK: - Logout

    func logout(ending: SessionEnd = .signedOut) async {
        sessionEnd = ending
        // The page's last keep of its kept trust, before anything below
        // deletes `.userId` or a key: switchAccountCleanup takes the sharing key
        // and deleteAll the rest, and the bridge refuses the page without them.
        // A sign-out only: an erasure keeps nothing.
        if ending == .signedOut { await lastWebKeep() }
        // Drain the offline outbox FIRST, while the session token, vault key, and
        // SDK keys still exist, so unsynced offline creates / edits / deletes
        // reach the server before we destroy them. Best-effort — an offline /
        // expired session just leaves the rows to be wiped (logout is a
        // user-initiated destructive action). Mirrors android SettingsViewModel.
        // logout preWipe → LocalDataWiper.
        await SyncService.shared.pushPendingChanges()
        // Shared cross-account purge (push / keys / read-cache / widget /
        // notifications / per-account crypto stores). Same block login() runs on
        // an account switch — factored so the two paths can't drift (a partial
        // mirror in login() would leave the outgoing account's keys behind).
        await switchAccountCleanup()
        // End the session on the server while there is still a token to end it
        // with: after the flush and the push unregister above, which need it,
        // before the wipe below. Mirrors the Android app's LogoutOrchestrator and
        // the Track iOS app.
        await endServerSession()
        // Logout-specific teardown: destroy the session tokens AND the
        // `.localDbKey` cache passphrase. deleteAll() wipes EVERYTHING (including
        // `.attestKeyId` — see its doc — and the key slots switchAccountCleanup
        // already deleted; the re-delete is harmless). Then reopen() re-keys an
        // empty cache against a fresh passphrase so a same-process re-login writes
        // under a key the next launch can reproduce. Mirrors android
        // LocalDataWiper.clearAllTables (the actual cross-account vector).
        keychain.deleteAll()
        NoteStore.shared.reopen()
        currentUser = nil
        isAuthenticated = false
        clearTwoFactorChallenge()
    }

    /// `POST /auth/logout`, given a few seconds: a sign-out never waits on a
    /// network that is not there. Unanswered, the session is left to expire
    /// on the server.
    private func endServerSession() async {
        // Either token names the session: the refresh token still does
        // when the access token has expired.
        guard keychain.getString(for: .accessToken) != nil
            || keychain.getString(for: .refreshToken) != nil else { return }
        await Self.withDeadline(seconds: 4) { _ = try? await APIService.shared.logout() }
    }

    /// Runs `work`, cancelled once `seconds` have passed; the caller never waits
    /// longer. Same shape as track-ios's `endServerSession`.
    nonisolated static func withDeadline(seconds: Double, _ work: @escaping @Sendable () async -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await work() }
            group.addTask { try? await Task.sleep(for: .seconds(seconds)) }
            await group.next()
            group.cancelAll()
        }
    }

    var deviceId: String? { keychain.getString(for: .deviceId) }
    var masterKeyBase64: String? { keychain.getString(for: .masterKey) }
    var vaultKeyBase64: String? { keychain.getString(for: .vaultKey) }
    var sharingPrivateKeyBase64: String? { keychain.getString(for: .sharingPrivateKey) }
    var sharingPublicKey: String? { keychain.getString(for: .sharingPublicKey) }

    enum AuthError: LocalizedError {
        case noAccessToken
        case twoFactorChallengeExpired
        case vaultKeyUnavailable
        case twoFactorPasskeyOnly
        /// The server's proof M2 did not check out. Not "wrong password":
        /// the password may be right.
        case serverProofRejected
        /// The same refusal at reauth (account deletion), where "sign in" does
        /// not fit.
        case reauthServerProofRejected
        /// The password typed to confirm a sensitive action (account deletion)
        /// was refused: auth's 401 at the step-up's second step.
        case reauthWrongPassword
        /// The two-step code was wrong; the attempt takes another.
        case wrongTwoFactorCode
        /// The two-step code was used a moment ago; the attempt takes the next
        /// one.
        case twoFactorCodeJustUsed
        /// Too many wrong two-step codes: the attempt is over.
        case twoFactorAttemptOver
        /// The two-step attempt has ended: it expired, or was already used.
        case twoFactorAttemptEnded
        /// The password was right, but the account's address was never verified
        /// (auth's 403 `email_not_verified`).
        case emailNotVerified

        /// Whether the two-step attempt still takes another code after this.
        var keepsTheTwoFactorAttempt: Bool {
            self == .wrongTwoFactorCode || self == .twoFactorCodeJustUsed
        }

        var errorDescription: String? {
            switch self {
            case .noAccessToken: return "Couldn't sign in. Please try again."
            case .twoFactorChallengeExpired: return "That sign-in attempt timed out. Enter your password again."
            case .vaultKeyUnavailable: return "Couldn't open your notes on this device. Please sign in again."
            // Same words in all four apps; do not paraphrase per platform.
            case .twoFactorPasskeyOnly:
                return "This account's second step uses a passkey, which this app can't use yet. " +
                    "Add an authenticator app in your account settings, or sign in on the web."
            // The same words on every client (as the Track iOS app's
            // LoginView).
            case .serverProofRejected: return "Couldn't sign in. Please try again."
            case .reauthServerProofRejected: return "Couldn't check your password just now."
            // note-android's words for the same refusal.
            case .reauthWrongPassword: return "Invalid password"
            // The two-step lines: the Track iOS app's words.
            case .wrongTwoFactorCode: return "That code isn't right. Please try again."
            case .twoFactorCodeJustUsed: return "That code was just used. Wait for the next one and try again."
            case .twoFactorAttemptOver: return "Too many wrong codes. Please wait a while, then sign in again."
            case .twoFactorAttemptEnded: return "That sign-in has ended. Please sign in again."
            // The same line as the Track iOS app;
            // never "wrong password".
            case .emailNotVerified:
                return "Please verify your email address first. Open the link we sent you, then sign in again."
            }
        }
    }
}

/// Trim a signing-key blob to its 32-byte seed. Some accounts' server rows
/// store the full 64-byte secret (seed||pub); every consumer here expects
/// the seed. A 32-byte value passes through unchanged.
private func normalizeSigningSeedB64(_ b64: String) -> String {
    let sodium = Sodium()
    guard let raw = sodium.utils.base642bin(b64, variant: .ORIGINAL), raw.count >= 64,
          let seedB64 = sodium.utils.bin2base64(Array(raw[0..<32]), variant: .ORIGINAL)
    else { return b64 }
    return seedB64
}
