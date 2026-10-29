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
import BackgroundTasks
import UIKit
import UserNotifications

/// iOS analog of android's UnifiedPush — except where android offers
/// a self-hosted push *distributor*, iOS offers no real alternative
/// to APNs for true wake-from-killed delivery. The realistic
/// equivalent for users who don't want notification metadata to flow
/// through Apple's relay is:
///
///   - Skip APNs registration entirely (no token issued to the server).
///   - Schedule a recurring `BGAppRefreshTask` so iOS opportunistically
///     wakes the app every few hours to pull pending reminders + new
///     shares from the authenticated API and post any local banners.
///   - Poll once whenever polling mode is started (`startIfNeeded`).
///
/// Trade-off vs APNs: latency goes from sub-second to "next time iOS
/// schedules a refresh" (often 15 min - 1 h) and the app sees no
/// signal at all when the OS has aggressively suspended it. In return
/// the server stores no per-device push endpoint for that user, so
/// notification metadata never transits Apple's push relay.
@MainActor
final class PollingPushManager {
    static let shared = PollingPushManager()

    /// Must match BGTaskSchedulerPermittedIdentifiers in Info.plist.
    static let refreshTaskID = "com.pingolin.note.refresh"

    /// Minimum interval iOS will respect (15 minutes). iOS picks the
    /// actual fire time based on the user's app-usage pattern.
    private static let minimumRefreshSeconds: TimeInterval = 15 * 60

    private init() {}

    /// Registered once at app launch (from NoteApp) so iOS knows
    /// which closure to invoke when the OS decides to run our
    /// background refresh task.
    static func registerLaunchHandler() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: refreshTaskID,
            using: nil
        ) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            // Re-arm before we run the work — if iOS kills us we still
            // get re-scheduled.
            shared.scheduleNext()
            let op = Task {
                let ok = await shared.runPoll()
                refresh.setTaskCompleted(success: ok)
            }
            refresh.expirationHandler = {
                op.cancel()
                refresh.setTaskCompleted(success: false)
            }
        }
    }

    /// Idempotent: only schedules if we're actually in polling mode.
    /// Called from PushNotificationManager.switchMode + after
    /// requestAuthorization, plus from the app delegate on launch.
    func startIfNeeded() {
        guard AppConfiguration.shared.pushDeliveryMode == .polling else { return }
        scheduleNext()
        Task { _ = await runPoll() }
    }

    /// Called from PushNotificationManager.switchMode when leaving
    /// polling mode. Cancels every pending BGTask submission so iOS
    /// doesn't wake us up just to do nothing.
    func stop() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.refreshTaskID)
    }

    /// Logout cleanup: stop scheduled polling AND drop the per-account
    /// last-seen-shares dedup set, so account B on the same device doesn't
    /// inherit account A's "already notified" share ids (which would suppress
    /// that user's own share banners).
    func reset() {
        stop()
        UserDefaults.standard.removeObject(forKey: Self.lastSeenSharesKey)
    }

    /// Submit a refresh task to iOS's BG scheduler. iOS coalesces +
    /// throttles aggressively; the request is a hint, not a contract.
    func scheduleNext() {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: Self.minimumRefreshSeconds)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            #if DEBUG
            print("[Note] BGTaskScheduler.submit failed: \(error)")
            #endif
        }
    }

    /// The actual polling work. Fetches pending reminders + shares
    /// inbox; posts local banners for anything not already shown.
    /// Returns true so iOS counts the run as successful (we always
    /// "succeed" — there's no recoverable error worth retrying right
    /// away).
    func runPoll() async -> Bool {
        guard AuthManager.shared.isAuthenticated else { return true }
        await checkRemindersAndNotify()
        await checkSharesInboxAndNotify()
        return true
    }

    private static let lastSeenSharesKey = "polling.last_seen_share_ids"

    private func checkRemindersAndNotify() async {
        do {
            let reminders = try await APIService.shared.listReminders()
                .filter { !$0.fired && !$0.dismissed }
            for r in reminders {
                guard let trigger = ReminderManager.parseTriggerAt(r.triggerAt),
                      trigger <= Date() else { continue }
                // For each due reminder, post a banner. UNNotificationRequest
                // deduplicates on identifier, so re-running the poll is
                // harmless.
                let content = UNMutableNotificationContent()
                content.title = "Reminder"
                content.body = "You have a pending reminder."
                content.sound = .default
                content.categoryIdentifier = PushNotificationManager.categoryReminder
                content.userInfo = ["refId": r.itemId]
                let req = UNNotificationRequest(
                    identifier: "polling-reminder-\(r.id)",
                    content: content,
                    trigger: nil
                )
                try? await UNUserNotificationCenter.current().add(req)
            }
        } catch {
            #if DEBUG
            print("[Note] polling reminders fetch failed: \(error)")
            #endif
        }
    }

    private func checkSharesInboxAndNotify() async {
        do {
            let inbox = try await APIService.shared.listInbox()
            let knownIDs = Set(UserDefaults.standard.stringArray(forKey: Self.lastSeenSharesKey) ?? [])
            let newShares = inbox.filter { !knownIDs.contains($0.shareId) }
            if !newShares.isEmpty {
                let content = UNMutableNotificationContent()
                content.title = newShares.count == 1
                    ? "New note shared with you"
                    : "\(newShares.count) new shares"
                content.body = "Tap to open Inbox"
                content.sound = .default
                content.categoryIdentifier = PushNotificationManager.categoryShare
                let req = UNNotificationRequest(
                    identifier: "polling-share-\(UUID().uuidString)",
                    content: content,
                    trigger: nil
                )
                try? await UNUserNotificationCenter.current().add(req)
            }
            UserDefaults.standard.set(inbox.map { $0.shareId }, forKey: Self.lastSeenSharesKey)
        } catch {
            #if DEBUG
            print("[Note] polling inbox fetch failed: \(error)")
            #endif
        }
    }
}
