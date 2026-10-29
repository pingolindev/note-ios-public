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

/// What the server last told us about this account's recovery address.
///
/// A recovery address is a verified second email that can receive a
/// password-reset link when the primary inbox is gone. It is worth nothing
/// unless it is set up BEFORE the lockout, which is why a phone-first user has
/// to be able to find it from the app, not only in the account portal.
///
/// Deliberately a byte-for-byte twin of the Track iOS app's copy of this file.
/// The two apps are separate repos with no shared module, and they describe
/// the SAME account — so the wording has to match rather than each app
/// inventing its own account of what recovery does. Change one, change the
/// other.
///
/// This type reports state and nothing else. Everything that CREATES, VERIFIES,
/// REMOVES or CONSUMES a recovery address stays in the portal's single
/// implementation, and this app links out to it. That is deliberate rather than
/// lazy: recovery is subtle (a hash padding mistake can silently lock out a
/// share of email lengths, and SRP credentials derived against the wrong
/// address brick an account), and one implementation is one place to get it
/// right. A second implementation is a second place for such faults to hide,
/// in the one flow where the failure mode is "cannot get back in".
enum RecoveryEmailStatus: Equatable {
    /// No `/auth/me` response has landed yet — cold launch, offline, or a
    /// `User` built by a path that doesn't carry the fields (registration,
    /// the offline keychain rebuild, the UI-test synthetic session).
    ///
    /// Distinct from `.notSet` on purpose. "We have not asked the server" must
    /// never render as "you do not have one": telling someone their recovery
    /// address is missing when it is not is how you get them to replace a
    /// working one under stress.
    case unknown

    /// The server answered and there is no recovery address on the account.
    case notSet

    /// An address is on file, but the verification link sent to it has not
    /// been followed. It CANNOT receive a reset in this state — the auth
    /// server looks an account up only by a verified recovery address, so an
    /// unverified address matches nothing.
    case pendingVerification(address: String)

    /// Set and verified — this address can receive a password-reset link.
    case verified(address: String)

    /// Derive the state from the two `GET /api/v1/auth/me` fields.
    ///
    /// `verified` being nil is the signal for `.unknown`: the auth server
    /// always sends `recovery_email_verified`, so a `User` that lacks it did
    /// not come from `/auth/me`. `recovery_email` alone cannot carry that
    /// signal — the server leaves it out when there is none, so absent is
    /// exactly what a real account with no recovery address looks like.
    static func resolve(address: String?, verified: Bool?) -> RecoveryEmailStatus {
        guard let verified else { return .unknown }
        guard let address, !address.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .notSet
        }
        return verified ? .verified(address: address) : .pendingVerification(address: address)
    }

    /// The address itself, when there is one to show.
    var address: String? {
        switch self {
        case .unknown, .notSet: return nil
        case .pendingVerification(let address), .verified(let address): return address
        }
    }

    /// One-line state, shown as the row's value.
    var summary: String {
        switch self {
        case .unknown: return "Checking…"
        case .notSet: return "Not set up"
        case .pendingVerification: return "Needs verifying"
        case .verified: return "Set up"
        }
    }

    /// The sentence under the row. Says what this state means for someone who
    /// is locked out right now, not what the field contains.
    var detail: String {
        switch self {
        case .unknown:
            return "Couldn't check your recovery address. Open your account settings to see it."
        case .notSet:
            return "Without one, losing access to your primary email means losing the account. Add one now — it can't be added once you're locked out."
        case .pendingVerification(let address):
            return "\(address) hasn't been confirmed yet, so it can't receive a reset link. Open the link we emailed to that address."
        case .verified(let address):
            return "\(address) can receive a password reset link if you lose access to your primary email."
        }
    }

    /// Whether this state is something the user should act on. Drives the
    /// warning tint — an account with no recovery address is precisely the one
    /// whose owner most needs to be told so.
    var needsAttention: Bool {
        switch self {
        case .notSet, .pendingVerification: return true
        case .unknown, .verified: return false
        }
    }
}

/// Copy shared by the Settings row and any other surface that has to explain
/// the boundary. Kept in one place so the two halves can't drift apart and
/// start implying different things about what recovery gets back.
enum RecoveryCopy {
    /// The whole point, in one sentence. A recovery address restores ACCOUNT
    /// access — the ability to sign in. It does not decrypt anything: the
    /// server never holds a key that could, so a reset leaves the encrypted
    /// data needing the recovery key, and saying otherwise would promise
    /// someone their notes and location history are coming back when they
    /// are not.
    static let scope = """
        A recovery address gets you back into your account. It does not unlock \
        your encrypted data — that needs your recovery key. Set up both while \
        you still can: neither can be added once you're locked out.
        """

    /// Why the app hands this to the browser instead of doing it here.
    static let managedInPortal =
        "Recovery is managed in your Pingolin account settings."
}
