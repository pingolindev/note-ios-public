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
import Sodium
@testable import Note

/// Sign-in never migrates a signing key: it classifies the key it opened,
/// logs and counts a legacy shape, and never replaces or creates a key —
/// whatever the server says. The server's `signing_public_key` is not
/// trusted; a disagreement with it is only logged.
final class SigningKeyMigrationTests: XCTestCase {

    private let sodium = Sodium()
    private let sharing: Bytes = (1...32).map { UInt8($0) }
    private let genuineSeed: Bytes = (100..<132).map { UInt8($0) }

    private func verifyingHex(_ seed: Bytes) -> String {
        sodium.sign.keyPair(seed: seed)!.publicKey.map { String(format: "%02x", $0) }.joined()
    }

    private func verdict(_ seed: Bytes?, server: String) -> AuthManager.SigningKeyVerdict {
        AuthManager.signingKeyVerdict(signingSeed: seed, sharingPrivateKey: sharing, serverVerifyingKeyHex: server)
    }

    private func isolatedDefaults() throws -> UserDefaults {
        try XCTUnwrap(UserDefaults(suiteName: "SigningKeyMigrationTests-\(UUID().uuidString)"))
    }

    func testALegacyShapedKeyNeverRotates() throws {
        let defaults = try isolatedDefaults()
        for server in [verifyingHex(sharing), "", verifyingHex(genuineSeed)] {
            let v = verdict(sharing, server: server)
            XCTAssertEqual(v, .legacy, "the seed IS the sharing key")
            XCTAssertEqual(AuthManager.recordSigningKeyVerdict(v, defaults: defaults), .logAndCountLegacy)
        }
        XCTAssertEqual(defaults.integer(forKey: legacySigningKeyCountKey), 3, "each sighting is counted")
    }

    func testTheServersDisagreementNeverRotates() throws {
        let defaults = try isolatedDefaults()
        let other = verifyingHex((200..<232).map { UInt8($0) })
        for server in [other, "", "not-a-key"] {
            let v = verdict(genuineSeed, server: server)
            XCTAssertEqual(v, .serverDisagrees, server)
            XCTAssertEqual(AuthManager.recordSigningKeyVerdict(v, defaults: defaults), .logServerDisagreement)
        }
        let agreeing = verdict(genuineSeed, server: verifyingHex(genuineSeed).uppercased())
        XCTAssertEqual(agreeing, .matches)
        XCTAssertEqual(AuthManager.recordSigningKeyVerdict(agreeing, defaults: defaults), .nothing)
        XCTAssertEqual(defaults.integer(forKey: legacySigningKeyCountKey), 0, "only the legacy shape is counted")
    }

    func testAMissingBlobNeverMints() throws {
        let defaults = try isolatedDefaults()
        for server in [verifyingHex(genuineSeed), ""] {
            let v = verdict(nil, server: server)
            XCTAssertEqual(v, .noSigningKey)
            XCTAssertEqual(AuthManager.recordSigningKeyVerdict(v, defaults: defaults), .nothing)
        }
        XCTAssertEqual(defaults.integer(forKey: legacySigningKeyCountKey), 0)
    }

    func testTheSharingKeyIsComparedByBytes() {
        XCTAssertTrue(AuthManager.constantTimeEquals(sharing, Bytes(sharing)))
        XCTAssertFalse(AuthManager.constantTimeEquals(sharing, genuineSeed))
        XCTAssertFalse(AuthManager.constantTimeEquals(sharing, Bytes(sharing.prefix(31))))
        // No sharing key opened: nothing can be called legacy.
        XCTAssertEqual(AuthManager.signingKeyVerdict(signingSeed: sharing, sharingPrivateKey: nil,
                                                     serverVerifyingKeyHex: ""), .serverDisagrees)
    }
}
