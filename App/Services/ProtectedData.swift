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

import UIKit

/// The Keychain before the first unlock after a restart.
///
/// Every item this app keeps is `...AfterFirstUnlock...`: from the first
/// unlock until the next restart it reads whether or not the screen is locked,
/// and before that first unlock every read fails with
/// `errSecInteractionNotAllowed`. iOS can start the app in the background in
/// that window. A read that fails there is not "nothing stored", so the caller
/// waits here and reads again.
enum ProtectedData {
    /// The Keychain status of a read made before the first unlock.
    static let lockedStatus: OSStatus = errSecInteractionNotAllowed

    /// Returns true once the device has been unlocked. With `seconds`, it
    /// also returns true that long without the notification, so a
    /// notification missed between the caller's read and this wait can't hold
    /// a caller that reads again either way.
    ///
    /// On a device that is already unlocked it returns FALSE after a
    /// one-second pause: a read that failed then was not waiting for the first
    /// unlock, and a caller that reads again must not spin on the main actor.
    @MainActor
    @discardableResult
    static func waitUntilAvailable(atMost seconds: Double? = 15) async -> Bool {
        if UIApplication.shared.isProtectedDataAvailable {
            try? await Task.sleep(for: .seconds(1))
            return false
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                let unlocks = NotificationCenter.default.notifications(
                    named: UIApplication.protectedDataDidBecomeAvailableNotification
                )
                for await _ in unlocks { return }
            }
            if let seconds {
                group.addTask {
                    try? await Task.sleep(for: .seconds(seconds))
                }
            }
            await group.next()
            group.cancelAll()
        }
        return true
    }
}
