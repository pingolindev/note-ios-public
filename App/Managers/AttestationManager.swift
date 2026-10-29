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
import DeviceCheck
import CryptoKit

/// App Attest integration. Acquires a server-issued attestation token
/// (`X-Attestation-Token` header) so register / login + other captcha-
/// guarded endpoints can skip Cloudflare Turnstile when the request
/// comes from a real, unmodified app on a real device.
///
/// Flow per the auth server (the same as in the Track iOS app):
///   1. DCAppAttestService.generateKey() once per install → keyId.
///   2. GET /api/v1/auth/attest/challenge?platform=apple → nonce.
///   3. DCAppAttestService.attestKey(keyId, clientDataHash:
///        sha256(challenge)) → attestation object.
///   4. POST /api/v1/auth/attest/apple {attestation, challenge, key_id}
///        → {attestation_token, platform, expires_at}.
///   5. Echo attestation_token back as X-Attestation-Token on
///        subsequent SRP step1 / step2 / refresh / signing-key
///        regenerate requests.
///
/// The token is cached in keychain until 5 min before expiry so the
/// app doesn't run the full chain on every login. Returns nil on
/// platforms / states where App Attest is unavailable (Simulator,
/// jailbroken, < iOS 14, or when the server reports
/// `apple_attest_enabled = false`) so callers gracefully fall back
/// to the un-attested path.
@MainActor
final class AttestationManager {
    static let shared = AttestationManager()

    private let api = APIService.shared
    private let keychain = KeychainService.shared
    private let attest = DCAppAttestService.shared

    private struct CachedToken: Codable {
        let token: String
        let expiresAt: Date
    }

    /// Server-side enablement flag, fetched lazily. nil = haven't asked.
    private var serverEnabled: Bool?

    private init() {}

    /// Returns a usable attestation token, fetching one if the cache is
    /// empty or near expiry. Returns nil on devices that don't support
    /// App Attest, or when the server says Apple Attest is disabled —
    /// callers fall through with the un-attested request.
    func getOrFetchToken() async -> String? {
        if let cached = loadCachedToken(), cached.expiresAt > Date().addingTimeInterval(5 * 60) {
            return cached.token
        }
        guard attest.isSupported else { return nil }

        // Check server enablement once per process; cheap call but
        // pointless to repeat for every auth flow within the same
        // session.
        if serverEnabled == nil {
            do {
                let status = try await api.getAttestationStatus()
                serverEnabled = status.appleAttestEnabled
            } catch {
                #if DEBUG
                print("[Note] attestation status fetch failed: \(error)")
                #endif
                return nil
            }
        }
        guard serverEnabled == true else { return nil }

        do {
            let keyId = try await ensureKeyId()
            let challenge = try await api.getAttestationChallenge()
            guard let challengeData = challenge.challenge.data(using: .utf8) else { return nil }
            let hash = Data(SHA256.hash(data: challengeData))
            let attestation = try await attest.attestKey(keyId, clientDataHash: hash)
            let response = try await api.verifyAppleAttestation(
                attestation: attestation.base64EncodedString(),
                challenge: challenge.challenge,
                keyId: keyId
            )
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let expires = formatter.date(from: response.expiresAt)
                ?? Date().addingTimeInterval(60 * 60)
            cache(CachedToken(token: response.attestationToken, expiresAt: expires))
            return response.attestationToken
        } catch {
            #if DEBUG
            print("[Note] attestation fetch failed: \(error)")
            #endif
            // If `generateKey` failed (server rejected the keyId, key
            // got revoked, etc.), wipe the key handle so the next call
            // mints a fresh one.
            keychain.delete(key: .attestKeyId)
            return nil
        }
    }

    /// Drop the cached attestation token. Called on logout so the next
    /// user's session re-attests fresh. The key handle itself is kept
    /// (App Attest keys are tied to the install, not the user).
    func resetToken() {
        keychain.delete(key: .attestCachedToken)
    }

    /// Wipe both the cached token AND the key handle. Used when the
    /// server explicitly rejects the keyId (revoked, replay-detected,
    /// etc.) so the next call regenerates from scratch.
    func resetAll() {
        keychain.delete(key: .attestCachedToken)
        keychain.delete(key: .attestKeyId)
        serverEnabled = nil
    }

    // MARK: - Internal

    private func ensureKeyId() async throws -> String {
        if let existing = keychain.getString(for: .attestKeyId) {
            return existing
        }
        let keyId = try await attest.generateKey()
        try keychain.save(keyId, for: .attestKeyId)
        return keyId
    }

    private func loadCachedToken() -> CachedToken? {
        guard let raw = keychain.getString(for: .attestCachedToken),
              let data = raw.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CachedToken.self, from: data)
    }

    private func cache(_ token: CachedToken) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let encoded = try? encoder.encode(token),
              let raw = String(data: encoded, encoding: .utf8) else { return }
        try? keychain.save(raw, for: .attestCachedToken)
    }
}
