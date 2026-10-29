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

/// How long the app may sit in the background before app lock re-arms.
///
/// Mirrors the Android app's `SessionManager.AUTO_LOCK_*` and offers the
/// same three choices. Re-locking on EVERY background transition would mean
/// a Face ID prompt after answering a notification or pasting from another
/// app — which is why people turn app lock off.
enum AutoLockTimeout: Int, CaseIterable {
    case immediately = 0
    case oneMinute = 60
    case fiveMinutes = 300

    var displayName: String {
        switch self {
        case .immediately: return "Immediately"
        case .oneMinute: return "After 1 minute"
        case .fiveMinutes: return "After 5 minutes"
        }
    }
}

/// How notifications reach this device. `.apns`, the default, registers for
/// Apple push notifications. `.polling` registers no push token: the app checks
/// for due reminders and new shares itself, at launch and whenever iOS grants a
/// background app refresh (`PollingPushManager`), so no notification metadata
/// passes through Apple's push relay.
enum PushDeliveryMode: String, CaseIterable {
    case apns
    case polling

    var displayName: String {
        switch self {
        case .apns: return "Apple Push Notifications"
        case .polling: return "Polling (no vendor push)"
        }
    }
}

/// Render-time redaction level for the surfaces that put decrypted
/// note content where it outlives the in-app UI: local notifications
/// (reminders, the pinned-note notification) and the widget snapshot
/// persisted to app-group UserDefaults. Mirrors android
/// SessionManager's notification-detail level; unknown stored values
/// normalize to `.full` — this is a display preference, not a
/// security boundary.
enum NotificationDetailLevel: String, CaseIterable {
    case full
    case titles
    case generic

    var displayName: String {
        switch self {
        case .full: return "Titles and content"
        case .titles: return "Titles only"
        case .generic: return "Generic"
        }
    }
}

/// Mirrors android NotificationDetail.kt — pure helpers so the
/// redaction rules are testable without UNUserNotificationCenter.
enum NotificationDetail {
    /// Title line of the reminder banner. The only decrypted content a
    /// reminder carries is the note's title, so full and titles render
    /// the same; generic drops it.
    static func reminderTitle(_ level: NotificationDetailLevel, noteTitle: String) -> String {
        switch level {
        case .full, .titles:
            return noteTitle.isEmpty ? "Note reminder" : noteTitle
        case .generic:
            return "Note reminder"
        }
    }

    /// Title line of the pinned-note notification.
    static func pinnedTitle(_ level: NotificationDetailLevel, noteTitle: String) -> String {
        switch level {
        case .full, .titles:
            return noteTitle.isEmpty ? "Pinned note" : noteTitle
        case .generic:
            return "Pinned note"
        }
    }

    /// Body/preview of the pinned-note notification, or nil when the
    /// level says the decrypted body must not reach the notification
    /// center.
    static func pinnedSnippet(_ level: NotificationDetailLevel, snippet: String) -> String? {
        switch level {
        case .full: return snippet
        case .titles, .generic: return nil
        }
    }
}

enum AppEnvironment: String, CaseIterable {
    case production
    case development
    case local

    var authBaseURL: String {
        switch self {
        case .production: return "https://api-auth.pingolin.com"
        case .development: return "https://api-auth.pingolindev.com"
        case .local: return "http://localhost:8081"
        }
    }

    var apiBaseURL: String {
        switch self {
        case .production: return "https://api-note.pingolin.com"
        case .development: return "https://api-note.pingolindev.com"
        case .local: return "http://localhost:8090"
        }
    }

    /// Public-web base for note-web. Used as the host of public
    /// share-link URLs (token in path, per-note content key in the
    /// fragment so the server stays E2EE-blind).
    var webBaseURL: String {
        switch self {
        case .production: return "https://note.pingolin.com"
        case .development: return "https://note.pingolindev.com"
        case .local: return "http://localhost:3000"
        }
    }

    /// The shared Pingolin account portal, which owns everything to do with
    /// the account itself: password reset, the recovery address, recovery
    /// keys, sessions, billing. Note links out to it rather than
    /// reimplementing any of that.
    ///
    /// Same values as track-ios `AppEnvironment.accountBaseURL` and both
    /// Android apps' `BuildConfig.ACCOUNT_BASE_URL` — one account, one portal,
    /// so the constant must not diverge per client.
    var accountBaseURL: String {
        switch self {
        case .production: return "https://account.pingolin.com"
        case .development: return "https://account.pingolindev.com"
        case .local: return "http://localhost:3001"
        }
    }
}

final class AppConfiguration {
    static let shared = AppConfiguration()

    private let defaults = UserDefaults.standard
    private let environmentKey = "app_environment"
    private let appLockEnabledKey = "app_lock_enabled"
    private let pushDeliveryKey = "push_delivery_mode"
    private let notificationDetailKey = "notification_detail_level"
    private let autoLockTimeoutKey = "auto_lock_timeout"
    private let hideInAppSwitcherKey = "hide_in_app_switcher"

    private init() {}

    var environment: AppEnvironment {
        get {
            #if DEBUG
            if let raw = defaults.string(forKey: environmentKey),
               let env = AppEnvironment(rawValue: raw) {
                return env
            }
            return .development
            #elseif RELEASE_DEV
            // ReleaseDev: a distribution-signed TestFlight build whose hosts
            // are fixed to development AT COMPILE TIME (project.yml sets the
            // RELEASE_DEV condition on that configuration only), so a
            // TestFlight build can run against the development servers.
            // Still no runtime switch: the persisted override is ignored
            // here too.
            return .development
            #else
            // Release is pinned to production. Never honor a persisted
            // app_environment override — it would repoint the app off its
            // production hosts.
            return .production
            #endif
        }
        set { defaults.set(newValue.rawValue, forKey: environmentKey) }
    }

    /// When true, RootView shows a biometric/passcode gate before any
    /// authenticated tab. Mirrors android SessionManager.kt's
    /// `isAppLockEnabled` + `requiresAppLockAuth` flow.
    var appLockEnabled: Bool {
        get { defaults.bool(forKey: appLockEnabledKey) }
        set { defaults.set(newValue, forKey: appLockEnabledKey) }
    }

    /// How long the app may sit in the background before app lock re-arms.
    /// Only consulted when `appLockEnabled`.
    var autoLockTimeout: AutoLockTimeout {
        get { AutoLockTimeout(rawValue: defaults.integer(forKey: autoLockTimeoutKey)) ?? .immediately }
        set { defaults.set(newValue.rawValue, forKey: autoLockTimeoutKey) }
    }

    /// Cover note content while the app is not frontmost, so it does not appear
    /// in the multitasking switcher.
    ///
    /// This is the half of note-android's "Block screenshots" that iOS can
    /// actually do. `FLAG_SECURE` blocks the screenshot itself; iOS offers no
    /// equivalent and Apple provides no API to prevent a screenshot, so the
    /// switcher snapshot is the part worth covering — and it is the part that
    /// leaks without the user doing anything.
    ///
    /// Defaults to TRUE, matching note-android, which blocks by default.
    /// `object(forKey:)` rather than `bool(forKey:)` because the latter reads
    /// an unset key as false, which would silently invert the default.
    var hideInAppSwitcher: Bool {
        get { (defaults.object(forKey: hideInAppSwitcherKey) as? Bool) ?? true }
        set { defaults.set(newValue, forKey: hideInAppSwitcherKey) }
    }

    /// Default: APNs. Polling is opt-in via Settings → Security.
    var pushDeliveryMode: PushDeliveryMode {
        get {
            if let raw = defaults.string(forKey: pushDeliveryKey),
               let mode = PushDeliveryMode(rawValue: raw) {
                return mode
            }
            return .apns
        }
        set { defaults.set(newValue.rawValue, forKey: pushDeliveryKey) }
    }

    /// How much decrypted content reaches notifications + widget
    /// snapshots. Default: titles-only.
    ///
    /// The widget snapshot persists this text to the app-group container
    /// (see `SharedAppGroup.writeSnapshot`) as a data-protected file
    /// (AfterFirstUnlock) that is excluded from backup — so it is not
    /// iCloud/iTunes backup-eligible, unlike the note store's ciphertext
    /// which is. Defaulting to `.titles` still means body snippets are
    /// never written unless the user explicitly opts into "Titles and
    /// content" via Settings → the same picker also governs how much
    /// decrypted text lands in lock-screen notifications.
    var notificationDetail: NotificationDetailLevel {
        get {
            NotificationDetailLevel(
                rawValue: defaults.string(forKey: notificationDetailKey) ?? ""
            ) ?? .titles
        }
        set { defaults.set(newValue.rawValue, forKey: notificationDetailKey) }
    }

    var authBaseURL: String { environment.authBaseURL }
    var apiBaseURL: String { environment.apiBaseURL }
    var webBaseURL: String { environment.webBaseURL }
    var accountBaseURL: String { environment.accountBaseURL }

    // MARK: - Account portal deep links

    /// Where accounts are created. Note has no sign-up form of its own: the
    /// account portal owns registration for both apps, and the login screen
    /// links here so someone without an account can find it.
    var registerURL: URL? { accountURL(path: "/register") }

    /// Where someone who cannot sign in goes. The portal owns the whole
    /// reset flow — Note deliberately implements none of it.
    var forgotPasswordURL: URL? { accountURL(path: "/forgot-password") }

    /// Where the recovery address and recovery keys are managed. Both live on
    /// the portal's Settings page.
    var recoverySettingsURL: URL? { accountURL(path: "/settings") }

    /// Join a portal path onto `accountBaseURL` so every deep link follows the
    /// environment and a Release build cannot open the dev portal. Trailing
    /// slashes are trimmed for the same reason note-android's
    /// `BuildConfig.ACCOUNT_BASE_URL.trimEnd('/')` does it: the Android value
    /// carries one and the iOS value does not, and `//forgot-password` is a
    /// different path to the portal's router.
    private func accountURL(path: String) -> URL? {
        var base = accountBaseURL
        while base.hasSuffix("/") { base.removeLast() }
        return URL(string: base + path)
    }

    var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    /// User-Agent in the shape the auth server's device-model parser expects:
    /// `Note/<ver> (<model>; iOS <release>) urlsession`.
    ///
    /// WHY THIS SHAPE
    ///   The prefix must be one of `["Track/", "Note/", "PingolinTrack/",
    ///   "PingolinNote/"]` — and `PingolinNote/` is NOT a prefix of
    ///   `PingolinNote-iOS/` — or the session is stored as "Unknown Device".
    ///   The parser also reads the first `(...)` comment as the device model, so
    ///   a build number there would name every session "1".
    ///
    ///   Byte-for-byte the shape the Track iOS app sends (its
    ///   `Configuration.userAgent`), so the two apps name a device the same way.
    ///
    /// SCOPE
    ///   Naming happens when the session ROW IS CREATED, so a change here
    ///   renames only sessions created afterwards. Existing rows keep the name
    ///   they were stored with; a user can rename a device from Manage Devices.
    ///
    ///   The build number is unaffected: Settings still shows
    ///   "<version> (<build>)" from `appVersion`/`buildNumber`, the only place a
    ///   human reads it.
    var userAgent: String {
        "Note/\(appVersion) (\(Self.deviceModelToken); iOS \(Self.iosReleaseToken)) urlsession"
    }

    /// `utsname.machine` (e.g. "iPhone15,3") sanitized to the same charset
    /// Android applies (`[A-Za-z0-9 ._-]`), trimmed, and length-capped so it
    /// cannot break the UA header or the server parser. Empty machine string
    /// falls back to `iPhone`. Mirrors track-ios exactly.
    private static let deviceModelToken: String = {
        var info = utsname()
        uname(&info)
        let raw: String = withUnsafeBytes(of: &info.machine) { buf in
            guard let base = buf.baseAddress else { return "" }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 ._-")
        let cleaned = raw
            .filter { allowed.contains($0) }
            .trimmingCharacters(in: .whitespaces)
        let capped = String(cleaned.prefix(60))
        return capped.isEmpty ? "iPhone" : capped
    }()

    private static let iosReleaseToken: String = {
        // Computed once — systemVersion never changes within a process.
        UIDevice.current.systemVersion
    }()
}
