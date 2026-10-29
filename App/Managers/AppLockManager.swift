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
import LocalAuthentication
import SwiftUI

/// Biometric / passcode gate. Mirrors android SessionManager.kt's
/// `isAppLockEnabled` / `requiresAppLockAuth` / auto-lock-timeout flow.
/// The state is intentionally simple: when `enabled`, the app
/// launches into a locked state; once `unlock()` succeeds via
/// LAPolicy.deviceOwnerAuthentication, we flip `isLocked` to false
/// until the next foreground transition.
@MainActor
final class AppLockManager: ObservableObject {
    static let shared = AppLockManager()

    @Published private(set) var isLocked: Bool
    @Published private(set) var lastError: String?

    private let config = AppConfiguration.shared

    private init() {
        self.isLocked = AppConfiguration.shared.appLockEnabled
    }

    /// Whether the device supports biometrics. Used by the settings
    /// screen to label the toggle ("Face ID" / "Touch ID" / "Passcode").
    var biometryLabel: String {
        let ctx = LAContext()
        var error: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return "Passcode"
        }
        switch ctx.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "Passcode"
        }
    }

    var enabled: Bool {
        get { config.appLockEnabled }
    }

    /// Called from the settings toggle. Re-prompts immediately so the
    /// user proves they can pass the gate before we save the flag.
    func setEnabled(_ enabled: Bool) async {
        if enabled {
            let ok = await prompt(reason: "Enable app lock")
            guard ok else { return }
            config.appLockEnabled = true
            isLocked = false
        } else {
            // Disabling does NOT re-prompt: device-level auth already
            // covers the user identity here (they unlocked the device
            // to reach Settings).
            config.appLockEnabled = false
            isLocked = false
        }
    }

    /// When the app last left the foreground, or nil if it has not since
    /// unlocking. Memory only: a cold start re-runs `init`, which locks.
    private var backgroundedAt: Date?

    /// Note that the app has left the foreground. Does NOT lock — the timeout
    /// is judged on the way back, because that is the only moment we know how
    /// long the app was away.
    func noteBackgrounded() {
        guard config.appLockEnabled, !isLocked else { return }
        backgroundedAt = Date()
    }

    /// Re-arm the lock if the app was away for at least the chosen timeout.
    ///
    /// Locking on EVERY background transition would mean a Face ID prompt
    /// after answering a notification, or switching apps to copy a link —
    /// which is the reason people turn app lock off, and so a stricter
    /// default that ends in the feature being disabled is not actually
    /// stricter. The same three choices as the Android app.
    func lockIfTimedOut() {
        guard config.appLockEnabled else { return }
        let timeout = TimeInterval(config.autoLockTimeout.rawValue)
        guard let since = backgroundedAt else {
            // No recorded background — treat as "lock", which is the safe
            // direction and matches a cold start.
            isLocked = true
            return
        }
        if timeout == 0 || Date().timeIntervalSince(since) >= timeout {
            isLocked = true
            backgroundedAt = nil
        }
    }

    /// Forced re-lock. Kept for callers that mean "lock now regardless",
    /// such as an explicit user action.
    func lock() {
        guard config.appLockEnabled else { return }
        isLocked = true
        backgroundedAt = nil
    }

    /// Attempt to unlock. Called by the lock-screen "Unlock" button or
    /// auto-fired on .onAppear.
    func unlock() async {
        let ok = await prompt(reason: "Unlock Note")
        if ok {
            isLocked = false
            lastError = nil
            backgroundedAt = nil
        }
    }

    private func prompt(reason: String) async -> Bool {
        let ctx = LAContext()
        ctx.localizedFallbackTitle = "Use Passcode"
        do {
            return try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            lastError = (error as NSError).localizedDescription
            return false
        }
    }
}
