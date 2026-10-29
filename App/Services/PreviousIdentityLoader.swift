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
import os

/// Identities from before a password reset.
///
/// Note's vault key is DERIVED from the account keypair, so an email password
/// reset changes it and EVERY note stops opening at once. Nothing is lost — the
/// ciphertext is untouched — but the device holds a valid session and a library
/// it cannot read.
///
/// If the user still had their recovery key they can recover that identity in
/// the account portal, which seals it under a value the SDK derives from the key
/// this app already holds. All the crypto is in the SDK; this fetches it and
/// exposes the vault key of each recovered era.
///
/// A singleton because the decrypt path (`NoteCrypto.decrypt`) is static and
/// reached from everywhere a note is opened; there is one account per app.
final class PreviousIdentityLoader {
    static let shared = PreviousIdentityLoader()

    /// The SDK's two calls, behind a seam so the union rule is tested against the
    /// SDK's real contract: the import REPLACES the set it holds.
    struct Importer {
        var importSealed: ([PingolinNoteSDK.SealedPreviousIdentity]) throws -> Int
        var vaultKeys: () -> [String]
        /// For the log only: how many identities and signing keys the SDK holds.
        var counts: () -> (identities: Int, signingKeys: Int) = { (0, 0) }

        static let sdk = Importer(
            importSealed: { Int(try SDKCrypto.cryptoManager.importPreviousIdentities(sealed: $0)) },
            vaultKeys: { SDKCrypto.cryptoManager.previousVaultKeys() },
            counts: {
                (Int(SDKCrypto.cryptoManager.previousIdentityCount()),
                 SDKCrypto.cryptoManager.previousSigningPublicKeys().count)
            }
        )
    }

    #if DEBUG
    /// Counts and decisions only, never key material. DEBUG builds only,
    /// like `IdentityRecheck`'s: a count says how many resets the account
    /// has had.
    private static let log = Logger(subsystem: "com.pingolin.note", category: "identities")
    #endif

    private static func note(_ line: @autoclosure () -> String) {
        #if DEBUG
        let line = line()
        log.debug("\(line, privacy: .public)")
        print("[Note] identities: \(line)")
        #endif
    }

    private let lock = NSLock()
    private var loaded = false
    private var cachedVaultKeys: [String] = []
    /// Every sealed blob this session has taken in. Because the import
    /// replaces, each one passes the union, so a later answer — empty, shorter,
    /// or a lie — can only add.
    private var held: [PingolinNoteSDK.SealedPreviousIdentity] = []
    /// Bumped by `reset()`: work that started for the previous account keeps
    /// nothing it finds.
    private var generation = 0
    /// Failed start-up loads in a row, and when the next may go out (uptime;
    /// nil = at once). See `retryDelay`.
    private var failures = 0
    private var retryAt: TimeInterval?
    /// The start-up load on the network, and the session it is for. Every
    /// caller of that session waits for this one instead of sending its own
    /// GET, so the page's op and every sync don't each start one while a GET
    /// hangs. A sign-out leaves it running; its answer is dropped by the
    /// generation check.
    private var startUp: (generation: Int, task: Task<Int, Never>)?

    private let fetch: () async throws -> [PreviousIdentityResponse]
    private let importer: Importer
    private let now: () -> TimeInterval
    /// Starts the start-up load's task. A seam, so a test can hold a task back
    /// between its creation and its start.
    private let spawn: (@escaping () async -> Int) -> Task<Int, Never>

    init(
        fetch: @escaping () async throws -> [PreviousIdentityResponse] = { try await APIService.shared.getPreviousIdentities() },
        importer: Importer = .sdk,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        spawn: @escaping (@escaping () async -> Int) -> Task<Int, Never> = { operation in Task { await operation() } }
    ) {
        self.fetch = fetch
        self.importer = importer
        self.now = now
        self.spawn = spawn
    }

    /// Load once per session, before anything is decrypted.
    ///
    /// Never throws: for almost every account this imports nothing, and a
    /// failure must only mean older notes stay unreadable — not that syncing
    /// stops. A failure leaves `loaded` false so a later call retries, once
    /// the wait after it (`retryDelay`) has passed.
    ///
    /// One load per session at a time: a call made while this session's load
    /// is out waits for that one and gets its answer. The load is a task of
    /// its own, so a caller that is cancelled meanwhile (a page torn down)
    /// cancels nothing for the others, and its failure is counted once.
    @discardableResult
    func ensureLoaded() async -> Int {
        lock.lock()
        let alreadyLoaded = loaded
        let gen = generation
        let waiting = retryAt.map { now() < $0 } ?? false
        var task: Task<Int, Never>?
        if !alreadyLoaded, !waiting {
            if let out = startUp, out.generation == gen {
                task = out.task
                Self.note("load: one is already out; waiting for it")
            } else {
                let started = spawn { await self.startUpLoad(gen) }
                startUp = (gen, started)
                task = started
            }
        }
        lock.unlock()
        if alreadyLoaded { return vaultKeys().count }
        guard let task else {
            Self.note("load: not yet, waiting after a failure")
            return 0
        }
        return await task.value
    }

    /// The start-up load itself, run once for session `gen` however many wait.
    private func startUpLoad(_ gen: Int) async -> Int {
        defer {
            lock.withLock { if startUp?.generation == gen { startUp = nil } }
        }
        do {
            return try await load(forGeneration: gen).imported
        } catch {
            lock.lock()
            defer { lock.unlock() }
            // This session's own failure only: an answer dropped because the
            // session changed says nothing about the next one.
            if gen == generation, !loaded {
                failures += 1
                let delay = Self.retryDelay(afterFailures: failures)
                retryAt = now() + delay
                Self.note("load: \(failures) failure(s) in a row; the next try waits \(Int(delay)) s")
            }
            return 0
        }
    }

    /// The wait after the n-th failed start-up load in a row: 30 s, twice as
    /// long each time after, at most 5 min. Until a load succeeds there is
    /// no session for the gated re-check, so without this wait every page
    /// call and every sync would make its own GET while the server kept
    /// failing.
    static func retryDelay(afterFailures n: Int) -> TimeInterval {
        min(30 * pow(2, Double(max(n, 1) - 1)), 300)
    }

    /// Ask again after a restore elsewhere, and import the UNION with what
    /// this session already took in. True only when more earlier identities open
    /// than before; the caller re-decrypts then. The push that asks for this
    /// carries nothing: it is the same signed-in fetch and SDK import as
    /// `ensureLoaded`, and the SDK opens a blob only under a key derived from
    /// this device's own private key. Never throws.
    func recheck() async -> Bool {
        let before = vaultKeys().count
        guard let result = try? await load() else { return false }
        return result.opened > before
    }

    /// Fetch, import the union, and cache what opened: for the session
    /// `forGeneration` names, or the current one when nil.
    private func load(forGeneration expected: Int? = nil) async throws -> (imported: Int, opened: Int) {
        let gen: Int
        if let expected {
            gen = expected
        } else {
            lock.lock()
            gen = generation
            lock.unlock()
        }

        let rows: [PreviousIdentityResponse]
        do {
            rows = try await fetch()
        } catch {
            // The type only: a reply that does not decode, or no answer at all.
            Self.note("load: the fetch failed (\(String(describing: type(of: error))))")
            throw error
        }
        let sealed = rows.compactMap { row -> PingolinNoteSDK.SealedPreviousIdentity? in
            guard let blob = row.appSealedPrivateKey else { return nil }
            return PingolinNoteSDK.SealedPreviousIdentity(nonce: blob.nonce, ciphertext: blob.ciphertext)
        }

        // Re-checked after the await, and under the lock `reset()` takes, so the
        // check and the import are one step (the rule for every key load that
        // awaits the network): a sign-out or account switch while this was out
        // means these are the previous account's, and nothing is imported into
        // the next session. The lock is held only for the local import, never
        // the network.
        lock.lock()
        defer { lock.unlock() }
        guard gen == generation else {
            Self.note("load: answer dropped, the session changed while it was out")
            throw CancellationError()
        }
        // The union with what is held NOW, not when this load went out: a
        // re-check that finished meanwhile (a push at launch) took blobs in, and
        // the import replaces the SDK's set.
        var union = held
        for blob in sealed where !union.contains(blob) { union.append(blob) }
        let before = importer.counts()
        let vaultBefore = cachedVaultKeys.count
        let imported: Int
        do {
            imported = union.isEmpty ? 0 : try importer.importSealed(union)
        } catch {
            Self.note("load: import failed (\(String(describing: type(of: error))))")
            throw error
        }
        let keys = importer.vaultKeys()
        let after = importer.counts()
        Self.note("load: \(rows.count) row(s), \(sealed.count) v1 blob(s), "
            + "\(rows.filter { $0.appSealedPrivateKeyV2 != nil }.count) v2 blob(s), union \(union.count), "
            + "imported \(imported); identities \(before.identities)→\(after.identities), "
            + "signing keys \(before.signingKeys)→\(after.signingKeys), vault keys \(vaultBefore)→\(keys.count)")
        held = union
        loaded = true
        cachedVaultKeys = keys
        failures = 0
        retryAt = nil
        return (imported, keys.count)
    }

    /// Whether this session's first load has been taken in.
    var isLoaded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return loaded
    }

    /// Bumped by every `reset()`. A caller that awaits `ensureLoaded` for someone
    /// else (the page's bridge op) compares it before and after.
    var currentGeneration: Int {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    /// Vault keys for each recovered era, newest first. Cached because the
    /// decrypt path calls this per note during a sync.
    func vaultKeys() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return cachedVaultKeys
    }

    /// Sign-out and account switch: the next account fetches its own, and
    /// nothing held for the union survives into it.
    func reset() {
        lock.lock()
        generation += 1
        loaded = false
        cachedVaultKeys = []
        held = []
        failures = 0
        retryAt = nil
        lock.unlock()
    }
}
