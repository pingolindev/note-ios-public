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
import UserNotifications

/// Owns the APNs registration loop + the runtime end of the push
/// pipeline. The server is E2EE-blind: pushes carry only `type: "tickle"`,
/// the event in `kind`, and an optional `refId` — the manager surfaces a
/// local notification or pulls through the authenticated API (see
/// `PushEvent`).
///
/// Mirrors the tickle-only design of android NoteFirebaseMessagingService.
@MainActor
final class PushNotificationManager: NSObject, ObservableObject {
    static let shared = PushNotificationManager()

    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published private(set) var lastError: String?

    private let api = APIService.shared
    private let keychain = KeychainService.shared

    private static let lastPushedTokenKey = "push.last_token"

    /// UNUserNotificationCenterDelegate categories. Matches the server
    /// `type` field so we can recover intent from the local notification
    /// after it's been displayed.
    static let categoryShare = "share"
    static let categoryReminder = "reminder"

    override private init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        registerCategories()
    }

    func requestAuthorization() async {
        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
            let settings = await center.notificationSettings()
            authorizationStatus = settings.authorizationStatus
            guard granted else { return }
            // Local notifications still work in polling mode; only the
            // remote-push registration is skipped.
            switch AppConfiguration.shared.pushDeliveryMode {
            case .apns:
                UIApplication.shared.registerForRemoteNotifications()
            case .polling:
                PollingPushManager.shared.startIfNeeded()
            }
        } catch {
            lastError = "Notifications request failed: \(error.localizedDescription)"
        }
    }

    /// Called by the Settings picker when the user switches between
    /// APNs and polling. Unwinds the prior mode (de-registers APNs
    /// from the server, or stops the BGTask schedule) before booting
    /// the new mode so we don't end up double-registered.
    func switchMode(to newMode: PushDeliveryMode) async {
        let old = AppConfiguration.shared.pushDeliveryMode
        guard old != newMode else { return }
        AppConfiguration.shared.pushDeliveryMode = newMode
        switch old {
        case .apns:
            await unregister()
        case .polling:
            PollingPushManager.shared.stop()
        }
        switch newMode {
        case .apns:
            UIApplication.shared.registerForRemoteNotifications()
        case .polling:
            PollingPushManager.shared.startIfNeeded()
        }
    }

    func register(deviceToken: Data) async {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()

        if let existing = UserDefaults.standard.string(forKey: Self.lastPushedTokenKey), existing == hex {
            return
        }

        guard let deviceId = AuthManager.shared.deviceId else {
            return
        }

        do {
            try await api.registerAPNs(
                deviceId: deviceId,
                apnsToken: hex,
                bundleId: Bundle.main.bundleIdentifier ?? "com.pingolin.note",
                appVersion: AppConfiguration.shared.appVersion
            )
            UserDefaults.standard.set(hex, forKey: Self.lastPushedTokenKey)
            lastError = nil
        } catch {
            lastError = "Push registration failed: \(error.localizedDescription)"
        }
    }

    func registrationFailed(_ error: Error) {
        lastError = "APNs registration failed: \(error.localizedDescription)"
    }

    func unregister() async {
        guard let deviceId = AuthManager.shared.deviceId else { return }
        try? await api.unregisterAPNs(deviceId: deviceId)
        UserDefaults.standard.removeObject(forKey: Self.lastPushedTokenKey)
    }

    func reset() {
        UserDefaults.standard.removeObject(forKey: Self.lastPushedTokenKey)
    }

    // MARK: - Incoming pushes

    /// What a push asks this device to do. The note server's dispatcher
    /// always sends `type: "tickle"` and carries the event in `kind` —
    /// "reminder", "share", "notebook_share" or "sync" — so `kind` is read
    /// first, as on Android (`when (kind ?: type)`); `type` only covers a
    /// sender that sets no kind. Reading `type` first would send every push
    /// to the reminder check: no share banner would show, and "sync" would
    /// pull nothing.
    ///
    /// The payload is the server's word, so only the kind and an id-shaped
    /// `refId` are taken from it; everything else comes through the normal
    /// signed-in calls.
    enum PushEvent: Equatable {
        case share(refId: String?)
        case notebookShare(refId: String?)
        case sync
        /// A restore was made elsewhere; re-check the earlier identities.
        case identities
        case reminder
        case ignored
    }

    nonisolated static func event(from userInfo: [AnyHashable: Any]) -> PushEvent {
        let tag = userInfo["kind"] as? String ?? userInfo["type"] as? String
        let refId = (userInfo["refId"] as? String ?? userInfo["ref_id"] as? String)
            .flatMap { UUID(uuidString: $0) == nil ? nil : $0 }
        switch tag {
        case "share": return .share(refId: refId)
        case "notebook_share": return .notebookShare(refId: refId)
        case "sync": return .sync
        case "identities": return .identities
        case "reminder", "tickle": return .reminder
        default: return .ignored
        }
    }

    /// Inspect a push payload and dispatch. Returns a UIBackgroundFetchResult
    /// the PushAppDelegate forwards to the system.
    func handleIncoming(_ userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        guard AuthManager.shared.isAuthenticated else { return .noData }

        let event = Self.event(from: userInfo)

        #if DEBUG
        print("[Note] push: \(event)")
        #endif

        switch event {
        case .share(let refId):
            await presentShareBanner(refId: refId, title: "New note shared with you", body: "Tap to open Shared with me")
            NotificationCenter.default.post(name: .pushReceivedShare, object: refId)
            return .newData
        case .notebookShare(let refId):
            await presentShareBanner(refId: refId, title: "New notebook shared with you", body: "Tap to accept or decline it")
            NotificationCenter.default.post(name: .pushReceivedShare, object: refId)
            return .newData
        case .sync:
            // A change was made elsewhere: pull now. SyncService.sync() returns
            // at once while another sync runs (its `isSyncing` guard), so a
            // burst of these never piles up — as Android's unique immediate work
            // with KEEP. A background push gets about 30 seconds, so this waits
            // at most 25; the sync itself carries on.
            await Self.run({ await SyncService.shared.sync() }, waitingAtMost: 25)
            return .newData
        case .identities:
            // Nothing is read from the push. The re-check is the normal
            // signed-in fetch, at most once per window (IdentityRecheck); a
            // background push gets about 30 seconds, so this waits at most 25.
            await Self.run({ await IdentityRecheck.shared.nudge() }, waitingAtMost: 25)
            return .newData
        case .reminder:
            let count = await fetchPendingReminderCount()
            if count > 0 {
                await presentReminderBanner(count: count)
            }
            NotificationCenter.default.post(name: .pushReceivedTickle, object: nil)
            return count > 0 ? .newData : .noData
        case .ignored:
            return .noData
        }
    }

    /// Runs `work`, waiting for it at most `seconds`: past that the caller moves
    /// on and the work carries on.
    static func run(_ work: @escaping @MainActor () async -> Void, waitingAtMost seconds: Double) async {
        let (done, signal) = AsyncStream.makeStream(of: Void.self)
        Task { @MainActor in
            await work()
            signal.finish()
        }
        let timer = Task {
            try? await Task.sleep(for: .seconds(seconds))
            signal.finish()
        }
        for await _ in done {}
        timer.cancel()
    }

    /// Tap-to-route: turn a UNNotificationResponse into a deep-link
    /// notification so the SwiftUI tree can switch tabs / open a row.
    func handleTap(_ response: UNNotificationResponse) {
        let userInfo = response.notification.request.content.userInfo
        let category = response.notification.request.content.categoryIdentifier
        let refId = userInfo["refId"] as? String ?? userInfo["ref_id"] as? String

        switch category {
        case Self.categoryShare:
            NotificationCenter.default.post(name: .pushOpenInbox, object: refId)
        case Self.categoryReminder:
            NotificationCenter.default.post(name: .pushOpenNote, object: refId)
        default:
            // Unknown category — best effort, surface as a tickle event so
            // the active tab refreshes if it cares.
            NotificationCenter.default.post(name: .pushReceivedTickle, object: refId)
        }
    }

    private func registerCategories() {
        let share = UNNotificationCategory(
            identifier: Self.categoryShare,
            actions: [],
            intentIdentifiers: [],
            options: []
        )
        let reminder = UNNotificationCategory(
            identifier: Self.categoryReminder,
            actions: [],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([share, reminder])
    }

    private func presentShareBanner(refId: String?, title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = Self.categoryShare
        if let refId { content.userInfo = ["refId": refId] }
        let request = UNNotificationRequest(
            identifier: "share-\(refId ?? UUID().uuidString)",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    private func presentReminderBanner(count: Int) async {
        let content = UNMutableNotificationContent()
        content.title = count == 1 ? "Reminder" : "\(count) reminders"
        content.body = "Tap to view your notes"
        content.sound = .default
        content.categoryIdentifier = Self.categoryReminder
        let request = UNNotificationRequest(
            identifier: "reminder-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    private func fetchPendingReminderCount() async -> Int {
        do {
            let all = try await api.listReminders()
            return all.filter { !$0.fired && !$0.dismissed }.count
        } catch {
            #if DEBUG
            print("[Note] tickle: listReminders failed: \(error)")
            #endif
            return 0
        }
    }
}

extension PushNotificationManager: UNUserNotificationCenterDelegate {
    /// Show banners even when the app is foreground. Matches android's
    /// PRIORITY_HIGH + auto-cancel behavior — the user always sees that
    /// something changed.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            self.handleTap(response)
            completionHandler()
        }
    }
}

extension Notification.Name {
    /// Posted after a share or notebook-share push is processed. `object` is
    /// the optional `refId` (share id) if the server included one.
    static let pushReceivedShare = Notification.Name("note.push.share.received")
    /// Posted after a reminder push is processed, and for a tap on a
    /// notification of an unknown category.
    static let pushReceivedTickle = Notification.Name("note.push.tickle.received")
    /// Posted when the user taps a share notification. `object` is the
    /// optional refId. RootView opens the web app's home view, which
    /// holds the shares inbox.
    static let pushOpenInbox = Notification.Name("note.push.open.inbox")
    /// Posted when the user taps a reminder notification. `object` is the
    /// optional refId (item id). RootView opens that note in the web
    /// shell.
    static let pushOpenNote = Notification.Name("note.push.open.note")
}

final class PushAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // BGTaskScheduler requires the handler to be registered before
        // the app finishes launching. Register unconditionally — the
        // task will simply re-arm to no work if polling mode isn't
        // active.
        PollingPushManager.registerLaunchHandler()
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in
            await PushNotificationManager.shared.register(deviceToken: deviceToken)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        Task { @MainActor in
            PushNotificationManager.shared.registrationFailed(error)
        }
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Task { @MainActor in
            let result = await PushNotificationManager.shared.handleIncoming(userInfo)
            completionHandler(result)
        }
    }
}
