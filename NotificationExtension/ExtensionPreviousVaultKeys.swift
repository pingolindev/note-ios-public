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
#if NOTE_TESTS
@testable import Note
#endif

/// The vault keys of identities recovered from before a password reset, for a
/// note whose key does not open with the current vault key (the app's
/// `PreviousIdentityLoader`, run once here): the account's sealed earlier
/// identities from the auth server, opened by the SDK with this account's
/// stored keys, read only. Almost every account has none, and this runs only
/// when a share's note needs it. Anything that does not work is no keys.
enum ExtensionPreviousVaultKeys {
    static func load(token: String, authBase: String?, deadline: Date, transport: FinisherTransport,
                     now: () -> Date, keychain: (KeychainService.Key) -> KeychainService.Read) async -> [Data] {
        let left = deadline.timeIntervalSince(now())
        guard let authBase, left > 3, let url = URL(string: authBase + "/api/v1/auth/previous-identities") else {
            return []
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = min(8, left - 0.5)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await transport.send(request), response.statusCode == 200,
              let rows = (FinisherAPI.payload(data) as? [String: Any])?["identities"] as? [Any]
        else { return [] }
        // The v1 blobs, exactly as received, as the app's loader imports them.
        let sealed = rows.compactMap { row -> SealedPreviousIdentity? in
            guard let blob = (row as? [String: Any])?["app_sealed_private_key"] as? [String: Any],
                  let nonce = blob["nonce"] as? String, let ciphertext = blob["ciphertext"] as? String
            else { return nil }
            return SealedPreviousIdentity(nonce: nonce, ciphertext: ciphertext)
        }
        guard !sealed.isEmpty else { return [] }

        let manager = CryptoManager()
        manager.registerSecureStorage(storage: ExtensionKeyStorage())
        guard (try? manager.loadPersistedKeys()) == true else { return [] }
        // Only this account's store: its public key is the one the app derived
        // at sign-in. Another's (a wipe still owed) opens nothing of ours.
        guard case .found(let stored) = keychain(.sharingPublicKey),
              let mine = Data(base64Encoded: stored), mine.count == 32,
              let exported = try? manager.exportPublicKey(), Data(base64Encoded: exported) == mine
        else { return [] }
        guard (try? manager.importPreviousIdentities(sealed: sealed)) != nil else { return [] }
        return manager.previousVaultKeys().compactMap { Data(base64Encoded: $0) }.filter { $0.count == 32 }
    }
}

/// READ-ONLY key storage for the SDK in the notification extension: the same
/// items as the app's `KeychainKeyStorageCallback`, readable through the app's
/// keychain group. Both writes are no-ops: a background process racing the
/// app over the account's keys is far worse than a share finished later. A
/// read that fails for any reason but "not there" throws, never "nothing".
final class ExtensionKeyStorage: KeyStorageCallback {
    private static let service = "com.pingolin.note.sdk.cryptomanager"

    func loadKeys() throws -> StoredKeyData? {
        let privateKey = try read("private_key")
        let circleKeys = try read("circle_keys_json")
        let pins = try read("pinned_keys_json")
        let signing = try read("signing_private_key_b64")
        if privateKey == nil, circleKeys == nil, pins == nil, signing == nil { return nil }
        return StoredKeyData(privateKey: privateKey ?? "", circleKeysJson: circleKeys ?? "",
                             pinnedKeysJson: pins, signingPrivateKeyB64: signing)
    }

    func storeKeys(data: StoredKeyData) throws {}

    func deleteKeys() throws {}

    private func read(_ account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw StorageCallbackError.Failed }
        return String(decoding: data, as: UTF8.self)
    }
}
