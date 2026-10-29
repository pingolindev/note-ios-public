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
@testable import Note

/// `PATCH /api/v1/auth/me` — the display-name change.
///
/// WHY THIS FILE EXISTS
///   The route replies with `UpdateDisplayNameResponse { display_name }`
///   and nothing else. Decoded as a `MeResponse`, which requires `id` and
///   `email`, that reply throws `keyNotFound(id)` after the server has
///   stored the new name: the user would see an error, the change would
///   be real, and the two would disagree until the next launch.
///
///   Making `MeResponse.id` and `.email` optional so the decode stops
///   throwing would remove the guarantee that a GET /auth/me identifies
///   the account it describes, which `checkExistingSession` leans on to
///   fail closed when the token authenticates as a different user. So
///   `updateMe` decodes the route's own response type.
final class DisplayNameUpdateTests: XCTestCase {

    private func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        // The strategy APIService uses; it is what maps `display_name`.
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    /// The real reply, as the server sends it.
    private let realResponse = #"{"display_name":"Test-Renamed"}"#

    func testResponseDecodes() throws {
        let response = try decoder().decode(
            UpdateDisplayNameResponse.self, from: Data(realResponse.utf8))
        XCTAssertEqual(response.displayName, "Test-Renamed")
    }

    /// Clearing a display name PATCHes null and gets null back.
    func testNullDisplayNameDecodes() throws {
        let response = try decoder().decode(
            UpdateDisplayNameResponse.self, from: Data(#"{"display_name":null}"#.utf8))
        XCTAssertNil(response.displayName)
    }

    /// NEGATIVE CONTROL — `MeResponse` cannot decode this route's reply,
    /// which is precisely why it is not `updateMe`'s return type. If
    /// anyone points `updateMe` at `MeResponse`, this states what happens.
    func testMeResponseCannotDecodeThisReply() {
        XCTAssertThrowsError(
            try decoder().decode(MeResponse.self, from: Data(realResponse.utf8)),
            "MeResponse requires id/email, neither of which this route returns"
        ) { error in
            guard case DecodingError.keyNotFound(let key, _) = error else {
                return XCTFail("Expected keyNotFound, got \(error)")
            }
            XCTAssertEqual(key.stringValue, "id")
        }
    }

    /// POSITIVE CONTROL for the above: `MeResponse` is still the right type for
    /// what GET /auth/me actually sends, identity fields and all. The negative
    /// control must be about the ROUTE's shape, not about MeResponse being
    /// broken.
    func testMeResponseStillDecodesTheGetReply() throws {
        let me = try decoder().decode(MeResponse.self, from: Data(#"""
        {"id":"11111111-1111-1111-1111-111111111111",
         "email":"user@example.com",
         "display_name":"User",
         "recovery_email_verified":false}
        """#.utf8))
        XCTAssertEqual(me.id, "11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(me.displayName, "User")
    }

    /// The request body auth expects: `{"display_name": "..."}`.
    func testRequestEncodesSnakeCase() throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let json = String(
            data: try encoder.encode(UpdateMeRequest(displayName: "Ada")), encoding: .utf8)
        XCTAssertEqual(json, #"{"display_name":"Ada"}"#)
    }
}
