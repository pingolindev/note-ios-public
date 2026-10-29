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
import PingolinNoteSDK
import Sodium
@testable import Note

/// A sign-in PROVES, then WIPES, then SAVES.
/// - This account's keys open in memory first (openSignInKeys), and nothing is
///   stored or imported there.
/// - The gate (signInStep): a switch or a first sign-in needs them opened;
///   only the same account goes on with the keys it holds when a re-derive
///   fails.
/// - Only then the switch cleanup, then `.userId` and the stores are bound,
///   then the keys are stored: a store that stops part-way leaves this account
///   with no keys, never its keys under the previous account's id. The opened
///   keys are zeroed on every path.
/// - A failed sign-in keeps every key slot: nothing of the incoming account's
///   was stored, and what a 401 kept is not its to delete.
@MainActor
final class SignInOrderTests: XCTestCase {

    private let me = "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"
    private let other = "2a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"

    // MARK: - the gate

    func testTheGateLetsOnlyTheSameAccountGoOnWithoutOpenedKeys() {
        typealias Step = AuthManager.SignInStep
        func step(opened: Bool, prior: String?, holdsKeys: Bool = true, rows: Bool = false) -> Step {
            AuthManager.signInStep(opened: opened, prior: prior, incoming: me, holdsKeys: holdsKeys, cacheHasRows: rows)
        }
        // Opened: this device's account saves; another's, one that isn't a
        // UUID, or rows nobody's id names, go first.
        XCTAssertEqual(step(opened: true, prior: nil), .save)
        XCTAssertEqual(step(opened: true, prior: me.uppercased()), .save)
        XCTAssertEqual(step(opened: true, prior: nil, rows: true), .switchThenSave)
        XCTAssertEqual(step(opened: true, prior: other), .switchThenSave)
        XCTAssertEqual(step(opened: true, prior: "u1"), .switchThenSave)
        // Not opened: only the same account, holding its keys, goes on.
        XCTAssertEqual(step(opened: false, prior: me), .save)
        XCTAssertEqual(step(opened: false, prior: "{\(me)}"), .save)
        XCTAssertEqual(step(opened: false, prior: me, holdsKeys: false), .refuse)
        XCTAssertEqual(step(opened: false, prior: other), .refuse)
        XCTAssertEqual(step(opened: false, prior: "u1"), .refuse)
        XCTAssertEqual(step(opened: false, prior: nil), .refuse)
        XCTAssertEqual(step(opened: false, prior: nil, rows: true), .refuse)
    }

    // MARK: - the open, in memory (real crypto)

    private let sodium = Sodium()

    private func blob(_ message: Bytes, key: Bytes) throws -> EncryptedBlobResponse {
        let sealed: (authenticatedCipherText: Bytes, nonce: Bytes) = try XCTUnwrap(sodium.secretBox.seal(message: message, secretKey: key))
        return EncryptedBlobResponse(
            nonce: try XCTUnwrap(sodium.utils.bin2base64(sealed.nonce, variant: .ORIGINAL)),
            ciphertext: try XCTUnwrap(sodium.utils.bin2base64(sealed.authenticatedCipherText, variant: .ORIGINAL))
        )
    }

    /// An account's key blobs under `password`, with the cheapest Argon2id
    /// libsodium allows.
    private func account(password: String, withSharing: Bool = true, sharingLength: Int = 32) throws -> (keys: EncryptedKeysResponse, kdf: KdfParamsResponse, sharing: Bytes, seed: Bytes) {
        let salt = try XCTUnwrap(sodium.randomBytes.buf(length: 16))
        let derived = try XCTUnwrap(sodium.pwHash.hash(outputLength: 32, passwd: Array(password.utf8), salt: salt,
                                                       opsLimit: 1, memLimit: 8192, alg: .Argon2ID13))
        let master = try XCTUnwrap(sodium.randomBytes.buf(length: 32))
        let sharing = try XCTUnwrap(sodium.randomBytes.buf(length: sharingLength))
        let seed = try XCTUnwrap(sodium.randomBytes.buf(length: 32))
        let keys = EncryptedKeysResponse(
            masterKey: try blob(master, key: derived),
            sharingPrivateKey: withSharing ? try blob(sharing, key: master) : nil,
            // The SDK's decryptWithKey hands back the plaintext's base64: the blob holds the raw seed.
            signingPrivateKey: try blob(seed, key: master),
            sharingPublicKey: nil, signingPublicKey: nil
        )
        let kdf = KdfParamsResponse(salt: try XCTUnwrap(sodium.utils.bin2base64(salt, variant: .ORIGINAL)),
                                    memoryKib: 8, iterations: 1, parallelism: 1)
        return (keys, kdf, sharing, seed)
    }

    func testThePasswordOpensTheKeysInMemoryAndTheWipeZeroesThem() async throws {
        let a = try account(password: "right")
        let opened = try await AuthManager.openSignInKeys(password: "right", keys: a.keys, kdf: a.kdf)
        XCTAssertEqual(opened.sharingPrivateKey, a.sharing)
        XCTAssertEqual(opened.signingSeed, a.seed)
        XCTAssertEqual(opened.vaultKey, sodium.genericHash.hash(message: a.sharing, key: Array("pingolin-note-vault".utf8), outputLength: 32))
        opened.wipe()
        for bytes in [opened.masterKey, opened.sharingPrivateKey, opened.vaultKey, opened.signingSeed ?? [1]] {
            XCTAssertTrue(bytes.allSatisfy { $0 == 0 })
        }
    }

    func testAWrongPasswordOrNo32ByteSharingKeyOpensNothing() async throws {
        let a = try account(password: "right")
        do {
            _ = try await AuthManager.openSignInKeys(password: "wrong", keys: a.keys, kdf: a.kdf)
            XCTFail("a wrong password opened the keys")
        } catch {
            XCTAssertEqual(error as? AuthManager.VaultDerivationError, .masterKeyOpen)
        }
        for b in [try account(password: "right", withSharing: false), try account(password: "right", sharingLength: 16)] {
            do {
                _ = try await AuthManager.openSignInKeys(password: "right", keys: b.keys, kdf: b.kdf)
                XCTFail("no 32-byte sharing key, yet keys opened")
            } catch {
                XCTAssertEqual(error as? AuthManager.VaultDerivationError, .sharingKeyOpen)
            }
        }
    }

    // MARK: - the order (the source)

    private func source() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("App/Managers/AuthManager.swift"), encoding: .utf8)
    }

    private func body(_ text: String, from start: String, to end: String) throws -> String {
        let s = try XCTUnwrap(text.range(of: start), start)
        let e = try XCTUnwrap(text.range(of: end, range: s.upperBound..<text.endIndex), end)
        return String(text[s.upperBound..<e.lowerBound])
    }

    func testTheSignInOpensGatesWipesBindsThenStoresAndAlwaysZeroesWhatItOpened() throws {
        let finish = try body(try source(), from: "private func finishLogin(", to: "func verify2FA(code: String)")
        func at(_ needle: String) throws -> String.Index { try XCTUnwrap(finish.range(of: needle), needle).lowerBound }
        let id = try at("guard let id = Self.signInAccount(userId) else { throw AuthError.noAccessToken }")
        let open = try at("opened = try await Self.openSignInKeys(password: password, keys: keys, kdf: kdf)")
        let zero = try at("defer { opened?.wipe() }")
        let gate = try at("if step == .refuse {\n            failPartialLogin()\n            throw AuthError.vaultKeyUnavailable\n        }")
        let cleanup = try at("if step == .switchThenSave {\n            await switchAccountCleanup()\n")
        // The switch also empties the page's data an expiry kept, awaited, before the bind.
        let pageWipe = try at("            await WebShellDataStore.wipeAsync()\n        }")
        let store = try at("stored = try storeSignInKeys(opened)")
        let bind = try at("try keychain.save(id, for: .userId)")
        let stores = try at("SenderKeyPinStore.shared.switchUser(id)")
        let check = try at("guard holdsSessionKeys() else {")
        XCTAssertTrue(id < open && open < zero && zero < gate && gate < cleanup && cleanup < pageWipe && pageWipe < bind
                      && bind < stores && stores < store && store < check)
        // Nothing before the gate stores a key, binds an account or wipes.
        let beforeGate = String(finish[..<gate])
        for write in [", for: .vaultKey)", ", for: .masterKey)", ", for: .sharingPrivateKey)", ", for: .signingPrivateKey)",
                      "save(id, for: .userId)", "await switchAccountCleanup()", "switchUser(", "importPrivateKey", "importSigningPrivateKey",
                      "WebShellDataStore.wipeAsync()"] {
            XCTAssertFalse(beforeGate.contains(write), write)
        }
        XCTAssertEqual(finish.components(separatedBy: "await switchAccountCleanup()").count - 1, 1)
        // A store that throws part-way is caught; the guard after it decides.
        XCTAssertTrue(finish.contains("do {\n                stored = try storeSignInKeys(opened)\n            } catch {\n                Self.keysLog.error(\"This sign-in's keys weren't stored:"))
    }

    /// A failed sign-in drops the tokens only: every key slot stays.
    func testAFailedSignInKeepsEveryKeySlot() throws {
        let fail = try body(try source(), from: "private func failPartialLogin() {", to: "\n    }\n")
        XCTAssertTrue(fail.contains("keychain.delete(key: .accessToken)"))
        XCTAssertTrue(fail.contains("keychain.delete(key: .refreshToken)"))
        for slot in [".vaultKey", ".masterKey", ".sharingPrivateKey", ".signingPrivateKey", ".userId", ".localDbKey"] {
            XCTAssertFalse(fail.contains("keychain.delete(key: \(slot))"), slot)
        }
        XCTAssertFalse(fail.contains("deleteAll"))
    }
}
