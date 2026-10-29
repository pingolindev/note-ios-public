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

/// Tests for the identity re-check: at most one re-check per window, one
/// pending flag for whatever was refused, the union (an empty answer takes
/// nothing away), sign-out clears everything, and the push is read for its
/// kind only. The clock and the wait are manual.
///
/// The loader's clock for the wait after a failed start-up load. Read from
/// the loader's lock, so not tied to the main actor like `ManualTime`.
private final class LoaderClock {
    var t: TimeInterval = 0
}

private struct ServerDown: Error {}

@MainActor
final class IdentityRecheckTests: XCTestCase {

    /// A clock the test moves, and sleepers it wakes. MainActor, like the
    /// re-check, so nothing hops executors and a few yields settle everything.
    @MainActor
    private final class ManualTime {
        var t: TimeInterval = 0
        private var sleepers: [(wake: TimeInterval, done: CheckedContinuation<Void, Never>)] = []

        func sleep(until deadline: TimeInterval) async {
            if deadline <= t { return }
            await withCheckedContinuation { sleepers.append((deadline, $0)) }
        }

        func advance(to newT: TimeInterval) async {
            t = newT
            let due = sleepers.filter { $0.wake <= t }
            sleepers.removeAll { $0.wake <= t }
            due.forEach { $0.done.resume() }
            await settle()
        }

        func settle() async {
            for _ in 0..<100 { await Task.yield() }
        }
    }

    private func makeRecheck(_ time: ManualTime, recheck: @escaping @MainActor () async -> Bool) -> IdentityRecheck {
        let r = IdentityRecheck()
        r.now = { time.t }
        r.sleepUntil = { await time.sleep(until: $0) }
        r.recheck = recheck
        r.somethingLocked = { false }
        r.afterNewIdentity = { _ in }
        return r
    }

    // MARK: - The limits

    func testManyNudgesInsideTheWindowMakeExactlyOneRequestWhenItEnds() async {
        let time = ManualTime()
        var requests = 0
        let r = makeRecheck(time) { requests += 1; return false }

        await r.nudge()
        XCTAssertEqual(requests, 1)
        for i in 1...12 {
            await time.advance(to: Double(i) * 10)
            await r.nudge()
        }
        XCTAssertEqual(requests, 1, "nothing inside the window")

        await time.advance(to: IdentityRecheck.window - 0.1)
        XCTAssertEqual(requests, 1)
        await time.advance(to: IdentityRecheck.window)
        XCTAssertEqual(requests, 2, "one request when the window ends")
        await time.advance(to: 10 * IdentityRecheck.window)
        XCTAssertEqual(requests, 2, "and nothing after it")
    }

    func testANudgeDuringARunningRecheckMakesExactlyOneFollowUp() async {
        let time = ManualTime()
        var requests = 0
        var release: CheckedContinuation<Void, Never>?
        let r = makeRecheck(time) {
            requests += 1
            if requests == 1 { await withCheckedContinuation { release = $0 } }
            return false
        }

        let first = Task { await r.nudge() }
        await time.settle()
        XCTAssertEqual(requests, 1)
        for _ in 0..<5 { await r.nudge() }
        XCTAssertEqual(requests, 1, "the running one is not doubled")

        release?.resume()
        await first.value
        await time.advance(to: IdentityRecheck.window)
        XCTAssertEqual(requests, 2, "exactly one follow-up")
        await time.advance(to: 10 * IdentityRecheck.window)
        XCTAssertEqual(requests, 2)
    }

    func testSignOutClearsThePendingFlagAndTheWindow() async {
        let time = ManualTime()
        var requests = 0
        let r = makeRecheck(time) { requests += 1; return false }

        await r.nudge()
        for _ in 0..<3 { await r.nudge() }
        r.clear()
        await time.advance(to: 2 * IdentityRecheck.window)
        XCTAssertEqual(requests, 1, "the refused nudges never run for the next account")

        await r.nudge()
        XCTAssertEqual(requests, 2, "no window carried over")
    }

    func testTheForegroundRechecksOnlyWhileSomethingIsLocked() async {
        let time = ManualTime()
        var requests = 0
        let r = makeRecheck(time) { requests += 1; return false }

        await r.foreground()
        XCTAssertEqual(requests, 0, "nothing locked, nothing pending: no request")
        r.somethingLocked = { true }
        await r.foreground()
        XCTAssertEqual(requests, 1)
    }

    func testOnlyARecheckThatOpenedSomethingNewReDecrypts() async {
        let time = ManualTime()
        var opensSomethingNew = false
        var reloads = 0
        let r = makeRecheck(time) { opensSomethingNew }
        r.afterNewIdentity = { _ in reloads += 1 }

        await r.nudge()
        XCTAssertEqual(reloads, 0)
        opensSomethingNew = true
        await time.advance(to: IdentityRecheck.window)
        await r.nudge()
        XCTAssertEqual(reloads, 1)
    }

    // MARK: - The union

    private final class ReplacingSDK {
        var held: [SealedPreviousIdentity] = []
        var imports: [[SealedPreviousIdentity]] = []

        var importer: PreviousIdentityLoader.Importer {
            PreviousIdentityLoader.Importer(
                importSealed: { [unowned self] in
                    self.held = $0
                    self.imports.append($0)
                    return $0.count
                },
                vaultKeys: { [unowned self] in self.held.map { "vault-\($0.nonce)" } }
            )
        }
    }

    private func row(_ n: Int) -> PreviousIdentityResponse {
        PreviousIdentityResponse(
            keyVersion: n,
            appSealedPrivateKey: SealedPreviousIdentityResponse(nonce: "n\(n)", ciphertext: "c\(n)")
        )
    }

    func testAnEmptyAnswerAfterAGoodOneLeavesTheCountUnchanged() async {
        let sdk = ReplacingSDK()
        var answers: [[PreviousIdentityResponse]] = [[row(1)], []]
        let loader = PreviousIdentityLoader(fetch: { answers.removeFirst() }, importer: sdk.importer)

        let first = await loader.recheck()
        XCTAssertTrue(first)
        XCTAssertEqual(loader.vaultKeys().count, 1)

        let second = await loader.recheck()
        XCTAssertFalse(second, "an empty answer opens nothing new")
        XCTAssertEqual(loader.vaultKeys().count, 1, "and takes nothing away")
        XCTAssertEqual(sdk.imports.last?.map(\.nonce), ["n1"], "the import carried the union")
    }

    func testALaterAnswerAddsToTheUnion() async {
        let sdk = ReplacingSDK()
        var answers: [[PreviousIdentityResponse]] = [[row(1)], [row(2)]]
        let loader = PreviousIdentityLoader(fetch: { answers.removeFirst() }, importer: sdk.importer)

        _ = await loader.recheck()
        let second = await loader.recheck()
        XCTAssertTrue(second)
        XCTAssertEqual(sdk.imports.last?.map(\.nonce), ["n1", "n2"])
    }

    func testSignOutDropsTheHeldBlobs() async {
        let sdk = ReplacingSDK()
        var answers: [[PreviousIdentityResponse]] = [[row(1)], [row(2)]]
        let loader = PreviousIdentityLoader(fetch: { answers.removeFirst() }, importer: sdk.importer)

        _ = await loader.recheck()
        loader.reset()
        XCTAssertEqual(loader.vaultKeys().count, 0)
        _ = await loader.recheck()
        XCTAssertEqual(sdk.imports.last?.map(\.nonce), ["n2"], "the next account's import carries none of the last one's")
    }

    // MARK: - A sign-out while a load is on the network

    /// A fetch whose FIRST call waits until the test lets it answer; later calls
    /// answer at once with `later`.
    private final class HeldFetch {
        private let lock = NSLock()
        private var release: CheckedContinuation<Void, Never>?
        private var started = false
        private var calls = 0

        func fetch(answer: [PreviousIdentityResponse], later: [PreviousIdentityResponse] = []) async -> [PreviousIdentityResponse] {
            lock.lock(); calls += 1; let first = calls == 1; lock.unlock()
            guard first else { return later }
            await withCheckedContinuation { c in
                lock.lock(); release = c; started = true; lock.unlock()
            }
            return answer
        }

        var isOut: Bool { lock.lock(); defer { lock.unlock() }; return started }

        func answerNow() { lock.lock(); let c = release; release = nil; lock.unlock(); c?.resume() }
    }

    private func waitUntilOut(_ held: HeldFetch) async {
        while !held.isOut { await Task.yield() }
    }

    func testASignOutWhileTheRecheckIsOutAddsNothing() async {
        let sdk = ReplacingSDK()
        let held = HeldFetch()
        let answer = [row(1)]
        let loader = PreviousIdentityLoader(fetch: { await held.fetch(answer: answer) }, importer: sdk.importer)

        let result = Task { await loader.recheck() }
        await waitUntilOut(held)
        loader.reset()
        held.answerNow()

        let opened = await result.value
        XCTAssertFalse(opened)
        XCTAssertTrue(sdk.imports.isEmpty, "nothing imported into the next session")
        XCTAssertEqual(loader.vaultKeys().count, 0)
    }

    func testASignOutWhileTheStartUpLoadIsOutAddsNothing() async {
        let sdk = ReplacingSDK()
        let held = HeldFetch()
        let answer = [row(1)]
        let loader = PreviousIdentityLoader(fetch: { await held.fetch(answer: answer) }, importer: sdk.importer)

        let result = Task { await loader.ensureLoaded() }
        await waitUntilOut(held)
        loader.reset()
        held.answerNow()

        let imported = await result.value
        XCTAssertEqual(imported, 0)
        XCTAssertTrue(sdk.imports.isEmpty)
    }

    /// The page's bridge op: a page from before a sign-out gets nothing, not the
    /// old account's keys and not the next account's, even when the next
    /// account's own load finished first.
    func testTheBridgeHandsThePageNothingLoadedAcrossASignOut() async {
        let sdk = ReplacingSDK()
        let held = HeldFetch()
        let answer = [row(1)]
        let next = [row(2)]
        let loader = PreviousIdentityLoader(fetch: { await held.fetch(answer: answer, later: next) }, importer: sdk.importer)

        let result = Task { await WebKeyBridge.previousVaultKeys(from: loader, pageAsked: nil) }
        await waitUntilOut(held)
        loader.reset()
        await loader.ensureLoaded()          // the next account's own load
        XCTAssertEqual(loader.vaultKeys(), ["vault-n2"])
        held.answerNow()

        let handed = await result.value
        XCTAssertEqual(handed, [], "the old page gets nothing")
        XCTAssertEqual(sdk.imports.map { $0.map(\.nonce) }, [["n2"]], "the old answer was never imported")
    }

    func testTheBridgeHandsThePageWhatOpenedOtherwise() async {
        let sdk = ReplacingSDK()
        let answer = [row(1)]
        let loader = PreviousIdentityLoader(fetch: { answer }, importer: sdk.importer)
        let handed = await WebKeyBridge.previousVaultKeys(from: loader, pageAsked: nil)
        XCTAssertEqual(handed, ["vault-n1"])
    }

    func testASignOutDuringTheRecheckReDecryptsNothing() async {
        let time = ManualTime()
        var release: CheckedContinuation<Void, Never>?
        var reloads = 0
        let r = makeRecheck(time) {
            await withCheckedContinuation { release = $0 }
            return true
        }
        r.afterNewIdentity = { _ in reloads += 1 }

        let first = Task { await r.nudge() }
        await time.settle()
        r.clear()
        release?.resume()
        await first.value
        XCTAssertEqual(reloads, 0)
    }

    func testEnsureLoadedAfterARecheckDoesNotFetchAgain() async {
        let sdk = ReplacingSDK()
        var fetches = 0
        let loader = PreviousIdentityLoader(fetch: { fetches += 1; return [] }, importer: sdk.importer)

        _ = await loader.recheck()
        await loader.ensureLoaded()
        XCTAssertEqual(fetches, 1)
    }

    // MARK: - The page's locked signal (the bridge op asks again)

    /// This app never caches a note it could not open, so after a sign-in that
    /// follows a reset nothing looks locked here. The page knows better: it asks
    /// the bridge again when it comes back with notes still locked.
    func testAPageThatComesBackWithLockedNotesGetsOneRecheckInTheWindow() async {
        let time = ManualTime()
        let sdk = ReplacingSDK()
        var gets = 0
        let answer = [row(1)]
        let loader = PreviousIdentityLoader(fetch: { gets += 1; return gets == 1 ? [] : answer }, importer: sdk.importer)
        let r = makeRecheck(time) { await loader.recheck() }
        r.somethingLocked = { false }   // nothing locked in the cache
        var told = [Bool]()
        r.afterNewIdentity = { told.append($0) }
        let ask = { await WebKeyBridge.previousVaultKeys(from: loader, pageAsked: { await r.pageAsked() }) }

        let first = await ask()
        XCTAssertEqual(first, [], "the start-up load: nothing restored yet")
        XCTAssertEqual(gets, 1)
        await r.foreground()
        XCTAssertEqual(gets, 1, "the cache shows nothing locked, so the foreground asks nothing")

        let second = await ask()
        XCTAssertEqual(gets, 2, "the page asked again: one re-check")
        XCTAssertEqual(second, ["vault-n1"], "and the page gets what it opened")
        XCTAssertEqual(told, [false], "the page's own request needs no event back")

        _ = await ask()
        _ = await ask()
        XCTAssertEqual(gets, 2, "no second GET inside the window")
    }

    /// A page call after sign-out stores nothing. Sign-out deletes the
    /// sharing key before it resets the loader, and the bridge serves nothing
    /// without one, so the call never reaches the loader, even while the old
    /// session's tokens (deleted last) would still answer.
    func testAPageCallAfterSignOutStoresNothing() async {
        let time = ManualTime()
        let sdk = ReplacingSDK()
        var signedIn = true
        var gets = 0
        let old = [row(1)]
        let loader = PreviousIdentityLoader(fetch: { gets += 1; return old }, importer: sdk.importer)
        let r = makeRecheck(time) { await loader.recheck() }
        let keys = WebKeyBridge.KeySource(
            sharingPrivateKeyBase64: { signedIn ? Data(repeating: 7, count: 32).base64EncodedString() : nil },
            signingSeedBase64: { nil },
            userId: { "7d0e7f7c-0000-4000-8000-000000000001" },
            previousVaultKeys: { await WebKeyBridge.previousVaultKeys(from: loader, pageAsked: { await r.pageAsked() }) }
        )
        let op: [String: Any] = ["op": "previousVaultKeys"]

        guard case .success = await WebKeyBridge.handle(op, keys: keys) else { return XCTFail("signed in, the op is served") }
        XCTAssertEqual(gets, 1)

        signedIn = false                 // switchAccountCleanup: the key slots go first,
        loader.reset()                   // then the loader and the gate
        r.clear()
        sdk.imports.removeAll()
        sdk.held.removeAll()

        for _ in 0..<3 {
            guard case .failure(.signedOut) = await WebKeyBridge.handle(op, keys: keys) else {
                return XCTFail("signed out, the op is refused")
            }
        }
        await time.advance(to: IdentityRecheck.window * 2)
        XCTAssertEqual(gets, 1, "no GET after sign-out, and nothing pending")
        XCTAssertTrue(sdk.imports.isEmpty, "nothing was stored")
        XCTAssertFalse(loader.isLoaded)
        XCTAssertEqual(loader.vaultKeys(), [])
    }

    func testAHostilePageSpammingTheOpMakesAtMostOneGetPerWindow() async {
        let time = ManualTime()
        let sdk = ReplacingSDK()
        var getTimes = [TimeInterval]()
        let loader = PreviousIdentityLoader(fetch: { getTimes.append(await time.t); return [] }, importer: sdk.importer)
        let r = makeRecheck(time) { await loader.recheck() }
        let ask = { await WebKeyBridge.previousVaultKeys(from: loader, pageAsked: { await r.pageAsked() }) }

        _ = await ask()                       // start-up load at t = 0
        for i in 1...100 {
            await time.advance(to: Double(i) * 6)
            _ = await ask()
        }
        await time.advance(to: 700)
        let rechecks = Array(getTimes.dropFirst())
        XCTAssertFalse(rechecks.isEmpty)
        for (a, b) in zip(rechecks, rechecks.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b - a, IdentityRecheck.window, "two GETs \(b - a) s apart: \(rechecks)")
        }
        XCTAssertLessThanOrEqual(rechecks.count, 4, "600 s of spam: at most one GET per 180 s window: \(rechecks)")
    }

    // MARK: - The wait after a failed start-up load

    /// A fetch whose FIRST call waits until the test lets it fail; later calls
    /// answer at once with nothing.
    private final class HeldFailure {
        private let lock = NSLock()
        private var release: CheckedContinuation<Void, Never>?
        private var started = false
        private var calls = 0

        func fetch() async throws -> [PreviousIdentityResponse] {
            lock.lock(); calls += 1; let first = calls == 1; lock.unlock()
            guard first else { return [] }
            await withCheckedContinuation { c in
                lock.lock(); release = c; started = true; lock.unlock()
            }
            throw ServerDown()
        }

        var isOut: Bool { lock.lock(); defer { lock.unlock() }; return started }

        func failNow() { lock.lock(); let c = release; release = nil; lock.unlock(); c?.resume() }
    }

    func testAFailingStartUpLoadWaits30sThenLongerUpTo5Min() async {
        let clock = LoaderClock()
        let sdk = ReplacingSDK()
        var getTimes = [TimeInterval]()
        let loader = PreviousIdentityLoader(fetch: { getTimes.append(clock.t); throw ServerDown() },
                                            importer: sdk.importer, now: { clock.t })
        for second in stride(from: 0.0, through: 1200.0, by: 5.0) {
            clock.t = second
            await loader.ensureLoaded()
        }
        XCTAssertEqual(getTimes, [0, 30, 90, 210, 450, 750, 1050], "30, 60, 120, 240 s apart, then 300 at most")
        XCTAssertFalse(loader.isLoaded)
    }

    /// Until a start-up load succeeds the page's call is never a repeat, so
    /// the re-check's window does not apply: the wait is what bounds it.
    func testAHostilePageSpammingWhileTheStartUpLoadFailsWaitsBetweenGets() async {
        let time = ManualTime()
        let clock = LoaderClock()
        let sdk = ReplacingSDK()
        var getTimes = [TimeInterval]()
        let loader = PreviousIdentityLoader(fetch: { getTimes.append(clock.t); throw ServerDown() },
                                            importer: sdk.importer, now: { clock.t })
        let r = makeRecheck(time) { await loader.recheck() }
        for second in 0..<600 {
            clock.t = Double(second)
            _ = await WebKeyBridge.previousVaultKeys(from: loader, pageAsked: { await r.pageAsked() })
        }
        XCTAssertEqual(getTimes, [0, 30, 90, 210, 450], "600 calls in 600 s: 5 GETs")
    }

    func testSignOutEndsTheWait() async {
        let clock = LoaderClock()
        let sdk = ReplacingSDK()
        var down = true
        var gets = 0
        let loader = PreviousIdentityLoader(fetch: { gets += 1; if down { throw ServerDown() }; return [] },
                                            importer: sdk.importer, now: { clock.t })
        await loader.ensureLoaded()               // fails at t = 0: the next try waits 30 s
        clock.t = 10
        await loader.ensureLoaded()
        XCTAssertEqual(gets, 1, "still waiting")

        loader.reset()                            // sign-out; the next account
        down = false
        await loader.ensureLoaded()
        XCTAssertEqual(gets, 2, "a new session loads at once")
        XCTAssertTrue(loader.isLoaded)
    }

    func testAFailureFromBeforeASignOutDoesNotMakeTheNextSessionWait() async {
        let clock = LoaderClock()
        let sdk = ReplacingSDK()
        let held = HeldFailure()
        var gets = 0
        let loader = PreviousIdentityLoader(fetch: { gets += 1; return try await held.fetch() },
                                            importer: sdk.importer, now: { clock.t })

        let old = Task { await loader.ensureLoaded() }
        while !held.isOut { await Task.yield() }
        loader.reset()                            // sign-out while the old load is out
        held.failNow()
        _ = await old.value

        await loader.ensureLoaded()               // the next session, same instant
        XCTAssertEqual(gets, 2, "the old session's failure made the next one wait")
        XCTAssertTrue(loader.isLoaded)
    }

    // MARK: - One start-up load at a time

    /// A fetch that counts its calls and holds every one until the test lets
    /// them all answer (the n-th call with `answers[n]`, the last one after
    /// that) or fail; calls after that answer at once, so a broken loader
    /// fails the test instead of hanging it. Notes whether a call it held was
    /// cancelled.
    private final class GateFetch {
        private let lock = NSLock()
        private var held: [CheckedContinuation<Void, Never>] = []
        private var calls = 0
        private var open = false
        private var failing = false
        private var sawCancellation = false

        func fetch(_ answers: [[PreviousIdentityResponse]]) async throws -> [PreviousIdentityResponse] {
            lock.lock(); let n = calls; calls += 1; let waits = !open; lock.unlock()
            if waits {
                await withCheckedContinuation { c in
                    lock.lock()
                    if open { lock.unlock(); c.resume() } else { held.append(c); lock.unlock() }
                }
            }
            lock.lock(); let fail = failing; lock.unlock()
            if Task.isCancelled {
                lock.lock(); sawCancellation = true; lock.unlock()
                throw CancellationError()
            }
            if fail { throw ServerDown() }
            return answers.isEmpty ? [] : answers[min(n, answers.count - 1)]
        }

        var callCount: Int { lock.lock(); defer { lock.unlock() }; return calls }
        var heldCount: Int { lock.lock(); defer { lock.unlock() }; return held.count }
        var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return sawCancellation }

        func answerAll() {
            lock.lock(); open = true; let all = held; held = []; lock.unlock()
            all.forEach { $0.resume() }
        }

        func failAll() {
            lock.lock(); failing = true; lock.unlock()
            answerAll()
        }
    }

    /// Yields until `done` holds or the budget runs out; returns whether it held.
    @discardableResult
    private func settle(until done: () -> Bool, yields: Int = 2_000) async -> Bool {
        for _ in 0..<yields where !done() { await Task.yield() }
        return done()
    }

    func testCallsWhileTheStartUpLoadIsOutShareOneGet() async {
        let sdk = ReplacingSDK()
        let gate = GateFetch()
        let answer = [row(1)]
        let loader = PreviousIdentityLoader(fetch: { try await gate.fetch([answer]) }, importer: sdk.importer)

        let syncs = (0..<10).map { _ in Task { await loader.ensureLoaded() } }
        let pages = (0..<10).map { _ in Task { await WebKeyBridge.previousVaultKeys(from: loader, pageAsked: nil) } }
        await settle(until: { gate.heldCount >= 1 })
        await settle(until: { gate.callCount > 1 }, yields: 500)   // time for every caller to come in
        XCTAssertEqual(gate.callCount, 1, "one GET while it hangs, not one per page call or sync")

        gate.answerAll()
        for sync in syncs {
            let imported = await sync.value
            XCTAssertEqual(imported, 1)
        }
        for page in pages {
            let handed = await page.value
            XCTAssertEqual(handed, ["vault-n1"])
        }
        XCTAssertEqual(gate.callCount, 1)
        XCTAssertEqual(sdk.imports.count, 1)
    }

    func testAFailureTheCallersSharedCountsOnce() async {
        let clock = LoaderClock()
        let sdk = ReplacingSDK()
        let gate = GateFetch()
        let loader = PreviousIdentityLoader(fetch: { try await gate.fetch([]) }, importer: sdk.importer, now: { clock.t })

        let waiting = (0..<5).map { _ in Task { await loader.ensureLoaded() } }
        await settle(until: { gate.heldCount >= 1 })
        await settle(until: { gate.callCount > 1 }, yields: 500)
        gate.failAll()
        for w in waiting {
            let imported = await w.value
            XCTAssertEqual(imported, 0)
        }
        XCTAssertEqual(gate.callCount, 1)

        clock.t = 29
        await loader.ensureLoaded()
        XCTAssertEqual(gate.callCount, 1, "still in the wait after the failure")
        clock.t = 30
        let next = Task { await loader.ensureLoaded() }
        await settle(until: { gate.callCount == 2 })
        XCTAssertEqual(gate.callCount, 2, "one failure counted: the next try is 30 s later, not 60 s or more")
        gate.answerAll()
        _ = await next.value
    }

    /// A page torn down while the load is out (its task cancelled): the one
    /// GET is not cancelled, and the other callers get its answer.
    func testACancelledCallerNeitherCancelsTheLoadNorFailsTheOthers() async {
        let sdk = ReplacingSDK()
        let gate = GateFetch()
        let answers = [[row(1)]]
        let loader = PreviousIdentityLoader(fetch: { try await gate.fetch(answers) }, importer: sdk.importer)

        let torn = Task { await WebKeyBridge.previousVaultKeys(from: loader, pageAsked: nil) }
        await settle(until: { gate.heldCount >= 1 })
        let others = (0..<3).map { _ in Task { await loader.ensureLoaded() } }
        await settle(until: { gate.callCount > 1 }, yields: 500)
        torn.cancel()
        await settle(until: { false }, yields: 100)
        gate.answerAll()

        for other in others {
            let imported = await other.value
            XCTAssertEqual(imported, 1, "the others get the answer")
        }
        _ = await torn.value
        XCTAssertFalse(gate.cancelled, "the shared GET was cancelled with the page")
        XCTAssertEqual(gate.callCount, 1)
        XCTAssertTrue(loader.isLoaded)
        XCTAssertEqual(loader.vaultKeys(), ["vault-n1"])
        // Nothing was counted as a failure, and nothing is loaded again.
        await loader.ensureLoaded()
        XCTAssertEqual(gate.callCount, 1)
    }

    /// A sign-out while the shared load is out: the next session's first call
    /// sends its own GET at once, and the old answer is imported nowhere.
    func testASignOutWhileTheSharedLoadIsOutLetsTheNextSessionLoadItsOwn() async {
        let sdk = ReplacingSDK()
        let gate = GateFetch()
        let answers = [[row(1)], [row(2)]]
        let loader = PreviousIdentityLoader(fetch: { try await gate.fetch(answers) }, importer: sdk.importer)

        let old = (0..<3).map { _ in Task { await loader.ensureLoaded() } }
        await settle(until: { gate.heldCount >= 1 })
        await settle(until: { gate.callCount > 1 }, yields: 500)
        loader.reset()                                  // sign-out; the next account
        let next = Task { await loader.ensureLoaded() }
        await settle(until: { gate.heldCount >= 2 })
        XCTAssertEqual(gate.callCount, 2, "the next session sends its own GET")

        gate.answerAll()
        for o in old {
            let imported = await o.value
            XCTAssertEqual(imported, 0, "the ended session's callers get nothing")
        }
        let imported = await next.value
        XCTAssertEqual(imported, 1)
        XCTAssertEqual(sdk.imports.map { $0.map(\.nonce) }, [["n2"]], "the old answer was imported nowhere")
        XCTAssertEqual(loader.vaultKeys(), ["vault-n2"])
    }

    /// Holds back the tasks a loader starts until the test lets them run;
    /// tasks started after that run at once.
    private final class HeldStart {
        private let lock = NSLock()
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private var open = false

        func spawn(_ operation: @escaping () async -> Int) -> Task<Int, Never> {
            Task {
                await withCheckedContinuation { c in
                    self.lock.lock()
                    if self.open { self.lock.unlock(); c.resume() } else { self.waiting.append(c); self.lock.unlock() }
                }
                return await operation()
            }
        }

        var heldCount: Int { lock.lock(); defer { lock.unlock() }; return waiting.count }

        func letRun() {
            lock.lock(); open = true; let all = waiting; waiting = []; lock.unlock()
            all.forEach { $0.resume() }
        }
    }

    /// A sign-out between the start-up task's creation and its start: the task
    /// loads for the session that asked, so its answer is dropped, and nothing
    /// lands in the next account's session.
    func testALoadThatStartsAfterASignOutStoresNothingForTheNextSession() async {
        let sdk = ReplacingSDK()
        let gate = GateFetch()
        let start = HeldStart()
        let answers = [[row(1)]]
        let loader = PreviousIdentityLoader(fetch: { try await gate.fetch(answers) }, importer: sdk.importer,
                                            spawn: start.spawn)

        let old = Task { await loader.ensureLoaded() }
        await settle(until: { start.heldCount >= 1 })     // made, not started
        loader.reset()                                    // sign-out before it starts
        start.letRun()
        await settle(until: { gate.heldCount >= 1 })
        gate.answerAll()

        let imported = await old.value
        XCTAssertEqual(imported, 0)
        XCTAssertTrue(sdk.imports.isEmpty, "the answer was imported into the next session")
        XCTAssertFalse(loader.isLoaded)
    }

    /// A re-check that lands while the start-up load is out (a push at
    /// launch): the start-up load's import keeps what the re-check took in,
    /// because the SDK's import replaces its set.
    func testTheStartUpLoadKeepsWhatARecheckTookInMeanwhile() async {
        let sdk = ReplacingSDK()
        let held = HeldFetch()
        let first = [row(1)]
        let later = [row(2)]
        let loader = PreviousIdentityLoader(fetch: { await held.fetch(answer: first, later: later) }, importer: sdk.importer)

        let startUp = Task { await loader.ensureLoaded() }
        await waitUntilOut(held)
        let opened = await loader.recheck()
        XCTAssertTrue(opened)
        XCTAssertEqual(loader.vaultKeys(), ["vault-n2"])

        held.answerNow()
        _ = await startUp.value
        XCTAssertEqual(Set(sdk.held.map(\.nonce)), ["n1", "n2"], "the re-check's identity was dropped")
        XCTAssertEqual(Set(loader.vaultKeys()), ["vault-n1", "vault-n2"])
    }

    // MARK: - The push

    func testExtraFieldsInThePushMakeNoDifference() {
        let bare: [AnyHashable: Any] = ["type": "tickle", "kind": "identities",
                                        "refId": "00000000-0000-0000-0000-000000000000"]
        var noisy = bare
        noisy["aps"] = ["content-available": 1]
        noisy["identities"] = [["nonce": "n", "ciphertext": "c"]]
        noisy["data"] = ["kind": "share"]
        noisy["title"] = "x"
        XCTAssertEqual(PushNotificationManager.event(from: bare), .identities)
        XCTAssertEqual(PushNotificationManager.event(from: noisy), .identities)
    }

    func testThePageEventIsOriginGuardedFirst() {
        let script = IdentityRecheck.pageEventScript(origin: "https://note.pingolindev.com")
        XCTAssertTrue(script.hasPrefix(#"(function(){try{if(location.origin!=="https://note.pingolindev.com")return;"#), script)
        XCTAssertTrue(script.contains("new CustomEvent('pingolin-identities')"), script)
    }
}
