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
#if NOTE_TESTS
@testable import Note
#endif

/// Runs for the note server's one visible alert, `finish_shares` ("Someone
/// you invited has joined Pingolin."), before iOS shows it: this phone
/// finishes the shares the owner's invitation left (`BackgroundFinish`), and
/// the banner says who can now open what (`FinishBanner`). Nothing finished,
/// or anything else: the alert as the server sent it.
///
/// A Notification Service Extension is the only code that runs for a push
/// when the app was swiped away; it runs because the server sends this alert
/// with mutable-content.
final class NotificationService: UNNotificationServiceExtension {

    /// Hands the banner to iOS exactly once: whichever gets there first, the
    /// work below or `serviceExtensionTimeWillExpire`.
    private var deliver: DeliverOnce?
    private var bestAttempt: UNMutableNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        let deliver = DeliverOnce(contentHandler)
        self.deliver = deliver
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            deliver(request.content)
            return
        }
        bestAttempt = content
        guard FinishPush.isFinishShares(content.userInfo) else {
            deliver(content)
            return
        }
        let original = content.copy() as? UNNotificationContent ?? content
        let deadline = Date().addingTimeInterval(BackgroundFinish.budget)
        Task {
            let result = await BackgroundFinish.run(deadline: deadline, env: .live)
            deliver(Self.banner(for: original, result: result))
        }
    }

    /// The server's alert with the body saying what was finished; the alert
    /// unchanged when nothing was, or when the account signed in here changed.
    static func banner(for original: UNNotificationContent, result: BackgroundFinish.Result) -> UNNotificationContent {
        guard !result.accountChanged,
              let body = FinishBanner.body(finished: result.report.finished, detail: result.detail),
              let content = original.mutableCopy() as? UNMutableNotificationContent
        else { return original }
        content.body = body
        return content
    }

    /// Out of time: the server's alert, rather than nothing.
    override func serviceExtensionTimeWillExpire() {
        if let deliver, let bestAttempt {
            deliver(bestAttempt)
        }
    }
}

/// A content handler that runs once: the first banner handed to it goes to iOS,
/// any later one is dropped. The run finishing and the time running out can race.
final class DeliverOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((UNNotificationContent) -> Void)?

    init(_ handler: @escaping (UNNotificationContent) -> Void) {
        self.handler = handler
    }

    /// True when this content is the one handed to iOS (the first).
    @discardableResult
    func callAsFunction(_ content: UNNotificationContent) -> Bool {
        lock.lock()
        let handler = self.handler
        self.handler = nil
        lock.unlock()
        handler?(content)
        return handler != nil
    }
}
