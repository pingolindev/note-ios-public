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
import WebKit
import Sodium
import PingolinNoteSDK
@testable import Note

/// The web shell and the sign-in path.
///
/// The page is fetched live, so it gets no private key — only the vault
/// key, the public keys and a marker — and asks `WebKeyBridge` for the
/// three operations that need a private key. The page stays on the default
/// WebKit store, whose files all sit under backup-excluded directories and
/// which is never cleared on update (it holds unsynced edits), and the
/// page's cookie is a short-lived HttpOnly access token, never the 30-day
/// refresh token. On the sign-in path, only a challenge that offers TOTP
/// gets the code entry.
final class WebShellKeyBridgeTests: XCTestCase {

    private let origin = "https://note.pingolindev.com"
    private let sodium = Sodium()

    // MARK: - What the page is handed

    func testTheHandoffCarriesNoPrivateKeyAndRemovesTheOldOnes() throws {
        let keys = WebAppKeyHandoff.Keys(vaultKeyB64: "VkFVTFQ=", sharingPubB64: "UFVC", signPublicB64: "U0lHTlBVQg==")
        let script = try XCTUnwrap(WebAppKeyHandoff.buildScript(keys: keys, origin: origin))
        XCTAssertTrue(script.hasPrefix("(function(){if(location.origin!=='\(origin)')return;"),
                      "the origin guard must run before anything else")
        XCTAssertTrue(script.contains("s.removeItem('pingolin_note_client_key')"))
        XCTAssertTrue(script.contains("window.localStorage.removeItem('pingolin_note_client_key')"))
        XCTAssertTrue(script.contains("s.setItem('pingolin_note_session_key','VkFVTFQ=')"))
        XCTAssertTrue(script.contains("s.setItem('pingolin_note_sharing_pub','UFVC')"))
        XCTAssertTrue(script.contains("s.setItem('pingolin_note_sign_public','U0lHTlBVQg==')"))
        XCTAssertFalse(script.contains("setItem('pingolin_note_sharing_priv'"))
        XCTAssertFalse(script.contains("setItem('pingolin_note_sign_secret'"))
        XCTAssertTrue(script.contains("s.removeItem('pingolin_note_sharing_priv')"))
        XCTAssertTrue(script.contains("s.removeItem('pingolin_note_sign_secret')"))
        XCTAssertTrue(script.contains("window.__pingolinKeyBridge=Object.freeze({version:1,signing:true})"))
    }

    func testWithoutASigningKeyTheMarkerSaysSoAndNoPublicKeyIsLeftBehind() throws {
        let keys = WebAppKeyHandoff.Keys(vaultKeyB64: "VkFVTFQ=", sharingPubB64: "UFVC", signPublicB64: nil)
        let script = try XCTUnwrap(WebAppKeyHandoff.buildScript(keys: keys, origin: origin))
        XCTAssertTrue(script.contains("signing:false"))
        XCTAssertTrue(script.contains("s.removeItem('pingolin_note_sign_public')"))
    }

    func testNothingIsHandedOverFromMalformedValues() {
        XCTAssertNil(WebAppKeyHandoff.buildScript(keys: nil, origin: origin))
        let bad = WebAppKeyHandoff.Keys(vaultKeyB64: "x');alert(1);//", sharingPubB64: "UFVC", signPublicB64: nil)
        XCTAssertNil(WebAppKeyHandoff.buildScript(keys: bad, origin: origin))
    }

    /// The script as WebKit runs it. On the note origin it hands over the keys
    /// and removes what earlier builds left behind — the private halves in
    /// sessionStorage, the client key in both storages — while the page's own
    /// data stays; on any other origin it touches nothing.
    func testTheHandoffScriptSweepsOnlyLegacyKeysAndOnlyOnTheNoteOrigin() async throws {
        let keys = WebAppKeyHandoff.Keys(vaultKeyB64: "VkFVTFQ=", sharingPubB64: "UFVC", signPublicB64: nil)
        let script = try XCTUnwrap(WebAppKeyHandoff.buildScript(keys: keys, origin: origin))
        func run(on base: String) async throws -> [String: Any] {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            let web = WKWebView(frame: .zero, configuration: config)
            let loaded = expectation(description: "loaded \(base)")
            let delegate = LoadDelegate { loaded.fulfill() }
            web.navigationDelegate = delegate
            web.loadHTMLString("<html><body>x</body></html>", baseURL: URL(string: base)!)
            await fulfillment(of: [loaded], timeout: 20)
            _ = try await web.evaluateJavaScript("""
                localStorage.setItem('pingolin_note_client_key','old');
                localStorage.setItem('pingolin_note_metadata','keep');
                sessionStorage.setItem('pingolin_note_client_key','old');
                sessionStorage.setItem('pingolin_note_sharing_priv','old'); 1
                """)
            _ = try await web.evaluateJavaScript(script + "; 1")
            let state = try await web.evaluateJavaScript("""
                JSON.stringify({lck: localStorage.getItem('pingolin_note_client_key'),
                  meta: localStorage.getItem('pingolin_note_metadata'),
                  sck: sessionStorage.getItem('pingolin_note_client_key'),
                  priv: sessionStorage.getItem('pingolin_note_sharing_priv'),
                  vault: sessionStorage.getItem('pingolin_note_session_key'),
                  marker: !!window.__pingolinKeyBridge})
                """) as? String
            _ = delegate
            return try JSONSerialization.jsonObject(with: Data(XCTUnwrap(state).utf8)) as? [String: Any] ?? [:]
        }
        let mine = try await run(on: "https://note.pingolindev.com/")
        XCTAssertTrue(mine["lck"] is NSNull, "the legacy client key leaves localStorage: \(mine)")
        XCTAssertTrue(mine["sck"] is NSNull, "\(mine)")
        XCTAssertTrue(mine["priv"] is NSNull, "\(mine)")
        XCTAssertEqual(mine["meta"] as? String, "keep", "the page's own data stays")
        XCTAssertEqual(mine["vault"] as? String, "VkFVTFQ=")
        XCTAssertEqual(mine["marker"] as? Bool, true)

        let theirs = try await run(on: "https://account.pingolindev.com/")
        XCTAssertEqual(theirs["lck"] as? String, "old", "another origin is not touched")
        XCTAssertTrue(theirs["vault"] is NSNull, "\(theirs)")
        XCTAssertEqual(theirs["marker"] as? Bool, false)
    }

    // MARK: - The bridge

    func testOnlyTheMainFrameOfTheNoteOriginMayUseTheBridge() {
        XCTAssertTrue(WebKeyBridge.isAllowed(isMainFrame: true, scheme: "https", host: "note.pingolindev.com", port: 0, origin: origin))
        XCTAssertTrue(WebKeyBridge.isAllowed(isMainFrame: true, scheme: "https", host: "note.pingolindev.com", port: 443, origin: origin))
        XCTAssertFalse(WebKeyBridge.isAllowed(isMainFrame: false, scheme: "https", host: "note.pingolindev.com", port: 0, origin: origin))
        XCTAssertFalse(WebKeyBridge.isAllowed(isMainFrame: true, scheme: "https", host: "account.pingolindev.com", port: 0, origin: origin))
        XCTAssertFalse(WebKeyBridge.isAllowed(isMainFrame: true, scheme: "http", host: "note.pingolindev.com", port: 0, origin: origin))
        XCTAssertFalse(WebKeyBridge.isAllowed(isMainFrame: true, scheme: "https", host: "note.pingolindev.com", port: 8443, origin: origin))
    }

    private struct Account {
        let priv: Bytes
        let pubHex: String
        init() {
            priv = Sodium().randomBytes.buf(length: 32)!
            pubHex = deriveSharingPublicKey(privateKey: Data(priv))!
        }
    }

    private func source(_ account: Account, seed: String? = nil, userId: String? = "5f2b8e2a-3c1d-4e5f-9a6b-7c8d9e0f1a2b",
                        previous: [String] = []) -> WebKeyBridge.KeySource {
        let privB64 = Data(account.priv).base64EncodedString()
        return WebKeyBridge.KeySource(
            sharingPrivateKeyBase64: { privB64 },
            signingSeedBase64: { seed },
            userId: { userId },
            previousVaultKeys: { previous }
        )
    }

    func testOpenSealedKeyOpensAShareAddressedToThisAccountOnly() async throws {
        let me = Account(), someoneElse = Account()
        let contentKey = Data((0..<32).map { UInt8($0) })
        let toMe = try sealForRecipient(contentKey: contentKey, recipientPublicKey: me.pubHex)
        let toThem = try sealForRecipient(contentKey: contentKey, recipientPublicKey: someoneElse.pubHex)

        let opened = await WebKeyBridge.handle(["op": "openSealedKey", "sealed": toMe], keys: source(me))
        XCTAssertEqual(try opened.get()["key"] as? String, contentKey.base64EncodedString())

        let notMine = await WebKeyBridge.handle(["op": "openSealedKey", "sealed": toThem], keys: source(me))
        XCTAssertTrue(try notMine.get()["key"] is NSNull, "a wrap that does not open is an answer, not an error")

        let garbage = await WebKeyBridge.handle(["op": "openSealedKey", "sealed": "not base64!"], keys: source(me))
        XCTAssertEqual(garbage.failure, .invalidRequest)
        let signedOut = await WebKeyBridge.handle(["op": "openSealedKey", "sealed": toMe], keys: source(me, userId: nil))
        XCTAssertEqual(signedOut.failure, .signedOut)
    }

    /// The signature must be byte-identical to what the web editor's own
    /// signNoteShareWrap produces for the same seed and fields (vector
    /// made by running the web editor's crypto.ts), or every share signed
    /// through the bridge would fail verification at its recipients.
    func testSignShareWrapMatchesNoteUIByteForByte() async throws {
        let request: [String: Any] = [
            "op": "signShareWrap",
            "senderUserId": "5f2b8e2a-3c1d-4e5f-9a6b-7c8d9e0f1a2b",
            "recipientUserId": "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d",
            "itemId": "c3d4e5f6-a7b8-4c9d-8e0f-1a2b3c4d5e6f",
            "contentKeyVersion": NSNumber(value: 7),
            "wrappedKey": "AQQHCg0QExYZHB8iJSgrLjE0Nzo9QENGSUxPUlVYW15hZGdqbXBzdnl8f4KFiIuOkZSXmp2go6aprK+ytbi7vsHEx8rN0NPW2dzf4uXo6+4=",
        ]
        let keys = source(Account(), seed: "CxAVGh8kKS4zOD1CR0xRVltgZWpvdHl+g4iNkpecoaY=", userId: "5F2B8E2A-3C1D-4E5F-9A6B-7C8D9E0F1A2B")
        let result = await WebKeyBridge.handle(request, keys: keys)
        XCTAssertEqual(try result.get()["signature"] as? String,
                       "68f2cfbbb43745f836846e2184a8bde8d6421e26bdb0ad1accd173507980294d39dade2750942c368cdeb3b5a6732bb4283766a98bced966aa60406a82c56309")

        // And the vector the web editor pins for this bridge
        // (keyOps.test.ts, "signShareWrap vector (for note-ios)"):
        // seed 0x01…0x20, wrapped key 0x00…0x4f.
        let pinned: [String: Any] = [
            "op": "signShareWrap",
            "senderUserId": "11111111-1111-4111-8111-111111111111",
            "recipientUserId": "22222222-2222-4222-8222-222222222222",
            "itemId": "33333333-3333-4333-8333-333333333333",
            "contentKeyVersion": NSNumber(value: 3),
            "wrappedKey": Data((0..<80).map { UInt8($0) }).base64EncodedString(),
        ]
        let pinnedKeys = source(Account(), seed: Data((1...32).map { UInt8($0) }).base64EncodedString(),
                                userId: "11111111-1111-4111-8111-111111111111")
        let pinnedResult = await WebKeyBridge.handle(pinned, keys: pinnedKeys)
        XCTAssertEqual(try pinnedResult.get()["signature"] as? String,
                       "c1db352c420039759ab3ec7f8ff39347cfc5e6abdae5e6553585bf92122f80de" +
                       "a469e97f5becb94a35e6f3ff8eb50e60952feb54f5f0292edc38de4d0941ba0b")
    }

    func testSignShareWrapRefusesAnotherSenderMissingSeedAndBadVersions() async {
        var request: [String: Any] = [
            "op": "signShareWrap", "senderUserId": "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d",
            "recipientUserId": "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d", "itemId": "c3d4e5f6-a7b8-4c9d-8e0f-1a2b3c4d5e6f",
            "contentKeyVersion": NSNumber(value: 1), "wrappedKey": Data(repeating: 1, count: 80).base64EncodedString(),
        ]
        let seed = Data(repeating: 7, count: 32).base64EncodedString()
        let a = Account()
        let other = await WebKeyBridge.handle(request, keys: source(a, seed: seed))
        XCTAssertEqual(other.failure, .senderMismatch)

        request["senderUserId"] = "5f2b8e2a-3c1d-4e5f-9a6b-7c8d9e0f1a2b"
        let noSeed = await WebKeyBridge.handle(request, keys: source(a, seed: nil))
        XCTAssertEqual(noSeed.failure, .signingUnavailable)

        for bad: Any in [NSNumber(value: -1), NSNumber(value: 1.5), NSNumber(value: true), NSNumber(value: 4_294_967_296.0), "1"] {
            request["contentKeyVersion"] = bad
            let r = await WebKeyBridge.handle(request, keys: source(a, seed: seed))
            XCTAssertEqual(r.failure, .invalidRequest, "\(bad)")
        }
    }

    func testPreviousVaultKeysAndUnknownOps() async throws {
        let a = Account()
        let prev = await WebKeyBridge.handle(["op": "previousVaultKeys"], keys: source(a, previous: ["QQ==", "Qg=="]))
        XCTAssertEqual(try prev.get()["keys"] as? [String], ["QQ==", "Qg=="])
        let unknown = await WebKeyBridge.handle(["op": "exportPrivateKey"], keys: source(a))
        XCTAssertEqual(unknown.failure, .unknownOp)
        let notAnObject = await WebKeyBridge.handle("openSealedKey", keys: source(a))
        XCTAssertEqual(notAnObject.failure, .invalidRequest)
    }

    /// The adapter through real WebKit: a page on the note origin gets an
    /// answer; the same script on another origin is refused by the frame
    /// origin WebKit reports (which the page cannot forge).
    @MainActor
    func testTheBridgeAnswersTheNoteOriginAndRefusesAnotherOrigin() async throws {
        let keys = WebKeyBridge.KeySource(
            sharingPrivateKeyBase64: { Data(repeating: 1, count: 32).base64EncodedString() },
            signingSeedBase64: { nil },
            userId: { "5f2b8e2a-3c1d-4e5f-9a6b-7c8d9e0f1a2b" },
            previousVaultKeys: { ["QQ=="] }
        )
        func run(on base: String) async throws -> Any? {
            let controller = WKUserContentController()
            controller.addScriptMessageHandler(WebKeyBridgeHandler(origin: origin, keys: keys),
                                               contentWorld: .page, name: WebKeyBridge.handlerName)
            let config = WKWebViewConfiguration()
            config.userContentController = controller
            config.websiteDataStore = .nonPersistent()
            let web = WKWebView(frame: .zero, configuration: config)
            let loaded = expectation(description: "loaded \(base)")
            let delegate = LoadDelegate { loaded.fulfill() }
            web.navigationDelegate = delegate
            web.loadHTMLString("<html><body>x</body></html>", baseURL: URL(string: base)!)
            await fulfillment(of: [loaded], timeout: 20)
            let result = try await web.callAsyncJavaScript("""
                try {
                  return await window.webkit.messageHandlers.pingolinKeys.postMessage({op: 'previousVaultKeys'});
                } catch (e) { return 'rejected: ' + e.message; }
                """, arguments: [:], in: nil, contentWorld: .page)
            _ = delegate
            return result
        }
        let mine = try await run(on: "https://note.pingolindev.com/")
        XCTAssertEqual((mine as? [String: Any])?["keys"] as? [String], ["QQ=="])
        let theirs = try await run(on: "https://account.pingolindev.com/")
        XCTAssertEqual(theirs as? String, "rejected: origin not allowed")
    }

    // MARK: - Which challenges get the code entry

    func testOnlyAChallengeOfferingTOTPGetsTheCodeEntry() throws {
        XCTAssertTrue(AuthManager.canAnswerTwoFactor(["totp"]))
        XCTAssertTrue(AuthManager.canAnswerTwoFactor(["passkey", "TOTP"]))
        XCTAssertFalse(AuthManager.canAnswerTwoFactor(["passkey"]))
        XCTAssertFalse(AuthManager.canAnswerTwoFactor([]))
        XCTAssertTrue(AuthManager.canAnswerTwoFactor(nil), "an older server that lists nothing keeps the code entry")

        // The app's own wire decoder, auth's real key names.
        let step2: SRPStep2Response = try APIService.decodeSuccessBody(Data(#"""
        {"server_proof":"p","requires_2fa":true,"two_factor_token":"t","available_methods":["passkey"],"preferred_method":"passkey"}
        """#.utf8), using: APIService.makeWireDecoder())
        XCTAssertEqual(step2.requires2fa, true)
        XCTAssertEqual(step2.availableMethods, ["passkey"])
        XCTAssertTrue(AuthManager.isTwoFactorChallenge(step2))
        XCTAssertEqual(AuthManager.AuthError.twoFactorPasskeyOnly.errorDescription,
                       "This account's second step uses a passkey, which this app can't use yet. " +
                       "Add an authenticator app in your account settings, or sign in on the web.")
    }

    // MARK: - Cookies, token expiry, backup exclusion, store location

    func testThePageGetsAnHttpOnlyShortLivedAccessTokenCookie() throws {
        let url = URL(string: origin)!
        let cookie = try XCTUnwrap(WebShellModel.authCookie(token: "a.b.c", domain: ".pingolindev.com", url: url, maxAge: 900))
        XCTAssertEqual(cookie.name, "auth_token")
        XCTAssertTrue(cookie.isHTTPOnly, "page script must not be able to read the token")
        XCTAssertTrue(cookie.isSecure)
        XCTAssertEqual(cookie.path, "/")
        XCTAssertEqual(cookie.domain, ".pingolindev.com")
        XCTAssertFalse(cookie.isSessionOnly)
        let expires = try XCTUnwrap(cookie.expiresDate)
        XCTAssertEqual(expires.timeIntervalSinceNow, 900, accuracy: 60)
    }

    func testAccessTokenExpiryIsReadFromTheJWT() {
        func jwt(_ claims: String) -> String {
            let b = Data(claims.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            return "eyJhbGciOiJIUzI1NiJ9.\(b).c2ln"
        }
        XCTAssertEqual(APIService.accessTokenExpiry(jwt(#"{"sub":"u","exp":1900000000}"#))?.timeIntervalSince1970, 1_900_000_000)
        XCTAssertNil(APIService.accessTokenExpiry("not-a-jwt"))
        XCTAssertNil(APIService.accessTokenExpiry(jwt(#"{"sub":"u"}"#)))
    }

    func testAuthCookiesAnEarlierBuildStoredArePurgedFromTheSharedJar() {
        let storage = HTTPCookieStorage.shared
        let url = URL(string: "https://account.pingolindev.com/api/v1/auth/refresh")!
        let stale = HTTPCookie.cookies(withResponseHeaderFields: [
            "Set-Cookie": "refresh_token=secret; Path=/api/v1/auth/refresh; Max-Age=2592000; Secure; HttpOnly",
        ], for: url)
        storage.setCookies(stale, for: url, mainDocumentURL: nil)
        XCTAssertTrue((storage.cookies ?? []).contains { $0.name == "refresh_token" })
        APIService.purgeStoredAuthCookies()
        XCTAssertFalse((storage.cookies ?? []).contains { $0.name == "refresh_token" })
    }

    /// The once-per-launch reset empties the page's cookie jar — an earlier
    /// build's 30-day refresh_token included — and nothing else: the page's
    /// own storage, where unsynced edits wait, is untouched.
    @MainActor
    func testTheCookieJarResetRemovesCookiesOnlyNotThePagesStorage() async throws {
        let dataStore = WKWebsiteDataStore.nonPersistent()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        let web = WKWebView(frame: .zero, configuration: config)
        let loaded = expectation(description: "loaded")
        let delegate = LoadDelegate { loaded.fulfill() }
        web.navigationDelegate = delegate
        web.loadHTMLString("<html><body>x</body></html>", baseURL: URL(string: origin + "/")!)
        await fulfillment(of: [loaded], timeout: 20)
        _ = try await web.evaluateJavaScript("localStorage.setItem('queued','edit'); 1")
        let old = try XCTUnwrap(HTTPCookie(properties: [
            .name: "refresh_token", .value: "old", .domain: ".pingolindev.com", .path: "/",
            .secure: "TRUE", .expires: Date(timeIntervalSinceNow: 30 * 24 * 3600),
        ]))
        await dataStore.httpCookieStore.setCookie(old)
        await dataStore.httpCookieStore.setCookie(try XCTUnwrap(WebShellModel.authCookie(
            token: "a.b.c", domain: ".pingolindev.com", url: URL(string: origin)!, maxAge: 900)))
        let before = await dataStore.httpCookieStore.allCookies()
        XCTAssertEqual(before.count, 2)

        await WebShellModel.resetCookieJar(dataStore)
        let after = await dataStore.httpCookieStore.allCookies()
        XCTAssertEqual(after.map(\.name), [], "the jar is empty")
        let kept = try await web.evaluateJavaScript("localStorage.getItem('queued')") as? String
        XCTAssertEqual(kept, "edit", "the page's own storage stays")
        _ = delegate
    }

    /// The native session keeps neither a cookie jar nor a response cache: the
    /// default cache writes the sign-in and refresh replies, refresh token
    /// included, to Library/Caches/<bundle>/Cache.db.
    func testNativeCallsKeepNoCookiesAndNoCachedResponses() throws {
        let configuration = APIService.makeSessionConfiguration()
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertNil(configuration.urlCache, "a sign-in reply must not be written to Cache.db")

        let cache = URLCache(memoryCapacity: 1 << 20, diskCapacity: 0)
        let request = URLRequest(url: URL(string: "https://api-auth.pingolindev.com/api/v1/auth/me")!)
        let response = try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                                     headerFields: ["Cache-Control": "max-age=600"]))
        cache.storeCachedResponse(CachedURLResponse(response: response, data: Data("{\"refresh_token\":\"x\"}".utf8)), for: request)
        XCTAssertNotNil(cache.cachedResponse(for: request))
        APIService.purgeCachedResponses(cache: cache)
        XCTAssertNil(cache.cachedResponse(for: request))
    }

    func testWebKitDirectoriesAreMarkedExcludedFromBackup() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let marked = WebShellDataStore.excludeWebKitDataFromBackup(library: tmp)
        XCTAssertEqual(marked.map(\.lastPathComponent), WebShellDataStore.backupExcludedLibraryPaths)
        for dir in marked {
            XCTAssertEqual(try dir.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true,
                           dir.lastPathComponent)
        }
    }

    /// The page stays on the DEFAULT store — nothing is moved or cleared on
    /// update, because that store holds any edit the page has not synced yet —
    /// and what the page writes there lands under directories excluded from
    /// backup. Measured, not assumed: a page on `WebShellDataStore.store()`
    /// writes a unique value to localStorage and a cookie, and the files that
    /// end up holding it are found on disk.
    @MainActor
    func testThePageStaysOnTheDefaultStoreAndItsDataLandsOnlyUnderExcludedDirectories() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "WebShellStoreTests-\(UUID().uuidString)"))
        let library = try XCTUnwrap(FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first)
        WebShellDataStore.excludeWebKitDataFromBackup(library: library)
        let store = WebShellDataStore.store(defaults: defaults)
        XCTAssertNil(store.identifier, "the default store, not a dedicated one")
        XCTAssertTrue(store.isPersistent)

        let marker = "s9probe" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let config = WKWebViewConfiguration()
        config.websiteDataStore = store
        let web = WKWebView(frame: .zero, configuration: config)
        let loaded = expectation(description: "page loaded")
        let delegate = LoadDelegate { loaded.fulfill() }
        web.navigationDelegate = delegate
        web.loadHTMLString("<html><body>x</body></html>", baseURL: URL(string: "https://note.pingolindev.com/")!)
        await fulfillment(of: [loaded], timeout: 20)
        _ = try await web.evaluateJavaScript("localStorage.setItem('s9probe','\(marker)'); 1")
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .name: "s9probe", .value: marker, .domain: "note.pingolindev.com", .path: "/",
            .expires: Date(timeIntervalSinceNow: 600),
        ]))
        await store.httpCookieStore.setCookie(cookie)

        // WebKit's storage process flushes on its own schedule: poll for the
        // localStorage value to reach disk.
        var holders: [URL] = []
        let deadline = Date().addingTimeInterval(20)
        repeat {
            holders = Self.files(under: library, containing: marker)
            if holders.contains(where: { $0.path.contains("/WebKit/") }) { break }
            try await Task.sleep(nanoseconds: 500_000_000)
        } while Date() < deadline
        print("[WebShellKeyBridgeTests] files holding the page's data: \(holders.map { $0.path.replacingOccurrences(of: library.path, with: "Library") })")
        XCTAssertTrue(holders.contains { $0.path.contains("/WebKit/") }, "the page's localStorage should reach disk under Library/WebKit")
        let excluded = WebShellDataStore.backupExcludedLibraryPaths.map { library.appendingPathComponent($0).path + "/" }
        for file in holders {
            XCTAssertTrue(excluded.contains { file.path.hasPrefix($0) }, "page data outside an excluded dir: \(file.path)")
        }
        for name in WebShellDataStore.backupExcludedLibraryPaths {
            let dir = library.appendingPathComponent(name, isDirectory: true)
            XCTAssertEqual(try dir.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true,
                           "\(name) must still be excluded after WebKit wrote into it")
        }

        _ = try await web.evaluateJavaScript("localStorage.removeItem('s9probe'); 1")
        await store.httpCookieStore.deleteCookie(cookie)
        _ = delegate
    }

    /// An install that still has the dedicated store an earlier build
    /// used keeps it — and any unsynced edit in it — until it signs out;
    /// leaving it then returns the shell to the default store.
    @MainActor
    func testAnEarlierBuildsDedicatedStoreIsKeptUntilSignOut() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "WebShellStoreTests-\(UUID().uuidString)"))
        let id = UUID()
        defaults.set(id.uuidString, forKey: WebShellDataStore.dedicatedIdentifierKey)
        XCTAssertEqual(WebShellDataStore.store(defaults: defaults).identifier, id)
        XCTAssertEqual(WebShellDataStore.store(defaults: defaults).identifier, id, "stable across launches")

        let left = WebShellDataStore.leaveDedicatedStore(defaults)
        XCTAssertEqual(left?.identifier, id, "the store handed back to be emptied")
        XCTAssertNil(WebShellDataStore.dedicatedIdentifier(defaults))
        XCTAssertNil(WebShellDataStore.store(defaults: defaults).identifier, "back on the default store")
        XCTAssertNil(WebShellDataStore.leaveDedicatedStore(defaults), "nothing to leave on an ordinary install")
        try? await WKWebsiteDataStore.remove(forIdentifier: id)
    }

    /// Every file under `root` (Caches aside — never backed up) holding
    /// `marker`, as UTF-8 or UTF-16LE (WebKit's LocalStorage keeps UTF-16).
    private static func files(under root: URL, containing marker: String) -> [URL] {
        let needles = [Data(marker.utf8), marker.data(using: .utf16LittleEndian) ?? Data()]
        let caches = root.appendingPathComponent("Caches").path + "/"
        guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else {
            return []
        }
        var found: [URL] = []
        while let url = walk.nextObject() as? URL {
            guard !url.path.hasPrefix(caches),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true, (values.fileSize ?? 0) < 32 * 1024 * 1024,
                  let data = try? Data(contentsOf: url)
            else { continue }
            if needles.contains(where: { !$0.isEmpty && data.range(of: $0) != nil }) { found.append(url) }
        }
        return found
    }
}

private final class LoadDelegate: NSObject, WKNavigationDelegate {
    private let done: () -> Void
    init(_ done: @escaping () -> Void) { self.done = done }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done() }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let f) = self { return f }
        return nil
    }
}
