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

/// Wire-contract coverage for `POST /api/v1/auth/login/2fa`.
///
/// This endpoint is how an account with two-factor authentication signs in,
/// and getting it wrong is not a degraded experience — it is a permanent
/// lockout, because the only alternative to signing in is not signing in.
/// The route is `/auth/login/2fa` (the server registers no
/// `/auth/2fa/verify`), and the token goes in `two_factor_token` (the
/// server reads no `temp_token`). Either mistake alone is fatal.
///
/// Note is especially exposed if this breaks, because Note's Terms tell
/// people to turn two-factor on.
final class TwoFactorLoginWireTests: XCTestCase {

    private func snakeEncoder() -> JSONEncoder {
        let e = JSONEncoder(); e.keyEncodingStrategy = .convertToSnakeCase; return e
    }
    private func snakeDecoder() -> JSONDecoder {
        let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase; return d
    }

    func testRequestUsesTheFieldNamesTheServerReads() throws {
        let req = Verify2FARequest(twoFactorToken: "tok-123", code: "654321", method: "totp")
        let json = String(data: try snakeEncoder().encode(req), encoding: .utf8)!
        XCTAssertTrue(json.contains("\"two_factor_token\":\"tok-123\""),
                      "the server reads two_factor_token; temp_token is dropped: \(json)")
        XCTAssertTrue(json.contains("\"code\":\"654321\""), json)
        XCTAssertTrue(json.contains("\"method\":\"totp\""),
                      "method is required, not optional: \(json)")
        XCTAssertFalse(json.contains("temp_token"),
                       "temp_token is not a name the server reads: \(json)")
    }

    /// The reply is a full LoginResponse. Note depends on that: the vault key is
    /// derived from kdf_params + encrypted_keys, so a response type that dropped
    /// them would sign the user in and leave every note unreadable.
    func testResponseCarriesTheKeyMaterialNeededToDeriveTheVaultKey() throws {
        let json = """
        {"user":{"id":"u1","email":"a@b.c","display_name":"A"},
         "kdf_params":{"salt":"73","memory_kib":65536,"iterations":2,"parallelism":1},
         "encrypted_keys":{"master_key":{"nonce":"bb","ciphertext":"aa"},
                           "sharing_private_key":{"nonce":"dd","ciphertext":"cc"},
                           "sharing_public_key":"ee"},
         "sharing_public_key":"ee","signing_public_key":"ff",
         "access_token":"at","refresh_token":"rt"}
        """
        let resp = try snakeDecoder().decode(Login2FAResponse.self, from: Data(json.utf8))
        XCTAssertEqual(resp.accessToken, "at")
        XCTAssertEqual(resp.refreshToken, "rt")
        XCTAssertEqual(resp.user.id, "u1")
        XCTAssertNotNil(resp.kdfParams, "without kdf_params the vault key cannot be derived")
        XCTAssertNotNil(resp.encryptedKeys, "without encrypted_keys the vault key cannot be derived")
    }

    /// A server that omits the refresh token must not fail the decode — the user
    /// is mid-login and failing here would look exactly like a wrong code.
    func testResponseToleratesAMissingRefreshToken() throws {
        let json = """
        {"user":{"id":"u1","email":"a@b.c","display_name":"A"},
         "kdf_params":{"salt":"73","memory_kib":65536,"iterations":2,"parallelism":1},
         "encrypted_keys":{"master_key":{"nonce":"bb","ciphertext":"aa"},
                           "sharing_private_key":{"nonce":"dd","ciphertext":"cc"},
                           "sharing_public_key":"ee"},
         "sharing_public_key":"ee","signing_public_key":"ff",
         "access_token":"at"}
        """
        let resp = try snakeDecoder().decode(Login2FAResponse.self, from: Data(json.utf8))
        XCTAssertNil(resp.refreshToken)
        XCTAssertEqual(resp.accessToken, "at")
    }

    // MARK: - SRP step 2: the server's challenge

    /// The server's step-2 challenge in its real shape and key names
    /// (`available_methods` lists "totp" first, then "passkey").
    private func challengeBody(methods: String, preferred: String) -> Data {
        Data("""
        {"success":true,"data":{"server_proof":"AAAA","requires_2fa":true,
         "two_factor_token":"5d3c1f9e-0000-4000-8000-000000000000",
         "available_methods":\(methods),"preferred_method":\(preferred)}}
        """.utf8)
    }

    /// Through the app's OWN wire decoder and envelope handling.
    private func decodeStep2(_ body: Data) throws -> SRPStep2Response {
        try APIService.decodeSuccessBody(body, using: APIService.makeWireDecoder())
    }

    /// SRP step 2 must surface the challenge rather than looking like a
    /// failure. It is decoded from the server's own `requires_2fa` through
    /// the app's wire decoder: iOS 26's `.convertFromSnakeCase` does not
    /// produce `requires2fa` from it, so a hand-written `requires2fa` key
    /// through a look-alike decoder would pass while every 2FA sign-in on
    /// iOS 26 fails.
    func testStep2SurfacesTheChallengeWithAnExchangeToken() throws {
        let step2 = try decodeStep2(challengeBody(methods: #"["totp"]"#, preferred: "null"))
        XCTAssertEqual(step2.requires2fa, true, "requires_2fa must decode on this runtime")
        XCTAssertEqual(step2.twoFactorToken, "5d3c1f9e-0000-4000-8000-000000000000",
                       "without the exchange token there is nothing to complete the login with")
        XCTAssertNil(step2.accessToken, "the challenge branch issues no access token")
        XCTAssertTrue(AuthManager.isTwoFactorChallenge(step2))
        XCTAssertTrue(AuthManager.canAnswerTwoFactor(step2.availableMethods))
    }

    /// A passkey-only challenge is recognised as a challenge AND as one
    /// this app cannot answer, so the user gets the passkey message —
    /// not a code box, and not "no access token".
    func testAPasskeyOnlyChallengeGetsThePasskeyMessage() throws {
        let only = try decodeStep2(challengeBody(methods: #"["passkey"]"#, preferred: #""passkey""#))
        XCTAssertTrue(AuthManager.isTwoFactorChallenge(only))
        XCTAssertFalse(AuthManager.canAnswerTwoFactor(only.availableMethods))

        // preferred_method can be "passkey" on an account that ALSO has an
        // authenticator app; that account can sign in here.
        let both = try decodeStep2(challengeBody(methods: #"["totp","passkey"]"#, preferred: #""passkey""#))
        XCTAssertTrue(AuthManager.isTwoFactorChallenge(both))
        XCTAssertTrue(AuthManager.canAnswerTwoFactor(both.availableMethods))
    }

    /// Whatever a runtime makes of `requires_2fa`, it reads as the flag.
    func testTheFlagReadsUnderEveryConvertedSpelling() throws {
        for key in ["requires_2fa", "requires2fa", "requires2Fa"] {
            let step2 = try decodeStep2(Data(#"{"\#(key)":true,"two_factor_token":"t"}"#.utf8))
            XCTAssertEqual(step2.requires2fa, true, key)
        }
        let session = try decodeStep2(Data(#"{"server_proof":"AAAA","access_token":"at","refresh_token":"rt"}"#.utf8))
        XCTAssertNil(session.requires2fa)
        XCTAssertEqual(session.accessToken, "at")
        XCTAssertFalse(AuthManager.isTwoFactorChallenge(session), "a session reply is not a challenge")
    }

    /// An exchange token with no access token is a challenge even without the
    /// flag, so a challenge can never fall through to "no access token".
    func testAnExchangeTokenWithoutAnAccessTokenIsAChallenge() throws {
        let step2 = try decodeStep2(Data(#"{"server_proof":"AAAA","two_factor_token":"t","available_methods":["passkey"]}"#.utf8))
        XCTAssertNil(step2.requires2fa)
        XCTAssertTrue(AuthManager.isTwoFactorChallenge(step2))
    }

    // MARK: - The sign-in keys come from the reply, never from /auth/me

    /// The auth server's SRP step-2 success reply (server_proof + a flattened
    /// login response): the sealed blobs in `encrypted_keys`, the
    /// public keys at the TOP level.
    private let step2Success = Data("""
    {"success":true,"data":{"server_proof":"AAAA",
     "user":{"id":"4f0c0000-0000-4000-8000-000000000001","email":"a@b.c","status":"active"},
     "kdf_params":{"salt":"c2FsdA==","memory_kib":65536,"iterations":3,"parallelism":1},
     "encrypted_keys":{"master_key":{"nonce":"bQ==","ciphertext":"Yw==","key_id":"v1"},
                       "sharing_private_key":{"nonce":"bg==","ciphertext":"ZA==","key_id":"v1"},
                       "signing_private_key":{"nonce":"bw==","ciphertext":"ZQ==","key_id":"v1"}},
     "sharing_public_key":"U0hBUklOR1BVQg==","signing_public_key":"U0lHTklOR1BVQg==",
     "access_token":"at","refresh_token":"rt"}}
    """.utf8)

    func testStep2CarriesThePublicKeysAtTheTopLevel() throws {
        let step2 = try decodeStep2(step2Success)
        XCTAssertNil(step2.encryptedKeys?.sharingPublicKey, "encrypted_keys holds only the sealed blobs")
        XCTAssertEqual(step2.sharingPublicKey, "U0hBUklOR1BVQg==")
        XCTAssertEqual(step2.signingPublicKey, "U0lHTklOR1BVQg==")

        let keys = try XCTUnwrap(AuthManager.signInKeys(serverKeys: step2.encryptedKeys,
                                                        sharingPublicKey: step2.sharingPublicKey,
                                                        signingPublicKey: step2.signingPublicKey))
        XCTAssertEqual(keys.sharingPublicKey, "U0hBUklOR1BVQg==")
        XCTAssertEqual(keys.signingPublicKey, "U0lHTklOR1BVQg==")
        XCTAssertNotNil(keys.sharingPrivateKey)
        XCTAssertNotNil(keys.signingPrivateKey)
        XCTAssertNil(AuthManager.signInKeys(serverKeys: nil, sharingPublicKey: "x", signingPublicKey: "y"),
                     "no sealed blobs in the reply: no keys, and nothing else is asked")
    }

    func testTheTwoFactorReplyCarriesThePublicKeysToo() throws {
        let body = Data("""
        {"success":true,"data":{
         "user":{"id":"4f0c0000-0000-4000-8000-000000000001","email":"a@b.c","status":"active"},
         "kdf_params":{"salt":"c2FsdA==","memory_kib":65536,"iterations":3,"parallelism":1},
         "encrypted_keys":{"master_key":{"nonce":"bQ==","ciphertext":"Yw==","key_id":"v1"},
                           "sharing_private_key":{"nonce":"bg==","ciphertext":"ZA==","key_id":"v1"},
                           "signing_private_key":{"nonce":"bw==","ciphertext":"ZQ==","key_id":"v1"}},
         "sharing_public_key":"U0hBUklOR1BVQg==","signing_public_key":"U0lHTklOR1BVQg==",
         "access_token":"at","refresh_token":"rt"}}
        """.utf8)
        let reply: Login2FAResponse = try APIService.decodeSuccessBody(body, using: APIService.makeWireDecoder())
        XCTAssertEqual(reply.sharingPublicKey, "U0hBUklOR1BVQg==")
        XCTAssertEqual(reply.signingPublicKey, "U0lHTklOR1BVQg==")
    }

    /// Our own public key is derived from the private key that opened,
    /// never taken from the reply. RFC 7748 §6.1's X25519 vector
    /// (Alice).
    func testTheSharingPublicKeyIsDerivedFromThePrivateKey() throws {
        let sodium = Sodium()
        let priv = try XCTUnwrap(sodium.utils.hex2bin("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a"))
        let pub = try XCTUnwrap(sodium.utils.hex2bin("8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a"))
        let derived = try XCTUnwrap(sodium.utils.bin2base64(pub, variant: .ORIGINAL))
        XCTAssertEqual(AuthManager.publicKeyB64(forSharingPrivateKey: priv), derived)

        // The served copy is only compared: a different one is not kept.
        let other = try XCTUnwrap(AuthManager.sharingPublicKeyToKeep(openedPrivateKey: priv, served: "U0hBUklOR1BVQg=="))
        XCTAssertEqual(other.key, derived)
        XCTAssertTrue(other.servedDisagrees)
        let same = try XCTUnwrap(AuthManager.sharingPublicKeyToKeep(openedPrivateKey: priv, served: derived))
        XCTAssertEqual(same.key, derived)
        XCTAssertFalse(same.servedDisagrees)
        let none = try XCTUnwrap(AuthManager.sharingPublicKeyToKeep(openedPrivateKey: priv, served: nil))
        XCTAssertEqual(none.key, derived)
        XCTAssertFalse(none.servedDisagrees)
    }

    /// A /me reply can carry a copy of the keys, but this app does
    /// not decode them, so no sign-in path can fall back to them.
    func testTheMeReplyIsNotAKeySource() throws {
        let me: MeResponse = try APIService.decodeSuccessBody(Data("""
        {"success":true,"data":{"id":"4f0c0000-0000-4000-8000-000000000001","email":"a@b.c",
         "display_name":"A","recovery_email_verified":false,
         "encrypted_keys":{"master_key":{"nonce":"bQ==","ciphertext":"Yw=="},
                           "sharing_private_key":{"nonce":"bg==","ciphertext":"ZA=="},
                           "sharing_public_key":"U0hBUklOR1BVQg=="},
         "kdf_params":{"salt":"c2FsdA==","memory_kib":65536,"iterations":3,"parallelism":1}}}
        """.utf8), using: APIService.makeWireDecoder())
        XCTAssertEqual(me.displayName, "A")
        let fields = Mirror(reflecting: me).children.compactMap(\.label)
        XCTAssertFalse(fields.contains("encryptedKeys"), "\(fields)")
        XCTAssertFalse(fields.contains("kdfParams"), "\(fields)")
    }
}
