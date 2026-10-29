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
import UserNotifications

/// Schedules + cancels iOS local notifications that fire at a
/// reminder's `triggerAt`. The reminder record itself lives on the
/// server (POST /api/v1/reminders); this manager mirrors each
/// server-side reminder into a UNNotificationRequest so the OS shows
/// a banner at the appointed time. Notification identifier == server
/// reminder id (so cancellation can target it precisely).
///
/// Mirrors android ReminderReceiver + ReminderDao's local mirror.
enum ReminderManager {
    /// Ask the OS for permission to show alerts + play sounds. Safe
    /// to call repeatedly; iOS only shows the prompt the first time.
    static func requestAuthorization() async {
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    /// Mirror a server-side reminder into a local notification.
    static func schedule(reminder: ReminderDto, noteTitle: String) {
        guard let date = parseTriggerAt(reminder.triggerAt) else { return }
        cancel(id: reminder.id)
        let content = UNMutableNotificationContent()
        content.title = NotificationDetail.reminderTitle(
            AppConfiguration.shared.notificationDetail, noteTitle: noteTitle
        )
        content.body = "Reminder"
        content.sound = .default
        content.userInfo = ["itemId": reminder.itemId, "reminderId": reminder.id]
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: date
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(identifier: reminder.id, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }

    static func cancel(id: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
    }

    /// ISO 8601 with optional fractional seconds (server emits either
    /// form depending on database driver — match android's tolerant
    /// parse).
    static func parseTriggerAt(_ raw: String) -> Date? {
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFrac.date(from: raw) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    static func formatTriggerAt(_ date: Date) -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        return fmt.string(from: date)
    }
}
