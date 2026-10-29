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

/// Pinned-note "always available" notification. iOS doesn't have a
/// direct analog to android's PinnedNoteService persistent
/// FLAG_ONGOING notification, but a `UNNotificationContent` with
/// `interruptionLevel = .passive` posted as a delivered notification
/// (no trigger date) sits silently in the notification center and
/// stays there until the user dismisses it — close enough that the
/// user always has a one-tap shortcut back to their pinned notes.
///
/// Tap → deep-link via `noteapp://item/{id}` (handled by
/// PushNotificationManager.handleTap → .pushOpenNote).
enum PinnedNoteNotifier {
    private static func identifier(for itemId: String) -> String { "pinned-\(itemId)" }

    static func pin(itemId: String, title: String, snippet: String) {
        let detail = AppConfiguration.shared.notificationDetail
        let content = UNMutableNotificationContent()
        content.title = NotificationDetail.pinnedTitle(detail, noteTitle: title)
        content.body = NotificationDetail.pinnedSnippet(detail, snippet: String(snippet.prefix(120))) ?? ""
        content.interruptionLevel = .passive
        content.sound = nil
        content.categoryIdentifier = PushNotificationManager.categoryReminder
        content.userInfo = ["refId": itemId, "pinned": true]
        // No trigger → fires immediately, then stays delivered.
        let request = UNNotificationRequest(
            identifier: identifier(for: itemId),
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    static func unpin(itemId: String) {
        let center = UNUserNotificationCenter.current()
        let id = identifier(for: itemId)
        center.removePendingNotificationRequests(withIdentifiers: [id])
        center.removeDeliveredNotifications(withIdentifiers: [id])
    }
}
