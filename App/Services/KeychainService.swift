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
import Security

final class KeychainService {
    static let shared = KeychainService()

    private let service = "com.pingolin.note"

    private init() {}

    enum Key: String, CaseIterable {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case userId = "user_id"
        /// Non-secret profile fields persisted so an offline launch can
        /// rebuild `currentUser` (and keep the share-wrap gate armed).
        case email = "user_email"
        case displayName = "user_display_name"
        case deviceId = "device_id"
        /// Base64-encoded master key, decrypted from `encrypted_master_key` with
        /// the user's password + Argon2id KDF at login. NOT the vault key — see
        /// AuthManager for the full derivation chain.
        case masterKey = "master_key"
        /// Final vault key (BLAKE2b-keyed sharing private key). Used as
        /// vaultKeyBase64 for encryptNote/decryptNote.
        case vaultKey = "vault_key"
        /// X25519 sharing private key (32 bytes, base64). Unwrapped from
        /// encrypted_sharing_private_key with the master key during login.
        /// Needed for opening sealed-box wrapped keys from incoming shares.
        case sharingPrivateKey = "sharing_private_key"
        /// X25519 sharing public key (32 bytes, base64). Derived at sign-in
        /// from the sharing private key that opened, never taken from the
        /// server's reply. Sent when the user is the sender of a share.
        case sharingPublicKey = "sharing_public_key"
        /// Ed25519 signing seed (32 bytes, base64) decrypted from
        /// `encrypted_signing_private_key` with the master key at login.
        /// This is the REAL identity signing key published as
        /// `signing_public_key`; `WebKeyBridge` feeds it to
        /// `signNoteShareWrap` so share-wrap signatures verify against the
        /// sender's directory key. It is not the X25519 sharing scalar: a wrap
        /// signed with that would not verify (see AuthManager.checkSigningKey).
        case signingPrivateKey = "signing_private_key"
        /// DCAppAttestService key handle (one per install). Persists
        /// across logout so we don't burn an attest call per user
        /// switch on the same device.
        case attestKeyId = "attest.key_id"
        /// Cached `{token,expiresAt}` JSON from
        /// /api/v1/auth/attest/apple. Refreshed when within 5 minutes
        /// of expiry.
        case attestCachedToken = "attest.cached_token"
        /// 32-byte SQLCipher passphrase (base64) for the local encrypted read
        /// cache (offline support). Generated once. The iOS analog of
        /// android's DatabasePassphraseManager (Keystore-wrapped passphrase).
        /// Wiped on logout with everything else — NoteStore self-heals by
        /// rebuilding the cache DB from the server on the next login (the cache
        /// is disposable; the server is the source of truth). Pinned to this
        /// device (see `accessibility`) so it can never ride a backup off-device
        /// and decrypt a cached plaintext copy of the user's notes elsewhere.
        case localDbKey = "local_db_key"
        /// Incremental-sync watermark: the server's compound keyset cursor
        /// (`SyncResponse.cursor` = the last synced item's `updated_at`) from the
        /// most recent full/delta pull. Threaded back as `since` so a foreground /
        /// launch sync fetches only what changed instead of re-downloading the
        /// whole vault. Non-secret (a coarse activity timestamp); wiped on logout /
        /// account switch with everything else. Pinned to this device because it's
        /// only meaningful paired with THIS device's local cache — a restored
        /// backup lands on an empty cache, which forces a full scan regardless.
        case syncCursor = "sync_cursor"
        /// Tie-breaker paired with `syncCursor` (`SyncResponse.cursorId` = the last
        /// synced item's id), threaded back as `since_id` so same-`updated_at`
        /// items split across a page boundary are neither skipped nor re-sent.
        case syncCursorId = "sync_cursor_id"

        /// Keychain accessibility class for this item.
        ///
        /// Long-term E2EE key material AND the session tokens are pinned to
        /// *this device* (`AfterFirstUnlockThisDeviceOnly`) so they cannot be
        /// restored onto a different device via an encrypted iCloud/iTunes
        /// backup. The server is blind, so leaking key material off-device
        /// would expose the user's notes; the access/refresh tokens are bearer
        /// credentials that likewise shouldn't ride a backup onto another
        /// device (a migrated device just re-logs in). The App Attest key
        /// handle + its cached server token are `...ThisDeviceOnly` too: the
        /// key-id references a Secure-Enclave key that never migrates anyway (a
        /// restored handle is dead), and the cached token is a server-minted
        /// attest bearer that shouldn't ride a backup onto another device. Only
        /// re-fetchable / non-secret identifiers stay `AfterFirstUnlock` so they
        /// survive a legitimate device migration (they're re-derived from the
        /// server on next launch, and none of them can decrypt content on their
        /// own).
        var accessibility: CFString {
            switch self {
            case .masterKey, .vaultKey, .sharingPrivateKey, .signingPrivateKey,
                 .accessToken, .refreshToken,
                 .attestKeyId, .attestCachedToken,
                 .localDbKey, .syncCursor, .syncCursorId:
                return kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            case .userId, .deviceId,
                 .email, .displayName,
                 .sharingPublicKey:
                return kSecAttrAccessibleAfterFirstUnlock
            }
        }
    }

    func save(_ value: String, for key: Key) throws {
        let data = Data(value.utf8)
        try save(data, for: key.rawValue, accessible: key.accessibility)
    }

    func getString(for key: Key) -> String? {
        guard let data = getData(for: key.rawValue) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// What a read found. `getString` folds the last two cases into nil; a
    /// caller that must not take "can't read it now" for "nothing stored" asks
    /// this.
    enum Read: Equatable {
        case found(String)
        /// errSecItemNotFound: nothing is stored under this key.
        case notFound
        /// Any other status: the item may well be there.
        /// `errSecInteractionNotAllowed` is the Keychain before the first
        /// unlock after a restart (see `ProtectedData`).
        case unreadable(OSStatus)
    }

    func read(_ key: Key) -> Read {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return Self.interpret(status: status, data: result as? Data)
    }

    /// A value that is not UTF-8 is still FOUND (decoded lossily): it is
    /// there, and what it is worth is the caller's to judge, as with a value
    /// that doesn't parse.
    static func interpret(status: OSStatus, data: Data?) -> Read {
        switch status {
        case errSecSuccess:
            guard let data else { return .unreadable(errSecDecode) }
            return .found(String(decoding: data, as: UTF8.self))
        case errSecItemNotFound:
            return .notFound
        default:
            return .unreadable(status)
        }
    }

    /// Returns the 32-byte SQLCipher passphrase for the local cache DB,
    /// generating and persisting it (base64) on first use. Mirrors android's
    /// `DatabasePassphraseManager.getOrCreatePassphrase`.
    func localDatabaseKey() throws -> Data {
        try Self.databaseKey(
            stored: read(.localDbKey),
            mint: {
                var bytes = [UInt8](repeating: 0, count: 32)
                let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
                guard status == errSecSuccess else { throw KeychainError.saveFailed(status) }
                return Data(bytes)
            },
            save: { try self.save($0, for: .localDbKey) }
        )
    }

    /// A new passphrase is minted ONLY when none is stored. One that is
    /// stored but can't be read right now is never replaced: the cache it
    /// opens holds the offline outbox (edits not yet pushed), and
    /// `NoteStore.openOrRebuild` deletes a file its key doesn't open. The
    /// throw leaves the store closed for this launch instead, with the file
    /// kept for the next. A stored value that isn't a 32-byte key opens
    /// nothing either way, and is replaced.
    static func databaseKey(
        stored: Read,
        mint: () throws -> Data,
        save: (String) throws -> Void
    ) throws -> Data {
        switch stored {
        case .found(let existing):
            if let data = Data(base64Encoded: existing), data.count == 32 { return data }
        case .notFound:
            break
        case .unreadable(let status):
            throw KeychainError.readFailed(status)
        }
        let data = try mint()
        try save(data.base64EncodedString())
        return data
    }

    func delete(key: Key) {
        delete(for: key.rawValue)
    }

    func deleteAll() {
        // Wipe EVERYTHING on logout, including .attestKeyId. Persisting the
        // App Attest key handle across account switches would let the auth
        // server see the same key_id on two different accounts' logins from
        // one install - a cross-account install-linkage identifier this app
        // must not introduce (track-ios likewise wipes its attest
        // key). Keeping it saves only a local generateKey() call - the cached
        // token is wiped here too, so the next user re-runs the full attest
        // chain regardless - which does not justify the linkage.
        Key.allCases.forEach { delete(key: $0) }
    }

    private func save(_ data: Data, for key: String, accessible: CFString) throws {
        // Atomic upsert. SecItemDelete then SecItemAdd would leave a window in
        // which a concurrent reader observes NO item. So add first; if the item
        // already exists (errSecDuplicateItem), update its value + accessibility
        // in place, so a reader always sees either the old or the new value,
        // never nothing.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessible
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            // Item already present — update it in place. The match query names
            // the item; `attributes` carries the new data AND accessibility, so
            // long-term keys keep their ...ThisDeviceOnly class (Key.accessibility)
            // — the accessibility is NOT weakened by the update.
            let matchQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key
            ]
            let attributes: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: accessible
            ]
            let updateStatus = SecItemUpdate(matchQuery as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecSuccess else { throw KeychainError.saveFailed(updateStatus) }
            return
        }
        guard status == errSecSuccess else { throw KeychainError.saveFailed(status) }
    }

    private func getData(for key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    private func delete(for key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }

    enum KeychainError: Error {
        case saveFailed(OSStatus)
        case readFailed(OSStatus)
    }
}
