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

/// Mirrors android AuthRateLimiter.kt: 5 attempts, then exponential
/// backoff (30s → 60s → 120s → 240s → 480s) inside a 15-minute window.
/// Keyed by lowercased+trimmed email so case-only variations don't bypass
/// the counter. Attempts are reset on a successful login.
///
/// State lives in UserDefaults (matches android's SharedPreferences
/// approach) — this is cosmetic UX guidance, not a security barrier.
@MainActor
final class AuthRateLimiter {
    static let shared = AuthRateLimiter()

    private let defaults = UserDefaults.standard
    private let attemptsPrefix = "auth_rl_attempts_"
    private let firstAttemptPrefix = "auth_rl_first_"
    private let lastAttemptPrefix = "auth_rl_last_"

    private let maxAttempts = 5
    private let backoffSeconds: [TimeInterval] = [30, 60, 120, 240, 480]
    private let windowSeconds: TimeInterval = 15 * 60

    private init() {}

    func check(email: String) throws {
        let key = normalize(email)
        let now = Date().timeIntervalSince1970

        // Window expired → wipe counter and let the user try again.
        let firstAttempt = defaults.double(forKey: firstAttemptPrefix + key)
        if firstAttempt > 0, now - firstAttempt > windowSeconds {
            reset(key: key)
            return
        }

        let attempts = defaults.integer(forKey: attemptsPrefix + key)
        guard attempts >= maxAttempts else { return }

        let lastAttempt = defaults.double(forKey: lastAttemptPrefix + key)
        let backoffIndex = min(attempts - maxAttempts, backoffSeconds.count - 1)
        let backoff = backoffSeconds[backoffIndex]
        let resumeAt = lastAttempt + backoff
        if now < resumeAt {
            throw AuthRateLimitError.tooManyAttempts(retryAfter: resumeAt - now)
        }
    }

    /// Call after a server response — successful or otherwise — to
    /// advance the counter. The check() above only blocks before the
    /// server is hit; tally() is what actually rate-limits.
    func tally(email: String) {
        let key = normalize(email)
        let now = Date().timeIntervalSince1970
        if defaults.double(forKey: firstAttemptPrefix + key) == 0 {
            defaults.set(now, forKey: firstAttemptPrefix + key)
        }
        defaults.set(now, forKey: lastAttemptPrefix + key)
        defaults.set(defaults.integer(forKey: attemptsPrefix + key) + 1,
                     forKey: attemptsPrefix + key)
    }

    func clear(email: String) {
        reset(key: normalize(email))
    }

    private func reset(key: String) {
        defaults.removeObject(forKey: attemptsPrefix + key)
        defaults.removeObject(forKey: firstAttemptPrefix + key)
        defaults.removeObject(forKey: lastAttemptPrefix + key)
    }

    private func normalize(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    enum AuthRateLimitError: LocalizedError {
        case tooManyAttempts(retryAfter: TimeInterval)

        var errorDescription: String? {
            switch self {
            case .tooManyAttempts(let retryAfter):
                let seconds = Int(retryAfter.rounded(.up))
                return "Too many failed attempts. Try again in \(seconds)s."
            }
        }
    }
}
