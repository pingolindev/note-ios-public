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
@testable import Note

/// `GET /api/v1/auth/previous-identities` read through the app's own wire
/// decoder, with the body as the server serializes it (inside the
/// `{success, data}` envelope; an absent blob is left out, not null). The
/// type must not name its keys in snake_case, which
/// `.convertFromSnakeCase` never matches: the empty list would decode,
/// every other answer would throw, and no earlier identity would ever
/// load.
final class PreviousIdentityWireTests: XCTestCase {
    /// Restored before app sealing existed (no blob), v1 only, v1 and v2.
    private let body = Data(#"""
    {"success":true,"data":{"identities":[
      {"key_version":1,"adopted_at":"2026-08-20T10:00:00+00:00",
       "sharing_public_key":"c2hhcmluZzE=","signing_public_key":"c2lnbmluZzE=",
       "encrypted_sharing_private_key":{"nonce":"bnMx","ciphertext":"Y3Mx"},
       "encrypted_signing_private_key":{"nonce":"bmcx","ciphertext":"Y2cx"}},
      {"key_version":2,"adopted_at":"2026-09-01T10:00:00+00:00",
       "sharing_public_key":"c2hhcmluZzI=","signing_public_key":"c2lnbmluZzI=",
       "encrypted_sharing_private_key":{"nonce":"bnMy","ciphertext":"Y3My"},
       "encrypted_signing_private_key":{"nonce":"bmcy","ciphertext":"Y2cy"},
       "app_sealed_private_key":{"nonce":"bjI=","ciphertext":"YzI="}},
      {"key_version":3,"adopted_at":"2026-09-25T04:18:50.99+00:00",
       "sharing_public_key":"c2hhcmluZzM=","signing_public_key":"c2lnbmluZzM=",
       "encrypted_sharing_private_key":{"nonce":"bnMz","ciphertext":"Y3Mz"},
       "encrypted_signing_private_key":{"nonce":"bmcz","ciphertext":"Y2cz"},
       "app_sealed_private_key":{"nonce":"bjM=","ciphertext":"YzM="},
       "app_sealed_private_key_v2":{"nonce":"djI=","ciphertext":"djJj"}}
    ]}}
    """#.utf8)

    private func decode(_ data: Data) throws -> [PreviousIdentityResponse] {
        let reply: PreviousIdentitiesResponse = try APIService.decodeSuccessBody(data, using: APIService.makeWireDecoder())
        return reply.identities
    }

    func testTheServersAnswerDecodes() throws {
        let rows = try decode(body)
        XCTAssertEqual(rows.map(\.keyVersion), [1, 2, 3])
        XCTAssertNil(rows[0].appSealedPrivateKey)
        XCTAssertEqual(rows[1].appSealedPrivateKey?.nonce, "bjI=")
        XCTAssertEqual(rows[1].appSealedPrivateKey?.ciphertext, "YzI=")
        XCTAssertNil(rows[1].appSealedPrivateKeyV2)
        XCTAssertEqual(rows[2].appSealedPrivateKey?.nonce, "bjM=")
        XCTAssertEqual(rows[2].appSealedPrivateKeyV2?.ciphertext, "djJj")
    }

    func testAnEmptyAnswerStillDecodes() throws {
        XCTAssertTrue(try decode(Data(#"{"success":true,"data":{"identities":[]}}"#.utf8)).isEmpty)
    }

    /// The whole path the running app takes: every v1 blob of the answer
    /// reaches the SDK's import.
    func testTheLoaderImportsEveryV1BlobOfTheAnswer() async {
        var imported: [[String]] = []
        let importer = PreviousIdentityLoader.Importer(
            importSealed: { imported.append($0.map(\.nonce)); return $0.count },
            vaultKeys: { [] }
        )
        let body = self.body
        let loader = PreviousIdentityLoader(fetch: { try self.decode(body) }, importer: importer)
        await loader.ensureLoaded()
        XCTAssertEqual(imported, [["bjI=", "bjM="]])
        XCTAssertTrue(loader.isLoaded)
    }
}
