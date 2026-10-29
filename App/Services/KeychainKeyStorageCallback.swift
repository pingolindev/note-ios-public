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
import PingolinNoteSDK
import Security

/// iOS `KeyStorageCallback` backed by the system Keychain. The SDK's
/// `CryptoManager` calls into this whenever it needs to persist or load its
/// stored key bundle. This app only uses the signing-key slot (the vault
/// key + per-item content keys live in `KeychainService`), but we
/// implement the full `StoredKeyData` contract so `importSigningPrivateKey` /
/// `generateSigningKeypair` auto-persist and survive cold starts — otherwise
/// the SDK would forget the signing key on every relaunch (or the key would
/// silently disappear). Mirrors the Track apps' `KeychainKeyStorageCallback`
/// (iOS) and `KeyStorageCallbackImpl` (Android).
///
/// Every item is written `AfterFirstUnlockThisDeviceOnly`: this is long-term
/// key material and must never leave the device via an encrypted backup.
///
/// A failure THROWS, and only `StorageCallbackError.Failed` (the SDK's
/// contract): the SDK then knows it could not read or write, and keeps every
/// write off a store it couldn't read. `nil` from `loadKeys` means nothing at
/// all is stored, and only that.
final class KeychainKeyStorageCallback: KeyStorageCallback {
    private static let service = "com.pingolin.note.sdk.cryptomanager"
    private static let privateKeyAccount = "private_key"
    private static let circleKeysJsonAccount = "circle_keys_json"
    private static let pinnedKeysJsonAccount = "pinned_keys_json"
    private static let signingPrivateKeyAccount = "signing_private_key_b64"

    typealias CopyMatching = @Sendable (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    private let copyMatching: CopyMatching

    /// `copyMatching` is a seam for tests: the simulator never refuses a read.
    init(copyMatching: @escaping CopyMatching = SecItemCopyMatching) {
        self.copyMatching = copyMatching
    }

    func storeKeys(data: StoredKeyData) throws {
        try writeString(data.privateKey, account: Self.privateKeyAccount)
        try writeString(data.circleKeysJson, account: Self.circleKeysJsonAccount)
        if let pinned = data.pinnedKeysJson {
            try writeString(pinned, account: Self.pinnedKeysJsonAccount)
        } else {
            try deleteEntry(account: Self.pinnedKeysJsonAccount)
        }
        if let signing = data.signingPrivateKeyB64 {
            try writeString(signing, account: Self.signingPrivateKeyAccount)
        } else {
            try deleteEntry(account: Self.signingPrivateKeyAccount)
        }
    }

    func loadKeys() throws -> StoredKeyData? {
        Self.stored(
            privateKey: try readString(account: Self.privateKeyAccount),
            circleKeysJson: try readString(account: Self.circleKeysJsonAccount),
            pinnedKeysJson: try readString(account: Self.pinnedKeysJsonAccount),
            signingPrivateKeyB64: try readString(account: Self.signingPrivateKeyAccount)
        )
    }

    /// nil ONLY when none of the four entries is stored. A store with some
    /// missing (a write cut short) gives what it has, with "" for a missing
    /// private key or circle-key map: the SDK then finds it doesn't decode,
    /// and the next explicit sign-in clears it (the SDK's contract). nil
    /// would let the next write replace what is there; "{}" would claim an
    /// empty set.
    static func stored(
        privateKey: String?,
        circleKeysJson: String?,
        pinnedKeysJson: String?,
        signingPrivateKeyB64: String?
    ) -> StoredKeyData? {
        if privateKey == nil, circleKeysJson == nil, pinnedKeysJson == nil, signingPrivateKeyB64 == nil {
            return nil
        }
        return StoredKeyData(
            privateKey: privateKey ?? "",
            circleKeysJson: circleKeysJson ?? "",
            pinnedKeysJson: pinnedKeysJson,
            signingPrivateKeyB64: signingPrivateKeyB64
        )
    }

    func deleteKeys() throws {
        try deleteEntry(account: Self.privateKeyAccount)
        try deleteEntry(account: Self.circleKeysJsonAccount)
        try deleteEntry(account: Self.pinnedKeysJsonAccount)
        try deleteEntry(account: Self.signingPrivateKeyAccount)
    }

    // MARK: - Keychain primitives

    private func writeString(_ value: String, account: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw StorageCallbackError.Failed
        }
        // Atomic upsert (mirrors KeychainService.save). SecItemDelete followed
        // by SecItemAdd would leave a window in which a concurrent reader
        // (loadKeys) observes NO item —
        // the SDK could then think its stored key bundle vanished. Instead add
        // first; if the item already exists (errSecDuplicateItem), update its
        // value AND accessibility in place, so a reader always sees either the
        // old or the new value, never nothing. The update re-applies
        // ...AfterFirstUnlockThisDeviceOnly, so the item keeps its
        // this-device-only class (never weakened by the update). No delete step.
        var attrs = baseQuery(account: account)
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attrs as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let attributes: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ]
            let updateStatus = SecItemUpdate(baseQuery(account: account) as CFDictionary,
                                             attributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw Self.failed(updateStatus)
            }
            return
        }
        guard status == errSecSuccess else {
            throw Self.failed(status)
        }
    }

    /// The entry's value, or nil when it is not stored. Every other status
    /// throws: a read that failed (`errSecInteractionNotAllowed` before the
    /// first unlock above all) must never read as "not stored".
    private func readString(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = copyMatching(query as CFDictionary, &result)
        return try Self.value(status: status, data: result as? Data)
    }

    /// Bytes that aren't UTF-8 are passed through, never thrown: the SDK then
    /// finds they don't decode, which a sign-in recovers. A throw reads as the
    /// platform failing, which nothing ever clears.
    static func value(status: OSStatus, data: Data?) throws -> String? {
        switch status {
        case errSecSuccess:
            guard let data else { throw failed(status) }
            return String(decoding: data, as: UTF8.self)
        case errSecItemNotFound:
            return nil
        default:
            throw failed(status)
        }
    }

    private func deleteEntry(account: String) throws {
        let query = baseQuery(account: account)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Self.failed(status)
        }
    }

    /// The SDK's error. The status goes to the DEBUG console only.
    private static func failed(_ status: OSStatus) -> StorageCallbackError {
        #if DEBUG
        print("[Note] SDK key store: Keychain status \(status)")
        #endif
        return .Failed
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
    }
}
