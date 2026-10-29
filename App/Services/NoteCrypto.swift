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
import Sodium

/// Note content + share crypto. Routes the byte-format-sensitive
/// operations (per-item content key generation, AEAD framing,
/// secretbox wrap, sealed-box seal/open) through the Rust
/// note-collab-sdk via UniFFI so iOS, android, and the web client all
/// produce byte-identical ciphertexts. swift-sodium stays around only
/// for the attachment-body / metadata AEAD.
enum NoteCrypto {
    private static let sodium = Sodium()

    /// Encrypts a plaintext string with the user's vault key
    /// (legacy path: content_key == vault_key). Uses
    /// `encrypt_note_with_content_key` so the format matches the
    /// wrapped path byte-for-byte.
    static func encrypt(plaintext: String, vaultKeyBase64: String) throws -> (ciphertext: String, nonce: String) {
        guard let vaultKey = decodeBase64Data(vaultKeyBase64) else {
            throw CryptoError.invalidVaultKey
        }
        do {
            let result = try encryptNoteWithContentKey(plaintext: plaintext, contentKey: vaultKey)
            return (result.ciphertextB64, result.nonceB64)
        } catch {
            throw CryptoError.encryptFailed
        }
    }

    /// Decrypts an Item, transparently handling both encryption paths:
    /// - **Legacy** (`wrappedContentKey == nil`): content is encrypted
    ///   directly under the vault key.
    /// - **Wrapped** (`wrappedContentKey != nil`): per-item content key
    ///   is unwrapped with the vault key, content is decrypted with
    ///   that.
    /// Both paths go through the SDK so the AEAD frame matches android
    /// and the web byte-for-byte.
    static func decrypt(_ item: Item, vaultKeyBase64: String) throws -> Data {
        guard let vaultKey = decodeBase64Data(vaultKeyBase64) else {
            throw CryptoError.invalidVaultKey
        }

        let contentKey: Data
        if let wrappedB64 = item.wrappedContentKey,
           let wrappedNonceB64 = item.wrappedContentKeyNonce {
            // The current vault key first, then the vault key of any identity
            // RECOVERED from before a password reset.
            //
            // note's vault key is DERIVED from the account keypair, so a reset
            // changes it and EVERY older note fails this unwrap — a device with
            // a valid session and a library it cannot read. Current key first
            // always: preferring a recovered one would keep the app reading
            // through a superseded identity long after the user moved off it.
            var resolved = unwrapWithVault(
                wrappedKeyB64: wrappedB64,
                nonceB64: wrappedNonceB64,
                vaultKey: vaultKey
            )
            if resolved == nil {
                for previousB64 in PreviousIdentityLoader.shared.vaultKeys() {
                    guard let previousVault = decodeBase64Data(previousB64) else { continue }
                    if let key = unwrapWithVault(
                        wrappedKeyB64: wrappedB64,
                        nonceB64: wrappedNonceB64,
                        vaultKey: previousVault
                    ) {
                        resolved = key
                        break
                    }
                }
            }
            guard let key = resolved else { throw CryptoError.unwrapContentKeyFailed }
            contentKey = key
        } else {
            contentKey = vaultKey
        }

        guard let plaintext = decryptNoteWithContentKeyV2(
            nonceB64: item.contentNonce,
            ciphertextB64: item.encryptedContent,
            contentKey: contentKey,
            itemId: item.id
        ) else { throw CryptoError.decryptFailed }
        return Data(plaintext.utf8)
    }

    /// Encrypt a plaintext via the per-item-content-key path.
    /// Generates a fresh 32-byte content key,
    /// AEAD-encrypts the plaintext under it, and wraps the content
    /// key with the vault key via secretbox. Byte-compatible with
    /// note-collab-sdk's `encrypt_note_with_content_key` +
    /// `wrap_with_vault` — which is exactly what this calls.
    static func encryptWithWrappedKey(plaintext: String, vaultKeyBase64: String) throws -> WrappedItemCiphertext {
        guard let vaultKey = decodeBase64Data(vaultKeyBase64) else {
            throw CryptoError.invalidVaultKey
        }
        let contentKey = generateContentKey()
        let cipher: PingolinNoteSDK.NoteCiphertext
        let wrapped: PingolinNoteSDK.WrappedKey
        do {
            cipher = try encryptNoteWithContentKey(plaintext: plaintext, contentKey: contentKey)
            wrapped = try wrapWithVault(contentKey: contentKey, vaultKey: vaultKey)
        } catch {
            throw CryptoError.encryptFailed
        }
        return WrappedItemCiphertext(
            encryptedContent: cipher.ciphertextB64,
            contentNonce: cipher.nonceB64,
            wrappedContentKey: wrapped.wrappedKeyB64,
            wrappedContentKeyNonce: wrapped.nonceB64
        )
    }

    /// v2 variant of `encryptWithWrappedKey` that binds the fresh ciphertext to
    /// `itemId` (AAD v2) instead of the legacy EMPTY-AAD frame, for a write whose
    /// id is known before it is sent: a restored note keeps its original id, and
    /// a conflict copy is given a new one. Readers accept v2 (they try v2-then-v1 —
    /// `decrypt`/`decryptItem` pass the itemId), so binding on the write side is
    /// safe. The plain `encryptWithWrappedKey` (no itemId) stays for the CREATE
    /// path, whose id is server-assigned — there is no id to bind at encrypt time.
    static func encryptWithWrappedKey(plaintext: String, vaultKeyBase64: String, itemId: String) throws -> WrappedItemCiphertext {
        guard let vaultKey = decodeBase64Data(vaultKeyBase64) else {
            throw CryptoError.invalidVaultKey
        }
        let contentKey = generateContentKey()
        let cipher: PingolinNoteSDK.NoteCiphertext
        let wrapped: PingolinNoteSDK.WrappedKey
        do {
            cipher = try encryptNoteWithContentKeyV2(plaintext: plaintext, contentKey: contentKey, itemId: itemId)
            wrapped = try wrapWithVault(contentKey: contentKey, vaultKey: vaultKey)
        } catch {
            throw CryptoError.encryptFailed
        }
        return WrappedItemCiphertext(
            encryptedContent: cipher.ciphertextB64,
            contentNonce: cipher.nonceB64,
            wrappedContentKey: wrapped.wrappedKeyB64,
            wrappedContentKeyNonce: wrapped.nonceB64
        )
    }

    enum CryptoError: LocalizedError {
        case invalidVaultKey, unwrapContentKeyFailed
        case decryptFailed, encryptFailed, base64EncodeFailed
        case invalidPrivateKey, unsealFailed

        var errorDescription: String? {
            switch self {
            case .invalidVaultKey: return "Vault key not valid base64"
            case .unwrapContentKeyFailed: return "Failed to unwrap per-item content key with vault key"
            case .decryptFailed: return "AEAD decrypt failed (key/ciphertext mismatch)"
            case .encryptFailed: return "AEAD encrypt failed"
            case .base64EncodeFailed: return "Base64 encoding failed"
            case .invalidPrivateKey: return "Sharing private key is not 32 bytes"
            case .unsealFailed: return "Sealed-box decryption failed (wrong key?)"
            }
        }
    }

    /// swift-sodium-style base64 → Data via libsodium so we stay
    /// consistent with how we encode keys at login (variant `.ORIGINAL`
    /// = standard padded base64, no URL-safety).
    private static func decodeBase64Data(_ s: String) -> Data? {
        guard let bytes = sodium.utils.base642bin(s, variant: .ORIGINAL) else { return nil }
        return Data(bytes)
    }
}

struct WrappedItemCiphertext {
    let encryptedContent: String
    let contentNonce: String
    let wrappedContentKey: String
    let wrappedContentKeyNonce: String
}

// MARK: - Sharing helpers (SDK-backed sealed boxes)

extension NoteCrypto {
    /// Recover the per-item content key. Routes through the SDK's
    /// `unwrap_with_vault` which is byte-identical to libsodium's
    /// crypto_secretbox_open_easy. Returns the raw 32-byte content
    /// key (Data → [UInt8] for callers that pass it through to
    /// existing libsodium-based helpers).
    static func contentKey(for item: Item, vaultKeyBase64: String) throws -> [UInt8] {
        guard let vaultKey = decodeBase64Data(vaultKeyBase64) else {
            throw CryptoError.invalidVaultKey
        }
        if let wrappedB64 = item.wrappedContentKey,
           let wrappedNonceB64 = item.wrappedContentKeyNonce {
            guard let opened = unwrapWithVault(
                wrappedKeyB64: wrappedB64,
                nonceB64: wrappedNonceB64,
                vaultKey: vaultKey
            ) else { throw CryptoError.unwrapContentKeyFailed }
            return Array(opened)
        }
        return Array(vaultKey)
    }

    /// base64 (libsodium `.ORIGINAL`, the variant `decodeBase64Data` reads) of a
    /// raw 32-byte symmetric key.
    static func encodeKeyBase64(_ key: [UInt8]) throws -> String {
        guard let b64 = sodium.utils.bin2base64(key, variant: .ORIGINAL) else {
            throw CryptoError.base64EncodeFailed
        }
        return b64
    }

    /// Unwrap a vault-wrapped content key (`wrap` + `nonce`) with
    /// `vaultKeyBase64`, to base64. Same unwrap as `contentKey(for:)` but over a
    /// given wrap rather than an item's own. Returns nil when the wrap doesn't
    /// open under that vault key: `SharesInboxStore.opensUnder` asks it whether
    /// any of this account's vault keys opens a row's wrap. Never throws, so one
    /// key that doesn't open can't break a check over several.
    static func unwrapRetiredContentKeyBase64(wrap: String, nonce: String, vaultKeyBase64: String) -> String? {
        guard let vaultKey = decodeBase64Data(vaultKeyBase64),
              let opened = unwrapWithVault(wrappedKeyB64: wrap, nonceB64: nonce, vaultKey: vaultKey)
        else { return nil }
        return try? encodeKeyBase64(Array(opened))
    }

    /// Open a sealed-box wrapped key with the recipient's own sharing
    /// private key. The SDK's `open_seal` derives the matching public
    /// key from the secret scalar internally via X25519 base-point
    /// multiplication, so the caller does NOT need to pass the
    /// public key (android uses the same one-arg form). The
    /// `sharingPublicKey` argument is kept on the API for source
    /// compatibility and is ignored.
    static func openSealedContentKey(
        wrappedB64: String,
        sharingPrivateKeyBase64: String,
        sharingPublicKey: String? = nil
    ) throws -> [UInt8] {
        guard let sk = decodeBase64Data(sharingPrivateKeyBase64),
              sk.count == 32
        else { throw CryptoError.invalidPrivateKey }
        guard let opened = openSeal(wrappedB64: wrappedB64, privateKey: sk) else {
            throw CryptoError.unsealFailed
        }
        return Array(opened)
    }

    /// Decrypt an item using a pre-supplied content key (instead of
    /// deriving from the vault key). Used by the receiver-side share
    /// flow where the content key comes from an unsealed wrapped_key.
    static func decryptItem(_ encryptedContent: String,
                            contentNonce: String,
                            contentKey: [UInt8],
                            itemId: String) throws -> Data {
        guard let plaintext = decryptNoteWithContentKeyV2(
            nonceB64: contentNonce,
            ciphertextB64: encryptedContent,
            contentKey: Data(contentKey),
            itemId: itemId
        ) else { throw CryptoError.decryptFailed }
        return Data(plaintext.utf8)
    }
}


/// A JSON fragment carried verbatim through a Codable round trip.
/// Whole-number values re-encode without a decimal point so android's
/// org.json reads them back as ints.
enum JSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n):
            if n == n.rounded(), abs(n) < 1e15 {
                try c.encode(Int64(n))
            } else {
                try c.encode(n)
            }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

/// Plaintext payload baked into encrypted_content. Format matches what
/// the web editor and the Android app produce: a JSON object with
/// title, body, and a few display flags.
///
/// Fields this client doesn't model — android's `color` and
/// `checklist_items`, anything a newer build invents — are captured in
/// `extras` on decode and written back verbatim on encode, so a save
/// from this device never strips the other platform's data.
struct DecodedNote: Codable {
    let title: String
    let body: String
    let noteType: String?
    let isPinned: Bool?
    let isArchived: Bool?
    let labels: [String]?
    let sortOrder: Int?
    let editMode: String?
    var extras: [String: JSONValue]

    init(title: String,
         body: String,
         noteType: String? = nil,
         isPinned: Bool? = nil,
         isArchived: Bool? = nil,
         labels: [String]? = nil,
         sortOrder: Int? = nil,
         editMode: String? = nil,
         extras: [String: JSONValue] = [:]) {
        self.title = title
        self.body = body
        self.noteType = noteType
        self.isPinned = isPinned
        self.isArchived = isArchived
        self.labels = labels
        self.sortOrder = sortOrder
        self.editMode = editMode
        self.extras = extras
    }

    private enum FieldKey: String, CaseIterable {
        case title
        case body
        case noteType = "note_type"
        case isPinned = "is_pinned"
        case isArchived = "is_archived"
        case labels
        case sortOrder = "sort_order"
        case editMode = "edit_mode"
    }

    private static let knownRawKeys = Set(FieldKey.allCases.map(\.rawValue))

    private struct AnyKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init(_ raw: String) { stringValue = raw }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        func key(_ f: FieldKey) -> AnyKey { AnyKey(f.rawValue) }
        title = try c.decode(String.self, forKey: key(.title))
        body = try c.decode(String.self, forKey: key(.body))
        noteType = try c.decodeIfPresent(String.self, forKey: key(.noteType))
        isPinned = try c.decodeIfPresent(Bool.self, forKey: key(.isPinned))
        isArchived = try c.decodeIfPresent(Bool.self, forKey: key(.isArchived))
        labels = try c.decodeIfPresent([String].self, forKey: key(.labels))
        sortOrder = try c.decodeIfPresent(Int.self, forKey: key(.sortOrder))
        editMode = try c.decodeIfPresent(String.self, forKey: key(.editMode))
        var captured: [String: JSONValue] = [:]
        for k in c.allKeys where !Self.knownRawKeys.contains(k.stringValue) {
            captured[k.stringValue] = try c.decode(JSONValue.self, forKey: k)
        }
        extras = captured
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        func key(_ f: FieldKey) -> AnyKey { AnyKey(f.rawValue) }
        try c.encode(title, forKey: key(.title))
        try c.encode(body, forKey: key(.body))
        try c.encodeIfPresent(noteType, forKey: key(.noteType))
        try c.encodeIfPresent(isPinned, forKey: key(.isPinned))
        try c.encodeIfPresent(isArchived, forKey: key(.isArchived))
        try c.encodeIfPresent(labels, forKey: key(.labels))
        try c.encodeIfPresent(sortOrder, forKey: key(.sortOrder))
        try c.encodeIfPresent(editMode, forKey: key(.editMode))
        for (raw, value) in extras where !Self.knownRawKeys.contains(raw) {
            try c.encode(value, forKey: AnyKey(raw))
        }
    }

    static func decode(from data: Data) throws -> DecodedNote {
        try JSONDecoder().decode(DecodedNote.self, from: data)
    }

    func encodeJSON() throws -> String {
        let data = try JSONEncoder().encode(self)
        return String(decoding: data, as: UTF8.self)
    }
}
