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

import CryptoKit
import UIKit
import XCTest
@testable import Note

/// A refresh that got no answer (offline at launch or at the foreground) leaves the page's copy of the access token
/// dead. The shell catches up: when the network is back, and on retries while the token is stale (expired or within
/// 120 s of its expiry) and the app is in the foreground (1, 2 and 4 s apart, inside the page's own retries after a
/// 401, then every 30 s), through the one refresher; the page is re-seeded once per new token, never with an older
/// one; a refused session gets the usual sign-out, for the session the attempt started under, and nothing else.
@MainActor
final class SessionCatchUpTests: XCTestCase {

    /// The hooks, faked, and what the catch-up did with them.
    private final class World {
        let center = NotificationCenter()
        var stale = true
        var foreground = true
        var answers: [RefreshOutcome] = []
        var hang: Double = 0
        var session = AuthManager.SessionStamp(account: "a", refreshToken: nil)
        /// What the sign-out does with a refusal: ends the session, or drops it.
        var refusalEnds = true
        /// The fake clock (moves only when a retry's time comes) and the token's expiry.
        var now = Date(timeIntervalSince1970: 1_900_000_000)
        var expiry: Date?
        /// When each attempt went out, on the fake clock.
        var attemptsAt: [Date] = []
        var refreshes = 0
        var reseeds = 0
        var refusedFor: [AuthManager.SessionStamp] = []
        var delays: [TimeInterval] = []
        var cancels = 0
        private var pending: (() -> Void)?
        private var pendingDelay: TimeInterval = 0
        private(set) var catchUp: SessionCatchUp!

        /// Weak, never unowned: the catch-up's deinit cancels a pending retry,
        /// and that runs while this world is being torn down.
        init() {
            catchUp = SessionCatchUp(center: center, hooks: .init(
                isStale: { [weak self] in self?.stale ?? false },
                isForeground: { [weak self] in self?.foreground ?? false },
                expiry: { [weak self] in self?.expiry },
                now: { [weak self] in self?.now ?? Date() },
                stamp: { [weak self] in self?.session ?? AuthManager.SessionStamp(account: nil, refreshToken: nil) },
                refresh: { [weak self] in await self?.refresh() ?? .noAnswer },
                reseed: { [weak self] in self?.reseeds += 1 },
                refused: { [weak self] stamp in
                    self?.refusedFor.append(stamp)
                    return self?.refusalEnds ?? false
                },
                schedule: { [weak self] delay, fire in
                    self?.delays.append(delay)
                    self?.pendingDelay = delay
                    self?.pending = fire
                    return { [weak self] in
                        self?.cancels += 1
                        self?.pending = nil
                    }
                }
            ))
        }

        var hasPending: Bool { pending != nil }

        /// The pending retry's time has come (the clock moves on to it).
        func fire() {
            let due = pending
            pending = nil
            if due != nil { now = now.addingTimeInterval(pendingDelay) }
            due?()
        }

        private func refresh() async -> RefreshOutcome {
            refreshes += 1
            attemptsAt.append(now)
            if hang > 0 { try? await Task.sleep(for: .seconds(hang)) }
            let answer = answers.isEmpty ? RefreshOutcome.noAnswer : answers.removeFirst()
            if answer == .refreshed { stale = false }
            return answer
        }
    }

    /// Lets the attempt's main-actor task run to its end.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(80))
    }

    func testTheNetworkComingBackCatchesUpOnlyWhenStale() async {
        let world = World()
        world.stale = false
        world.center.post(name: .pingolinNetworkRegained, object: nil)
        await settle()
        XCTAssertEqual(world.refreshes, 0, "a fresh token: nothing")

        world.stale = true
        world.answers = [.refreshed]
        world.center.post(name: .pingolinNetworkRegained, object: nil)
        await settle()
        XCTAssertEqual(world.refreshes, 1)
        XCTAssertEqual(world.reseeds, 1)
        XCTAssertFalse(world.catchUp.isRetrying, "fresh again: nothing pending")
    }

    func testARetryIsPendingOnlyWhileStaleAndInTheForeground() {
        let world = World()
        for (stale, foreground, pending) in [(true, true, true), (true, false, false), (false, true, false),
                                             (false, false, false), (true, true, true)] {
            world.stale = stale
            world.foreground = foreground
            world.catchUp.evaluate()
            XCTAssertEqual(world.catchUp.isRetrying, pending, "stale \(stale), foreground \(foreground)")
            XCTAssertEqual(world.hasPending, pending)
        }
        world.catchUp.evaluate()
        world.catchUp.evaluate()
        XCTAssertEqual(world.delays, [1, 1], "one pending retry however often evaluated; a new stale spell starts at 1 s")

        world.center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        XCTAssertFalse(world.catchUp.isRetrying, "stopped on background")
        world.catchUp.evaluate()
        world.center.post(name: UIScene.didEnterBackgroundNotification, object: nil)
        XCTAssertFalse(world.catchUp.isRetrying, "stopped on a scene's background")
        world.catchUp.evaluate()
        world.catchUp.stop()
        XCTAssertFalse(world.catchUp.isRetrying, "stopped at sign-out (the shell's teardown)")
        XCTAssertEqual(world.refreshes, 0, "evaluating never refreshes by itself")
    }

    /// Right after a no answer the retries come 1, 2 and 4 s apart, inside the page's own retries after its 401
    /// (300 ms, 1 s, 2 s), then every 30 s.
    func testQuickRetriesAfterANoAnswerThenEvery30Seconds() async {
        let world = World()
        world.answers = Array(repeating: .noAnswer, count: 5)
        world.catchUp.evaluate()
        for _ in 0..<5 {
            world.fire()
            await settle()
        }
        XCTAssertEqual(world.refreshes, 5)
        XCTAssertEqual(world.delays, [1, 2, 4, 30, 30, 30])
        XCTAssertTrue(world.catchUp.isRetrying)
        XCTAssertEqual(world.reseeds, 0)
    }

    func testFreshStopsAndTheNextStaleSpellStartsQuickAgain() async {
        let world = World()
        world.answers = [.noAnswer, .refreshed]
        world.catchUp.evaluate()
        world.fire()
        await settle()
        world.fire()
        await settle()
        XCTAssertFalse(world.catchUp.isRetrying)
        XCTAssertEqual(world.reseeds, 1)
        XCTAssertEqual(world.delays, [1, 2])
        world.stale = true
        world.catchUp.evaluate()
        XCTAssertEqual(world.delays, [1, 2, 1], "quick again")
    }

    func testNoAnswerWhenTheNetworkComesBackRetriesQuickly() async {
        let world = World()
        world.answers = [.noAnswer]
        world.center.post(name: .pingolinNetworkRegained, object: nil)
        await settle()
        XCTAssertEqual(world.refreshes, 1)
        XCTAssertTrue(world.catchUp.isRetrying, "still stale, in the foreground")
        XCTAssertEqual(world.delays, [1])
    }

    func testARetryOutOfTheForegroundOrNoLongerStaleStopsWithoutARefresh() async {
        let world = World()
        world.catchUp.evaluate()
        world.foreground = false
        world.fire()
        await settle()
        XCTAssertFalse(world.catchUp.isRetrying)
        world.foreground = true
        world.catchUp.evaluate()
        world.stale = false
        world.fire()
        await settle()
        XCTAssertFalse(world.catchUp.isRetrying)
        XCTAssertEqual(world.refreshes, 0)
    }

    /// A refusal signs out the session the attempt STARTED under (the sign-out ignores it when that is no longer the
    /// session stored), and nothing else: no re-seed, no retry.
    func testARefusalSignsOutTheSessionTheAttemptStartedUnderAndNothingElse() async {
        let world = World()
        let startedUnder = world.session
        world.answers = [.refused]
        world.hang = 0.2
        world.catchUp.evaluate()
        world.fire()
        world.session = AuthManager.SessionStamp(account: "b", refreshToken: nil)
        try? await Task.sleep(for: .seconds(0.4))
        XCTAssertEqual(world.refusedFor, [startedUnder], "the stamp taken when the attempt started")
        XCTAssertEqual(world.reseeds, 0)
        XCTAssertFalse(world.catchUp.isRetrying)
        XCTAssertEqual(world.refreshes, 1, "no retry")
    }

    /// The cookie dies with the token: a stale spell that starts at the pre-expiry refresh (90 s before) spends its
    /// quick retries early, so a retry that would land past the expiry is brought to it and the quick retries start
    /// again there (1, 2 and 4 s after it), while the page's own requests go out with no cookie.
    func testTheQuickRetriesStartAgainWhenTheTokenExpires() async {
        let world = World()
        let expiry = world.now.addingTimeInterval(90)
        world.expiry = expiry
        world.answers = Array(repeating: .noAnswer, count: 9)
        world.catchUp.evaluate()
        for _ in 0..<9 {
            world.fire()
            await settle()
        }
        XCTAssertEqual(world.attemptsAt.map { Int($0.timeIntervalSince(expiry).rounded()) },
                       [-89, -87, -83, -53, -23, 1, 3, 7, 37])
        XCTAssertEqual(world.delays, [1, 2, 4, 30, 30, 24, 2, 4, 30, 30])
    }

    /// A refusal the sign-out drops (a sign-out or an erasure under way, another session meanwhile) keeps the
    /// retries going, so a dropped refusal followed by an erasure that fails can't leave the page stale.
    func testARefusalTheSignOutDropsKeepsTheRetriesGoing() async {
        let world = World()
        world.refusalEnds = false
        world.answers = [.refused, .refused]
        world.catchUp.evaluate()
        world.fire()
        await settle()
        XCTAssertEqual(world.refusedFor.count, 1)
        XCTAssertTrue(world.catchUp.isRetrying, "still stale: the next retry is pending")
        world.refusalEnds = true
        world.fire()
        await settle()
        XCTAssertEqual(world.refusedFor.count, 2)
        XCTAssertFalse(world.catchUp.isRetrying, "this one ended the session")
        XCTAssertEqual(world.delays, [1, 2])
        XCTAssertEqual(world.reseeds, 0)
    }

    func testOneAttemptAtATime() async {
        let world = World()
        world.hang = 0.3
        world.answers = [.refreshed]
        world.center.post(name: .pingolinNetworkRegained, object: nil)
        world.center.post(name: .pingolinNetworkRegained, object: nil)
        world.catchUp.evaluate()
        world.fire()
        try? await Task.sleep(for: .seconds(0.6))
        XCTAssertEqual(world.refreshes, 1)
        XCTAssertEqual(world.reseeds, 1)
        XCTAssertFalse(world.catchUp.isRetrying)
    }

    func testStaleMeansExpiredOrWithin120SecondsOfIt() {
        let now = Date()
        func jwt(_ secondsLeft: TimeInterval) -> String {
            token(#"{"sub":"u","exp":\#(Int(now.timeIntervalSince1970 + secondsLeft))}"#)
        }
        XCTAssertFalse(SessionCatchUp.isStale(jwt(300), now: now))
        XCTAssertFalse(SessionCatchUp.isStale(jwt(121), now: now))
        XCTAssertTrue(SessionCatchUp.isStale(jwt(120), now: now))
        XCTAssertTrue(SessionCatchUp.isStale(jwt(60), now: now))
        XCTAssertTrue(SessionCatchUp.isStale(jwt(-600), now: now))
        XCTAssertFalse(SessionCatchUp.isStale(nil, now: now), "signed out: nothing to catch up")
        XCTAssertFalse(SessionCatchUp.isStale("not-a-jwt", now: now), "left to the 401 paths, so no loop")
    }

    func testThePageIsReseededOncePerNewTokenAndNeverWithAnOlderOne() {
        let older = token(#"{"sub":"u","iat":1900000000,"exp":1900000900}"#)
        let newer = token(#"{"sub":"u","iat":1900000600,"exp":1900001500}"#)
        let newest = token(#"{"sub":"u","iat":1900001200,"exp":1900002100}"#)
        var seeded = SeededToken()
        XCTAssertFalse(seeded.isBehind(nil))
        XCTAssertTrue(seeded.isBehind(newer))
        XCTAssertFalse(seeded.isOlder(newer), "nothing seeded yet: nothing is older")
        seeded.record(newer)
        XCTAssertFalse(seeded.isBehind(newer), "the same token: no second seed")
        XCTAssertTrue(seeded.isOlder(older), "an older token never replaces a newer one")
        XCTAssertFalse(seeded.isOlder(newer))
        XCTAssertFalse(seeded.isOlder("not-a-jwt"), "unknown: not older")
        XCTAssertTrue(seeded.isBehind(newest))
        XCTAssertFalse(seeded.isOlder(newest))
        seeded.record(newest)
        XCTAssertTrue(seeded.isOlder(newer))
        seeded.forget()
        XCTAssertTrue(seeded.isBehind(newer), "after a sign-out the next page is seeded afresh")
        XCTAssertFalse(seeded.isOlder(older), "and nothing is older")
    }

    /// The shell's wiring: seeds run one at a time, each never older than the last and recording its token, and each
    /// evaluates the catch-up again; a refreshed token reaches the page through `reseedIfBehind`; sign-out stops the
    /// catch-up and forgets the token; the hooks are the real ones.
    func testTheShellWiresItsCatchUp() throws {
        let shell = try source("App/Views/WebShellView.swift")
        let seed = try body(shell, "func seedCookies(refreshFirst: Bool = true, keepExpired: Bool = false) async {")
        assertInOrder(seed, ["if refreshFirst { await APIService.shared.refreshAccessTokenIfExpiring(within: 120) }",
                             "let previous = seeding", "if let previous {",
                             "await WebShellModel.settled(within: WebShellModel.seedQueueWait) { await previous.value }",
                             "await self?.seedNow(keepExpired: keepExpired)", "seeding = mine", "await mine.value"],
                      "seedCookies")
        XCTAssertEqual(WebShellModel.seedQueueWait, 5)
        let now = try body(shell, "private func seedNow(keepExpired: Bool) async {")
        assertInOrder(now, ["defer { catchUp?.evaluate() }", "guard !seeded.isOlder(access) else { return }",
                            "await store.setCookie(cookie)", "guard !seeded.isOlder(access) else {",
                            "Task { @MainActor [weak self] in await self?.seedCookies(refreshFirst: false) }",
                            "seeded.record(access)"], "seedNow")
        let reseed = try body(shell, "@objc private func reseedCookies() {")
        XCTAssertTrue(reseed.contains("Task { @MainActor in await reseedIfBehind() }"))
        let behind = try body(shell, "func reseedIfBehind() async {")
        assertInOrder(behind, ["guard webView != nil, seeded.isBehind(KeychainService.shared.getString(for: .accessToken))",
                               "await seedCookies(refreshFirst: false)"], "reseedIfBehind")
        let teardown = try body(shell, "func teardown(keepData: Bool = false) {")
        XCTAssertTrue(teardown.contains("catchUp?.stop()"))
        XCTAssertTrue(teardown.contains("seeded.forget()"))
        XCTAssertTrue(teardown.contains("seeding = nil"), "a stuck seed never holds the next session's first load")
        assertInOrder(shell, [
            "catchUp = SessionCatchUp(hooks: .init(",
            "isStale: { SessionCatchUp.isStale(KeychainService.shared.getString(for: .accessToken)) },",
            "isForeground: { MainActor.assumeIsolated { UIApplication.shared.applicationState != .background } },",
            "expiry: { KeychainService.shared.getString(for: .accessToken).flatMap(APIService.accessTokenExpiry) },",
            "now: { Date() },",
            "stamp: { AuthManager.SessionStamp.current() },",
            "refresh: { await APIService.shared.refreshAccessTokenIfExpiring(within: 120) },",
            "reseed: { [weak self] in await self?.reseedIfBehind() },",
            "MainActor.assumeIsolated { AuthManager.shared.expireSessionRefusedByServer(since: stamp) }",
            "schedule: SessionCatchUp.mainRunLoopOnce",
        ], "the hooks")
        XCTAssertEqual(SessionCatchUp.quickRetries, [1, 2, 4])
        XCTAssertEqual(SessionCatchUp.retryEvery, 30)
        let monitor = try source("App/Services/ConnectivityMonitor.swift")
        assertInOrder(monitor, ["let wasOnline = self.isOnline", "if satisfied, !wasOnline {",
                                "NotificationCenter.default.post(name: .pingolinNetworkRegained, object: nil)"],
                      "the network coming back")
    }

    private func token(_ claims: String) -> String {
        let body = Data(claims.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        return "eyJhbGciOiJIUzI1NiJ9.\(body).c2ln"
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// The body of `func <name>` up to the next `\n    }\n` at its depth.
    private func body(_ text: String, _ signature: String) throws -> String {
        let start = try XCTUnwrap(text.range(of: signature), "no \(signature)")
        let rest = text[start.upperBound...]
        let end = try XCTUnwrap(rest.range(of: "\n    }\n"), "no end of \(signature)")
        return String(rest[..<end.lowerBound])
    }

    private func assertInOrder(_ text: String, _ marks: [String], _ what: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        var at = text.startIndex
        for mark in marks {
            guard let r = text.range(of: mark, range: at..<text.endIndex) else {
                return XCTFail("\(what): \(mark) missing or out of order", file: file, line: line)
            }
            at = r.upperBound
        }
    }
}
