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

/// Pick up a restore made elsewhere while the app runs, so older notes open
/// without a restart.
///
/// Triggers: the "identities" push (the nudge); the app coming to the
/// foreground while the local cache still holds notes that did not open; and
/// the page asking again for the earlier vault keys (bridge op
/// `previousVaultKeys`), which it does when it comes back with notes still
/// locked. The page's signal matters: this app's cache never keeps a note it
/// could not open unless it had cached it before, so after a sign-in that
/// follows a reset the cache shows nothing locked. The push carries nothing
/// and grants nothing: the re-check is the normal signed-in
/// `GET /auth/previous-identities` plus the SDK import, and it only ADDS
/// (`PreviousIdentityLoader.recheck` imports the union). Only when something
/// new opened does the app re-decrypt: it tells the page, which reads the new
/// vault keys through the bridge (op `previousVaultKeys`), and syncs the
/// native cache.
///
/// Limits, per device: at most one re-check per `window`. A trigger refused by
/// the window or by a running re-check leaves ONE pending flag, which runs a
/// single re-check when the window ends (or at a foreground after it), and
/// that run is the new window's one re-check. So a flood of nudges costs at
/// most one GET per window. Sign-out and account switch (`clear`, from
/// `AuthManager.switchAccountCleanup`) drop the flag and the window; the
/// loader's `reset` drops the held blobs.
@MainActor
final class IdentityRecheck {
    static let shared = IdentityRecheck()
    static let window: TimeInterval = 180

    // Seams for tests: the clock, the wait, the re-check, the "locked" test and
    // what runs when something new opened. MainActor, like everything here.
    var now: @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// Waits until the clock reads the given time. A deadline, not a duration,
    /// so the wake does not depend on when the waiting task got to run.
    var sleepUntil: @MainActor (TimeInterval) async -> Void = { deadline in
        try? await Task.sleep(for: .seconds(max(0, deadline - ProcessInfo.processInfo.systemUptime)))
    }
    var recheck: @MainActor () async -> Bool = {
        guard AuthManager.shared.isAuthenticated else { return false }
        return await PreviousIdentityLoader.shared.recheck()
    }
    var somethingLocked: @MainActor () -> Bool = { !NoteStore.shared.undecryptedItems().isEmpty }
    /// Tells the page (unless the page's own request started this re-check:
    /// its reply carries the keys) and syncs the native cache.
    var afterNewIdentity: @MainActor (_ notifyPage: Bool) async -> Void = { notifyPage in
        if notifyPage { WebShellModel.shared.notifyIdentitiesChanged() }
        await SyncService.shared.sync()
    }

    /// What asked for a re-check, for the log.
    enum Trigger: String {
        case push, foreground, page, pending
    }

    #if DEBUG
    /// Decisions and counts only, never key material. DEBUG builds only, like
    /// this app's other per-event diagnostics (`[Note] push:`): even a count
    /// says how many resets an account has had, so a release build neither
    /// builds the line nor writes it to the device log.
    static let log = Logger(subsystem: "com.pingolin.note", category: "identities")
    #endif

    private func note(_ line: @autoclosure () -> String) {
        #if DEBUG
        let line = line()
        Self.log.debug("\(line, privacy: .public)")
        print("[Note] identities: \(line)")
        #endif
    }

    private var gate = IdentityRecheckGate(window: IdentityRecheck.window)
    private var scheduled: Task<Void, Never>?
    /// Bumped by `clear`: a run or a pending wake from before it keeps nothing.
    private var generation = 0

    init() {}

    /// The "identities" push. Returns once the re-check it started, if any, is
    /// done, so a background wake has used its time for it.
    func nudge() async {
        await request(.push)
    }

    /// The app came to the foreground: re-check only while something is still
    /// locked, or a refused trigger is still pending.
    func foreground() async {
        guard gate.hasPending || somethingLocked() else {
            note("foreground: nothing locked in the cache, nothing pending")
            return
        }
        await request(.foreground)
    }

    /// The page asked again for the earlier vault keys (it has notes still
    /// locked). Gated like every trigger, so a page that spams the op costs at
    /// most one GET per window.
    func pageAsked() async {
        await request(.page)
    }

    /// Sign-out / account switch: no pending re-check, no window.
    func clear() {
        gate.clear()
        scheduled?.cancel()
        scheduled = nil
        generation += 1
    }

    private func request(_ trigger: Trigger) async {
        let t = now()
        switch gate.request(now: t) {
        case .run:
            note("\(trigger.rawValue): ran")
            await run(trigger)
        case .pending(let at):
            if let at {
                note("\(trigger.rawValue): refused, inside the window; pending set, due in \(Int((at - t).rounded(.up))) s")
                schedule(at: at)
            } else {
                note("\(trigger.rawValue): refused, a re-check is running; pending set")
            }
        }
    }

    private func run(_ trigger: Trigger) async {
        let started = generation
        let opened = await recheck()
        // Looked at again after the await: a sign-out meanwhile means whatever
        // opened is not this session's to act on, and the gate was cleared.
        guard started == generation else {
            note("\(trigger.rawValue): dropped, the session changed while it ran")
            return
        }
        note("\(trigger.rawValue): done, something new opened: \(opened)")
        if opened { await afterNewIdentity(trigger != .page) }
        if let at = gate.finished() { schedule(at: at) }
    }

    /// Run the pending re-check at `at`, once.
    private func schedule(at: TimeInterval) {
        guard scheduled == nil else { return }
        let started = generation
        scheduled = Task { [weak self] in
            await self?.sleepUntil(at)
            guard let self, !Task.isCancelled, started == self.generation else { return }
            self.scheduled = nil
            if self.gate.runPending(now: self.now()) {
                self.note("pending: ran at the window's end")
                await self.run(.pending)
            } else if let due = self.gate.pendingDue {
                self.note("pending: woke inside the window; rescheduled")
                self.schedule(at: due)
            }
        }
    }

    /// The event the page listens for, origin guard first, as in every script
    /// this shell injects (`WebAppDeviceState.buildScript`).
    nonisolated static func pageEventScript(origin: String) -> String {
        "(function(){try{if(location.origin!==\(WebAppDeviceState.quote(origin)))return;"
            + "window.dispatchEvent(new CustomEvent('pingolin-identities'));}catch(e){}})();"
    }
}

/// The re-check limits as a pure state machine over clock readings (seconds).
struct IdentityRecheckGate {
    let window: TimeInterval
    private(set) var hasPending = false
    private var running = false
    private var windowStart: TimeInterval?

    init(window: TimeInterval) {
        self.window = window
    }

    enum Decision: Equatable {
        /// Start one now; the window starts now.
        case run
        /// Refused: the pending flag is set. It may run at `at`, or, while one
        /// is running (nil), when that one ends and its window has passed.
        case pending(at: TimeInterval?)
    }

    mutating func request(now: TimeInterval) -> Decision {
        if running {
            hasPending = true
            return .pending(at: nil)
        }
        if let start = windowStart, now - start < window {
            hasPending = true
            return .pending(at: start + window)
        }
        start(now)
        return .run
    }

    /// The pending re-check, if one is set and its time has come.
    mutating func runPending(now: TimeInterval) -> Bool {
        guard hasPending, !running else { return false }
        if let start = windowStart, now - start < window { return false }
        start(now)
        return true
    }

    /// When a pending re-check may run, if one is waiting and none is running.
    var pendingDue: TimeInterval? {
        guard hasPending, !running else { return nil }
        return (windowStart ?? 0) + window
    }

    /// A re-check ended: when its pending successor may run, or nil.
    mutating func finished() -> TimeInterval? {
        running = false
        return hasPending ? (windowStart ?? 0) + window : nil
    }

    mutating func clear() {
        running = false
        hasPending = false
        windowStart = nil
    }

    private mutating func start(_ now: TimeInterval) {
        running = true
        hasPending = false
        windowStart = now
    }
}
