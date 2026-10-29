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

import XCTest
import Security
import PingolinNoteSDK
@testable import Note

/// The SDK's key store callback: `nil` means nothing at all is stored, and
/// only that. A Keychain read that fails throws the SDK's
/// `StorageCallbackError.Failed`, so the SDK keeps every write off a store
/// it couldn't read. A store that is only partly there is handed over with
/// "" for a missing part, for the SDK to find it doesn't decode.
final class KeyStoreCallbackTests: XCTestCase {

    private let locked = errSecInteractionNotAllowed

    // MARK: - One entry

    func testAnEntryIsItsValueOrNilWhenNotStored() throws {
        XCTAssertEqual(try KeychainKeyStorageCallback.value(status: errSecSuccess, data: Data("abc".utf8)), "abc")
        XCTAssertNil(try KeychainKeyStorageCallback.value(status: errSecItemNotFound, data: nil))
    }

    func testAReadThatFailsThrowsTheSDKsError() {
        for status in [locked, errSecAuthFailed, errSecDecode, errSecNotAvailable] {
            XCTAssertThrowsError(try KeychainKeyStorageCallback.value(status: status, data: nil), "status \(status)") {
                XCTAssertEqual($0 as? StorageCallbackError, .Failed, "status \(status)")
            }
        }
        // Success with nothing returned is not "not stored" either.
        XCTAssertThrowsError(try KeychainKeyStorageCallback.value(status: errSecSuccess, data: nil)) {
            XCTAssertEqual($0 as? StorageCallbackError, .Failed)
        }
    }

    func testBytesThatAreNotUTF8ArePassedThrough() throws {
        // For the SDK to find they don't decode (a sign-in recovers that); a
        // throw would read as the platform failing, which nothing clears.
        let value = try KeychainKeyStorageCallback.value(status: errSecSuccess, data: Data([0xFF, 0xFE, 0x41]))
        XCTAssertNotNil(value)
        XCTAssertTrue(value?.hasSuffix("A") ?? false)
    }

    // MARK: - The four entries

    func testNilOnlyWhenNothingAtAllIsStored() {
        XCTAssertNil(KeychainKeyStorageCallback.stored(
            privateKey: nil, circleKeysJson: nil, pinnedKeysJson: nil, signingPrivateKeyB64: nil))
    }

    func testAPartlyWrittenStoreGivesWhatItHasWithEmptyRequiredParts() {
        let onlyKey = KeychainKeyStorageCallback.stored(
            privateKey: "K", circleKeysJson: nil, pinnedKeysJson: nil, signingPrivateKeyB64: nil)
        XCTAssertEqual(onlyKey?.privateKey, "K")
        XCTAssertEqual(onlyKey?.circleKeysJson, "", "never \"{}\": that would claim an empty set")
        XCTAssertNil(onlyKey?.pinnedKeysJson)
        XCTAssertNil(onlyKey?.signingPrivateKeyB64)

        let noKey = KeychainKeyStorageCallback.stored(
            privateKey: nil, circleKeysJson: "{}", pinnedKeysJson: nil, signingPrivateKeyB64: "S")
        XCTAssertEqual(noKey?.privateKey, "")
        XCTAssertEqual(noKey?.circleKeysJson, "{}")
        XCTAssertEqual(noKey?.signingPrivateKeyB64, "S")

        let onlySeed = KeychainKeyStorageCallback.stored(
            privateKey: nil, circleKeysJson: nil, pinnedKeysJson: nil, signingPrivateKeyB64: "S")
        XCTAssertNotNil(onlySeed, "a seed alone is still something stored")

        let whole = KeychainKeyStorageCallback.stored(
            privateKey: "K", circleKeysJson: "{}", pinnedKeysJson: "{}", signingPrivateKeyB64: "S")
        XCTAssertEqual(whole?.privateKey, "K")
        XCTAssertEqual(whole?.circleKeysJson, "{}")
        XCTAssertEqual(whole?.pinnedKeysJson, "{}")
        XCTAssertEqual(whole?.signingPrivateKeyB64, "S")
    }

    /// A Keychain answering per entry, as `SecItemCopyMatching` does.
    private func callback(_ answers: [String: (OSStatus, String?)]) -> KeychainKeyStorageCallback {
        KeychainKeyStorageCallback(copyMatching: { query, result in
            let account = (query as NSDictionary)[kSecAttrAccount as String] as? String ?? ""
            let (status, value) = answers[account] ?? (errSecItemNotFound, nil)
            if status == errSecSuccess, let value {
                result?.pointee = Data(value.utf8) as CFData
            }
            return status
        })
    }

    func testLoadingANewInstallGivesNil() throws {
        XCTAssertNil(try callback([:]).loadKeys())
    }

    func testLoadingAWholeStore() throws {
        let loaded = try callback([
            "private_key": (errSecSuccess, "K"),
            "circle_keys_json": (errSecSuccess, "{}"),
            "pinned_keys_json": (errSecSuccess, "{\"p\":1}"),
            "signing_private_key_b64": (errSecSuccess, "S"),
        ]).loadKeys()
        XCTAssertEqual(loaded?.privateKey, "K")
        XCTAssertEqual(loaded?.circleKeysJson, "{}")
        XCTAssertEqual(loaded?.pinnedKeysJson, "{\"p\":1}")
        XCTAssertEqual(loaded?.signingPrivateKeyB64, "S")
    }

    func testLoadingAStoreWithTheMapMissing() throws {
        let loaded = try callback(["private_key": (errSecSuccess, "K")]).loadKeys()
        XCTAssertEqual(loaded?.privateKey, "K")
        XCTAssertEqual(loaded?.circleKeysJson, "")
    }

    func testAnyEntryThatCantBeReadFailsTheWholeLoad() {
        for account in ["private_key", "circle_keys_json", "pinned_keys_json", "signing_private_key_b64"] {
            var answers: [String: (OSStatus, String?)] = [
                "private_key": (errSecSuccess, "K"),
                "circle_keys_json": (errSecSuccess, "{}"),
            ]
            answers[account] = (locked, nil)
            XCTAssertThrowsError(try callback(answers).loadKeys(), account) {
                XCTAssertEqual($0 as? StorageCallbackError, .Failed, account)
            }
        }
    }

    /// The SDK's contract: callbacks throw its StorageCallbackError, never a
    /// MobileError (that one panics in the SDK's lift) or an error of their own.
    func testTheCallbackThrowsOnlyTheSDKsError() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("App/Services/KeychainKeyStorageCallback.swift"), encoding: .utf8)
        let throwsLines = source.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("throw ") || $0.contains(" throw ") }
            .filter { !$0.hasPrefix("///") && !$0.hasPrefix("//") }
        XCTAssertFalse(throwsLines.isEmpty)
        for line in throwsLines {
            XCTAssertTrue(line.contains("StorageCallbackError.Failed") || line.contains("failed("),
                          "throws something else: \(line)")
        }
        XCTAssertFalse(source.contains("MobileError"))
        XCTAssertEqual(source.components(separatedBy: "-> StorageCallbackError").count, 2,
                       "one helper makes every error")
    }
}
