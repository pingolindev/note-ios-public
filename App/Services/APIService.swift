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
import os

actor APIService {
    static let shared = APIService()

    /// Release-visible sync telemetry: surfaces a >20k-item
    /// page-cap truncation in the field, not only under `#if DEBUG`.
    private static let syncLog = Logger(subsystem: "com.pingolin.note", category: "sync")

    private let session: URLSession
    private let config = AppConfiguration.shared
    private let keychain = KeychainService.shared
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    private init() {
        // System trust minus the leaked emSign keys (`TrustBlocklist`), which
        // only ever refuses.
        self.session = TrustBlocklist.session(configuration: Self.makeSessionConfiguration())
        self.decoder = Self.makeWireDecoder()
        self.encoder = Self.makeWireEncoder()
    }

    nonisolated static func makeSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        // No cookie jar. Every call here authenticates with the Bearer header,
        // but the auth server also answers login and refresh with Set-Cookie
        // `refresh_token=…; Max-Age=2592000` for the web — and the default
        // configuration would store it in HTTPCookieStorage.shared, i.e.
        // Library/Cookies, which iOS backs up: a 30-day refresh token riding
        // every iCloud backup next to the Keychain copy that deliberately
        // does not. `purgeStoredAuthCookies()` removes what earlier builds
        // left there.
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        // No response cache either. The default one writes the sign-in and
        // refresh REPLIES to Library/Caches/<bundle>/Cache.db — bodies and
        // Set-Cookie headers, each carrying the refresh token in plaintext
        // outside the Keychain. Nothing here is served from cache.
        // `purgeCachedResponses()` removes what earlier builds left there.
        configuration.urlCache = nil
        // No certificate pinning, on purpose: system trust only. Every host
        // sits behind Cloudflare Universal SSL, which picks the issuing CA and
        // rotates it without notice, so a pin hard-fails every request the day
        // Cloudflare swaps CA. Pinning would need Advanced Certificate Manager
        // (to fix the CA), root pins with a backup, and a remote kill switch.
        // The Android app does not pin either.
        return configuration
    }

    /// The JSON coders every call uses. Factories rather than inline set-up so
    /// tests decode REAL server bodies through exactly this configuration — a
    /// test with its own look-alike decoder, fed a hand-written key, can miss a
    /// key the real decoder converts differently (see `SRPStep2Response`).
    nonisolated static func makeWireDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    nonisolated static func makeWireEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// Read a 2xx body the way every call does: the server's `{success, data}`
    /// envelope first, else the bare value.
    nonisolated static func decodeSuccessBody<T: Decodable>(_ data: Data, using decoder: JSONDecoder) throws -> T {
        if let wrapped = try? decoder.decode(APIResponse<T>.self, from: data),
           let result = wrapped.data {
            return result
        }
        return try decoder.decode(T.self, from: data)
    }

    // MARK: - Auth

    func srpStep1(email: String) async throws -> SRPStep1Response {
        let attest = await AttestationManager.shared.getOrFetchToken()
        return try await post("/api/v1/auth/srp/step1",
                              body: SRPStep1Request(email: email),
                              auth: false,
                              baseURL: config.authBaseURL,
                              attestationToken: attest)
    }

    func srpStep2(sessionId: String, clientPublic: String, clientProof: String) async throws -> SRPStep2Response {
        let attest = await AttestationManager.shared.getOrFetchToken()
        return try await post("/api/v1/auth/srp/step2",
                              body: SRPStep2Request(sessionId: sessionId, clientPublic: clientPublic, clientProof: clientProof),
                              auth: false,
                              baseURL: config.authBaseURL,
                              attestationToken: attest)
    }

    /// Complete a login that stopped at the 2FA challenge.
    ///
    /// The route is the one the server registers, `/api/v1/auth/login/2fa`.
    ///
    /// The reply is a full `LoginResponse`: it carries the user, the KDF
    /// params and the encrypted key blobs, so this path needs no follow-up
    /// `/me` to derive the vault key.
    func verify2FA(twoFactorToken: String, code: String, method: String = "totp") async throws -> Login2FAResponse {
        let attest = await AttestationManager.shared.getOrFetchToken()
        return try await post("/api/v1/auth/login/2fa",
                              body: Verify2FARequest(twoFactorToken: twoFactorToken, code: code, method: method),
                              auth: false,
                              baseURL: config.authBaseURL,
                              attestationToken: attest)
    }

    func getMe() async throws -> MeResponse {
        try await get("/api/v1/auth/me", baseURL: config.authBaseURL)
    }

    /// SRP step-up re-authentication, step 1. Bodyless and authenticated: the
    /// server identifies the account from the session rather than an emailed
    /// identity, so there is no enumeration surface. Reuses SRPStep1Response
    /// (salt, server_public, session_id, bcrypt_salt).
    /// Backend route: POST /api/v1/auth/reauth/srp/step1.
    func reauthStep1() async throws -> SRPStep1Response {
        try await post("/api/v1/auth/reauth/srp/step1",
                       body: EmptyBody(),
                       baseURL: config.authBaseURL)
    }

    /// SRP step-up re-authentication, step 2. Reuses SRPStep2Request
    /// (session_id, client_public, client_proof). On a valid proof the server
    /// returns a short-lived `reauth_token` the caller passes to
    /// DELETE /api/v1/auth/me in place of the raw password. A wrong password
    /// fails proof verification server-side and throws (401).
    /// Backend route: POST /api/v1/auth/reauth/srp/step2.
    func reauthStep2(sessionId: String, clientPublic: String, clientProof: String) async throws -> ReauthStep2Response {
        try await post("/api/v1/auth/reauth/srp/step2",
                       body: SRPStep2Request(sessionId: sessionId, clientPublic: clientPublic, clientProof: clientProof),
                       baseURL: config.authBaseURL)
    }

    /// Permanently delete the current account (GDPR Article 17). Backend route:
    /// DELETE /api/v1/auth/me on the auth API, carrying a short-lived
    /// `reauth_token` minted by the SRP step-up above in place of the raw
    /// password.
    ///
    /// Note sends no `pseudonyms`: those exist so Track's location rows, keyed
    /// by per-circle pseudonym rather than user id, can be found. Note has
    /// nothing of the kind, and the server defaults the field.
    func deleteAccount(
        reauthToken: String,
        forfeitCreditBalance: Bool = false
    ) async throws -> DeleteAccountResponse {
        try await delete("/api/v1/auth/me",
                         body: DeleteAccountRequest(
                             reauthToken: reauthToken,
                             forfeitCreditBalance: forfeitCreditBalance ? true : nil
                         ),
                         baseURL: config.authBaseURL)
    }

    // MARK: - Attestation (App Attest, mirrors android Dtos.kt attestation block)

    /// Reports which verifiers the auth backend has enabled. Clients
    /// can use this to know whether to bother running App Attest at
    /// all on this build.
    func getAttestationStatus() async throws -> AttestationStatusResponse {
        try await get("/api/v1/auth/attest/status", auth: false, baseURL: config.authBaseURL)
    }

    /// Server-issued nonce for DCAppAttestService.attestKey(). The
    /// `platform=apple` query selects the Apple verifier.
    func getAttestationChallenge() async throws -> AttestationChallengeResponse {
        try await get("/api/v1/auth/attest/challenge?platform=apple",
                      auth: false, baseURL: config.authBaseURL)
    }

    /// Submit the App Attest payload; server verifies against Apple's
    /// root cert + issues an attestation_token to echo on subsequent
    /// register/login as X-Attestation-Token.
    func verifyAppleAttestation(
        attestation: String,
        challenge: String,
        keyId: String
    ) async throws -> AttestationVerifyResponse {
        try await post("/api/v1/auth/attest/apple",
                       body: AppleAttestVerifyRequest(
                           attestation: attestation,
                           challenge: challenge,
                           keyId: keyId
                       ),
                       auth: false,
                       baseURL: config.authBaseURL)
    }

    /// Update the user's display name. Mirrors android's
    /// PATCH /api/v1/auth/me.
    ///
    /// Returns `UpdateDisplayNameResponse` — `{ "display_name": ... }`, which
    /// is the whole of what the server sends. Decoding it as `MeResponse`,
    /// whose `id` and `email` are non-optional, would throw `keyNotFound(id)`
    /// on a request that succeeded: the name changes on the server and the
    /// user is shown an error. Widening `MeResponse` instead would make
    /// required identity fields optional everywhere else too — so the reply
    /// has its own type.
    func updateMe(displayName: String) async throws -> UpdateDisplayNameResponse {
        try await patch("/api/v1/auth/me",
                        body: UpdateMeRequest(displayName: displayName),
                        baseURL: config.authBaseURL)
    }

    /// Exchange a refresh token for a fresh access+refresh pair. Mirrors
    /// android(auth) TokenAuthenticator: on 401 the caller runs this once
    /// (single-flight), then retries the original request with the new
    /// access token. On failure the user is logged out.
    func refreshToken(_ refreshToken: String) async throws -> TokenPairResponse {
        let attest = await AttestationManager.shared.getOrFetchToken()
        // The auth server reads the refresh credential from the
        // `X-Refresh-Token` header (mobile) or the `refresh_token` cookie
        // (web) — NOT from the request body. Posting `{refresh_token: …}`
        // makes the server take its legacy path, which rejects every
        // current session with "Please log in again to upgrade session".
        // Send the header with an empty body. Mirrors both Android apps.
        return try await post("/api/v1/auth/refresh",
                              body: [String: String](),
                              auth: false,
                              baseURL: config.authBaseURL,
                              attestationToken: attest,
                              extraHeaders: ["X-Refresh-Token": refreshToken])
    }

    /// `POST /api/v1/auth/logout` on the auth server: ends THIS session, so its
    /// refresh token dies with it and it stops counting toward the account's
    /// session cap. The body names the session by its refresh token, so it ends
    /// even when the access token has already expired, as in the Track iOS app.
    /// Never refreshes on a 401: a refresh landing after sign-out's keychain
    /// wipe would write fresh tokens back.
    func logout() async throws {
        var req = try Self.logoutRequest(
            authBaseURL: config.authBaseURL,
            accessToken: keychain.getString(for: .accessToken),
            refreshToken: keychain.getString(for: .refreshToken),
            encoder: encoder
        )
        req.setValue(config.userAgent, forHTTPHeaderField: "User-Agent")
        let _: EmptyResponse = try await execute(req, didRefresh: true)
    }

    /// The sign-out request: `{"refresh_token": …}`, plus whatever bearer the app
    /// holds, expired or not. A bearer is also what skips auth's CSRF check if a
    /// Cookie header were ever present; this session sends no cookies.
    nonisolated static func logoutRequest(
        authBaseURL: String,
        accessToken: String?,
        refreshToken: String?,
        encoder: JSONEncoder
    ) throws -> URLRequest {
        var req = URLRequest(url: URL(string: authBaseURL + "/api/v1/auth/logout")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try encoder.encode(LogoutRequest(refreshToken: refreshToken))
        if let accessToken {
            req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    // MARK: - Items (Notes / Notebooks / Labels — see ItemType)

    /// Identities the user recovered after a password reset. Empty for almost
    /// every account; see PreviousIdentityLoader.
    func getPreviousIdentities() async throws -> [PreviousIdentityResponse] {
        let response: PreviousIdentitiesResponse = try await get(
            "/api/v1/auth/previous-identities", baseURL: config.authBaseURL)
        return response.identities
    }

    /// Pull everything that changed for the current user since `since`.
    /// Defaults to the epoch (full sync) on first call. The server
    /// requires `since` as an ISO 8601 DateTime — there's no "omit"
    /// form. Returns encrypted blobs; decrypting them is the caller's
    /// job.
    func syncPull(since: Date = Date(timeIntervalSince1970: 0), sinceId: String? = nil, sinceRaw: String? = nil, limit: Int? = nil) async throws -> SyncResponse {
        // `sinceRaw`, when set, is a server-issued cursor (SyncResponse.cursor —
        // an RFC3339 string) threaded back verbatim on pagination. Using it
        // WITHOUT a Date round-trip preserves the exact sub-second value the
        // backend's compound (updated_at, id) keyset cursor compares against, so
        // a paged scan can neither skip nor re-fetch the page boundary. Falls
        // back to formatting the `since` Date for the first (un-paged) call.
        let sinceStr: String
        if let sinceRaw {
            sinceStr = sinceRaw
        } else {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            sinceStr = formatter.string(from: since)
        }
        let escaped = sinceStr.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? sinceStr
        var path = "/api/v1/sync/pull?since=\(escaped)"
        // Tie-breaker paired with `since` (the compound (updated_at, id) keyset
        // cursor from SyncResponse.cursorId). Omitted when nil → backend falls
        // back to a plain `updated_at > since`. `syncPullAll` threads it across
        // the pages of a scan.
        if let sinceId {
            let escapedId = sinceId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? sinceId
            path += "&since_id=\(escapedId)"
        }
        if let limit { path += "&limit=\(limit)" }
        return try await get(path)
    }

    /// Page through the ENTIRE `/sync/pull` result set for the current user,
    /// threading the server's compound keyset cursor (`cursor` = the last item's
    /// `updated_at`, `cursor_id` = its id) back as `since`/`since_id` until the
    /// backend reports `has_more == false`. The backend orders `updated_at ASC`
    /// and caps each page at `limit`, so a SINGLE `syncPull` only ever returns
    /// the OLDEST `limit` items — a vault larger than one page would never
    /// surface its newest notes to the list or the offline cache without this
    /// loop. Accumulates every page. `maxPages` is a defensive cap so a backend
    /// that never clears `has_more` can't spin forever; hitting it logs and
    /// returns what was gathered so far.
    func syncPullAll(sinceRaw startCursor: String? = nil, sinceId startCursorId: String? = nil,
                     limit: Int = 200, maxPages: Int = 100) async throws -> SyncPage {
        var all: [Item] = []
        var sinceRaw: String? = startCursor
        var sinceId: String? = startCursorId
        // The newest keyset boundary the server handed us across this scan — the
        // caller persists it as the next delta's watermark.
        // Seed it with the CALLER's watermark so a single-page delta (has_more
        // false, cursor nil) returns it UNCHANGED rather than nil (which would
        // reset the watermark and re-scan the same window forever). It advances
        // only on multi-page scans, so it settles ~one page behind the newest
        // item: the next delta re-fetches at most that final page (bounded,
        // idempotent) and never SKIPS a row.
        var watermark: String? = startCursor
        var watermarkId: String? = startCursorId
        var page = 0
        while page < maxPages {
            let response = try await syncPull(sinceId: sinceId, sinceRaw: sinceRaw, limit: limit)
            all.append(contentsOf: response.items)
            page += 1
            // Advance only while the server says there's more AND handed us a
            // cursor to resume from (the fast-path / final page has cursor == nil).
            // The (updated_at, id) keyset is strictly increasing, so the cursor
            // always advances — the page cap below is pure defense in depth.
            guard response.hasMore, let nextCursor = response.cursor else { break }
            watermark = nextCursor
            watermarkId = response.cursorId
            sinceRaw = nextCursor
            sinceId = response.cursorId
        }
        if page >= maxPages {
            // A >20k-item delta hit the page cap. Logged in RELEASE builds too
            // (not just DEBUG). Self-healing with the persisted watermark:
            // `watermark` points into what we gathered, so the NEXT sync
            // resumes there and drains the remainder — and a genuinely
            // pathological vault is observable in the field instead of silently
            // truncating.
            Self.syncLog.error("syncPullAll hit the \(maxPages, privacy: .public)-page cap; gathered \(all.count, privacy: .public) items — remainder deferred to the next incremental sync")
        }
        return SyncPage(items: all, cursor: watermark, cursorId: watermarkId)
    }

    /// Create an item. `encryptedContent` + `contentNonce` are base64.
    /// The actual encryption happens client-side using a per-item
    /// content key wrapped with the user's vault key.
    func createItem(_ request: CreateItemRequest) async throws -> Item {
        try await post("/api/v1/items", body: request)
    }

    func getItem(_ itemId: String) async throws -> Item {
        try await get("/api/v1/items/\(itemId)")
    }

    /// Update an item server-side. Mirrors android Dtos.kt +
    /// NoteApi PUT /api/v1/items/{id}.
    func updateItem(_ itemId: String, _ request: UpdateItemRequest) async throws -> Item {
        try await put("/api/v1/items/\(itemId)", body: request)
    }

    /// Update a shared-with-us note. Encrypts under the inbox-held
    /// content key (caller-supplied ciphertext) and sends NO wrap
    /// fields — only the owner rotates the wrap; PUTting any value
    /// (even "") would clobber the owner's wrapped_content_key and
    /// lock everyone out.
    ///
    /// `expectedVersion` is usually right: SharesInboxStore.reconcile
    /// adopts the live version from the recipient's /sync/pull copy of the
    /// share. The retry is the backstop for the cases where it's stale —
    /// an owner edit racing this PUT, or a share that's inbox-only (no
    /// pulled copy to learn the version from, so it falls back to the
    /// synthesized version 1). On a 409, refetch the live version and
    /// retry once (the "pull-then-merge before retrying" the
    /// UpdateItemRequest doc describes).
    func updateSharedNote(
        _ itemId: String,
        encryptedContent: String,
        contentNonce: String,
        expectedVersion: Int64
    ) async throws -> Item {
        try await Self.retryingOnVersionConflict(
            expectedVersion: expectedVersion,
            put: { version in
                try await self.updateItem(itemId, UpdateItemRequest(
                    encryptedContent: encryptedContent,
                    contentNonce: contentNonce,
                    expectedVersion: version
                ))
            },
            liveVersion: { try await self.getItem(itemId).version }
        )
    }

    /// Run `put(version)`; on an HTTP 409 (stale optimistic-concurrency
    /// version) fetch the live version via `liveVersion()` and retry
    /// exactly once. Generic over both effects so the retry policy is
    /// unit-testable without the network. A non-409 error, or a second
    /// 409 after the refetch, propagates.
    static func retryingOnVersionConflict(
        expectedVersion: Int64,
        put: (Int64) async throws -> Item,
        liveVersion: () async throws -> Int64
    ) async throws -> Item {
        do {
            return try await put(expectedVersion)
        } catch let err as APIError where err.status == 409 {
            let live = try await liveVersion()
            return try await put(live)
        }
    }

    func deleteItem(_ itemId: String) async throws {
        let _: EmptyResponse = try await delete("/api/v1/items/\(itemId)", body: EmptyBody())
    }

    /// Restore a trashed item (un-delete). NoteApi POST
    /// /api/v1/items/{id}/restore — counterpart to deleteItem.
    func restoreItem(_ itemId: String) async throws {
        let _: EmptyResponse = try await post("/api/v1/items/\(itemId)/restore", body: EmptyBody())
    }

    /// Hard-delete every trashed item for the current user — the
    /// "Empty trash" action. NoteApi DELETE /api/v1/trash.
    func purgeTrash() async throws {
        let _: EmptyResponse = try await delete("/api/v1/trash", body: EmptyBody())
    }

    // MARK: - Sharing

    func lookupPublicKeys(emails: [String]) async throws -> PublicKeyLookupResponse {
        try await post("/api/v1/users/public-keys", body: PublicKeyLookupRequest(emails: emails))
    }

    func listInbox() async throws -> [InboxShareResponse] {
        try await get("/api/v1/shares/inbox")
    }

    // MARK: - Shared-note inbox recipient consent (dismiss + block)

    /// Recipient-side "dismiss this shared note". Marks the inbound share row
    /// dismissed server-side so it drops out of the inbox and can't re-trigger a
    /// share-invite push. `shareId` is the
    /// inbox row id (`InboxShareResponse.shareId`), NOT the note/item id.
    func dismissInboxShare(_ shareId: String) async throws {
        let _: EmptyResponse = try await post("/api/v1/shares/inbox/\(shareId)/dismiss", body: EmptyBody())
    }

    /// Recipient-side "block this sender". Blocks the sender's email and
    /// retroactively dismisses every current inbound share from them; future
    /// shares are auto-dismissed server-side.
    func blockShareSender(email: String) async throws {
        let _: EmptyResponse = try await post("/api/v1/shares/block", body: BlockSenderRequest(email: email))
    }

    /// Recipient-side "unblock this sender". Removes the block; deliberately does
    /// NOT un-dismiss already-dismissed shares (dismissal is sticky server-side).
    func unblockShareSender(email: String) async throws {
        // Percent-encode the email so `@`/`+`/etc. can't break the path segment.
        let escaped = email.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? email
        let _: EmptyResponse = try await delete("/api/v1/shares/block/\(escaped)", body: EmptyBody())
    }

    /// The caller's blocked-sender emails, newest first — for a "blocked senders"
    /// management screen.
    func listShareBlocks() async throws -> [BlockedSenderDto] {
        try await get("/api/v1/shares/blocks")
    }

    // MARK: - Reminders (mirrors android Dtos.kt + NoteApi reminder routes)

    func listReminders() async throws -> [ReminderDto] {
        try await get("/api/v1/reminders")
    }

    func createReminder(_ request: CreateReminderRequest) async throws -> ReminderDto {
        try await post("/api/v1/reminders", body: request)
    }

    func deleteReminder(_ id: String) async throws {
        let _: EmptyResponse = try await delete("/api/v1/reminders/\(id)", body: EmptyBody())
    }

    // MARK: - Cooperative edit lock (mirrors android NoteApi acquire/peek/release)

    /// Acquire / extend a per-note edit lock. Server returns the
    /// current lock record either way: if someone else holds it, the
    /// caller surfaces "Locked by holder_display_name" and falls back
    /// to read-only.
    func acquireLock(itemId: String, displayName: String) async throws -> LockRecordDto {
        try await post("/api/v1/items/\(itemId)/lock",
                       body: AcquireLockRequest(displayName: displayName))
    }

    /// Peek the current lock without trying to acquire. Returns nil
    /// (decoded as a 204 / explicit null) when no lock is held.
    func peekLock(itemId: String) async throws -> LockRecordDto? {
        do {
            return try await get("/api/v1/items/\(itemId)/lock")
        } catch let err as APIError where err.code == "http_404" {
            return nil
        }
    }

    func releaseLock(itemId: String) async throws {
        let _: EmptyResponse = try await delete("/api/v1/items/\(itemId)/lock", body: EmptyBody())
    }

    // MARK: - Push

    func registerAPNs(deviceId: String, apnsToken: String, bundleId: String, appVersion: String?) async throws {
        let _: EmptyResponse = try await post("/api/v1/push/apns-register",
                                              body: APNsRegisterRequest(deviceId: deviceId,
                                                                        apnsToken: apnsToken,
                                                                        bundleId: bundleId,
                                                                        appVersion: appVersion))
    }

    func unregisterAPNs(deviceId: String) async throws {
        let _: EmptyResponse = try await delete("/api/v1/push/apns-register",
                                                body: APNsUnregisterRequest(deviceId: deviceId))
    }

    // MARK: - Quota

    /// Subscription tier + current usage. The single canonical source
    /// for client-side gating hints. The server is still the authority —
    /// this just spares the UI from discovering gates by bouncing off a
    /// 402. Mirrors android NoteApi.getQuota.
    func getQuota() async throws -> QuotaDto {
        try await get("/api/v1/quota")
    }

    // MARK: - HTTP

    /// May this account buy `product` through the App Store right now?
    ///
    /// The server refuses when a live WEB subscription already covers the
    /// product: buying again would charge the customer twice, and we cannot
    /// cancel the web subscription on their behalf from in here.
    func getApplePurchaseEligibility(product: String) async throws -> ApplePurchaseEligibility {
        // The slug is a fixed constant, not user input, so it goes straight into
        // the path — `get` here takes no query-parameter argument.
        try await get("/api/v1/billing/apple/eligibility?product=\(product)",
                      baseURL: config.authBaseURL)
    }

    /// Report a completed App Store purchase so the subscription exists without
    /// waiting for Apple's server notification.
    ///
    /// The notification stays the authority; this only closes the gap where a
    /// customer who has just paid would still see the free tier. Both write the
    /// same row by the same key, so arriving twice changes nothing.
    func linkApplePurchase(signedTransaction: String) async throws -> AppleLinkResponse {
        struct Body: Encodable { let signedTransaction: String }
        return try await post("/api/v1/billing/apple/link",
                              body: Body(signedTransaction: signedTransaction),
                              baseURL: config.authBaseURL)
    }

    private func get<T: Decodable>(_ path: String, auth: Bool = true, baseURL: String? = nil) async throws -> T {
        var req = URLRequest(url: URL(string: (baseURL ?? config.apiBaseURL) + path)!)
        req.httpMethod = "GET"
        try addHeaders(to: &req, auth: auth)
        return try await execute(req)
    }

    private func post<T: Decodable, B: Encodable>(_ path: String, body: B, auth: Bool = true, baseURL: String? = nil, attestationToken: String? = nil, extraHeaders: [String: String]? = nil) async throws -> T {
        var req = URLRequest(url: URL(string: (baseURL ?? config.apiBaseURL) + path)!)
        req.httpMethod = "POST"
        req.httpBody = try encoder.encode(body)
        try addHeaders(to: &req, auth: auth, attestationToken: attestationToken, extraHeaders: extraHeaders)
        return try await execute(req)
    }

    private func patch<T: Decodable, B: Encodable>(_ path: String, body: B, auth: Bool = true, baseURL: String? = nil) async throws -> T {
        var req = URLRequest(url: URL(string: (baseURL ?? config.apiBaseURL) + path)!)
        req.httpMethod = "PATCH"
        req.httpBody = try encoder.encode(body)
        try addHeaders(to: &req, auth: auth)
        return try await execute(req)
    }

    private func put<T: Decodable, B: Encodable>(_ path: String, body: B, auth: Bool = true, baseURL: String? = nil) async throws -> T {
        var req = URLRequest(url: URL(string: (baseURL ?? config.apiBaseURL) + path)!)
        req.httpMethod = "PUT"
        req.httpBody = try encoder.encode(body)
        try addHeaders(to: &req, auth: auth)
        return try await execute(req)
    }

    private func delete<T: Decodable, B: Encodable>(_ path: String, body: B, auth: Bool = true, baseURL: String? = nil) async throws -> T {
        var req = URLRequest(url: URL(string: (baseURL ?? config.apiBaseURL) + path)!)
        req.httpMethod = "DELETE"
        req.httpBody = try encoder.encode(body)
        try addHeaders(to: &req, auth: auth)
        return try await execute(req)
    }

    private func addHeaders(to req: inout URLRequest, auth: Bool, attestationToken: String? = nil, extraHeaders: [String: String]? = nil) throws {
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(config.userAgent, forHTTPHeaderField: "User-Agent")
        if auth {
            guard let token = keychain.getString(for: .accessToken) else {
                throw APIError(code: "unauthorized", message: "No access token")
            }
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let attestationToken {
            req.setValue(attestationToken, forHTTPHeaderField: "X-Attestation-Token")
        }
        if let extraHeaders {
            for (field, value) in extraHeaders {
                req.setValue(value, forHTTPHeaderField: field)
            }
        }
    }

    private func execute<T: Decodable>(_ req: URLRequest, attempt: Int = 0, didRefresh: Bool = false) async throws -> T {
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw APIError(code: "network_error", message: "Invalid response")
        }

        // A freshly-issued token can come back "Token not yet valid" for
        // a few seconds on the first call (clock skew against the JWT
        // `nbf` claim between servers). Retry with exponential backoff
        // (1s, 2s, 4s; ~7s total grace) before giving up.
        if http.statusCode == 401, attempt < 3,
           let bodyString = String(data: data, encoding: .utf8),
           bodyString.localizedCaseInsensitiveContains("not yet valid") {
            let delaySeconds = UInt64(1 << attempt)  // 1, 2, 4
            try await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
            return try await execute(req, attempt: attempt + 1, didRefresh: didRefresh)
        }

        // Generic 401 → try to refresh the access token once, then retry.
        // Mirrors android(auth) TokenAuthenticator single-flight refresh.
        // Skip for unauthenticated endpoints (no Authorization header in
        // the original request) and for the refresh call itself.
        if http.statusCode == 401, !didRefresh,
           req.value(forHTTPHeaderField: "Authorization") != nil,
           req.url?.path != "/api/v1/auth/refresh" {
            if await tryRefreshAccessToken() {
                var retried = req
                if let newToken = keychain.getString(for: .accessToken) {
                    retried.setValue("Bearer \(newToken)", forHTTPHeaderField: "Authorization")
                }
                return try await execute(retried, attempt: attempt, didRefresh: true)
            }
        }

        guard (200...299).contains(http.statusCode) else {
            // 402 Payment Required — the server just enforced a quota /
            // tier gate (note cap, attachment cap, sharing, reminders).
            // Refresh the cached quota so it reflects the cap that was
            // just hit. Guard against the quota endpoint itself to avoid
            // a refresh loop. Mirrors note-android SyncWorker's
            // refresh-on-402.
            if http.statusCode == 402, req.url?.path != "/api/v1/quota" {
                Task { @MainActor in QuotaManager.shared.refresh() }
            }
            // Server envelope: {success, data, error: String?, error_code: String?}
            // (matches android Dtos.kt). Pull the human-readable error
            // string and error_code out and synthesize an APIError.
            if let wrapped = try? decoder.decode(APIResponse<EmptyResponse>.self, from: data),
               let msg = wrapped.error {
                throw APIError(code: wrapped.errorCode ?? "http_\(http.statusCode)", message: msg,
                               status: http.statusCode, quota: wrapped.quota)
            }
            #if DEBUG
            let preview = String(data: data.prefix(400), encoding: .utf8) ?? "<binary>"
            throw APIError(code: "http_\(http.statusCode)", message: "Request failed: \(preview)", status: http.statusCode)
            #else
            throw APIError(code: "http_\(http.statusCode)", message: "Request failed", status: http.statusCode)
            #endif
        }
        return try Self.decodeSuccessBody(data, using: decoder)
    }

    /// Refresh the access token now if it expires within `seconds` (or its
    /// expiry cannot be read). For the web shell, which hands the page a copy
    /// of the access token and no refresh token, so the page can never
    /// refresh it itself. Returns false only when a needed refresh failed.
    @discardableResult
    func refreshAccessTokenIfExpiring(within seconds: TimeInterval) async -> Bool {
        guard let token = keychain.getString(for: .accessToken) else { return false }
        if let expiry = Self.accessTokenExpiry(token), expiry.timeIntervalSinceNow > seconds {
            return true
        }
        return await tryRefreshAccessToken()
    }

    /// The `exp` claim of a JWT access token, or nil when it cannot be read.
    /// No signature check: this only decides WHEN to refresh; the server still
    /// decides whether a token is valid.
    nonisolated static func accessTokenExpiry(_ jwt: String) -> Date? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = claims["exp"] as? NSNumber
        else { return nil }
        return Date(timeIntervalSince1970: exp.doubleValue)
    }

    /// Remove auth cookies an earlier build's cookie-accepting session stored
    /// in HTTPCookieStorage.shared (see the session configuration above).
    nonisolated static func purgeStoredAuthCookies(storage: HTTPCookieStorage = .shared) {
        for cookie in storage.cookies ?? [] where cookie.name == "refresh_token" || cookie.name == "auth_token" {
            storage.deleteCookie(cookie)
        }
    }

    /// Remove the responses an earlier build's caching session stored — the
    /// sign-in and refresh replies among them, refresh token and all (see the
    /// session configuration above). This session was the shared cache's only
    /// user.
    nonisolated static func purgeCachedResponses(cache: URLCache = .shared) {
        cache.removeAllCachedResponses()
    }

    /// Single-flight refresh. Reads the stored refresh token, calls
    /// `/auth/refresh`, persists the new pair, and returns true on
    /// success. Returns false (and logs the server's reason)
    /// on failure so the caller can fall through to a logout.
    private var refreshInFlight: Task<Bool, Never>?

    private func tryRefreshAccessToken() async -> Bool {
        if let inFlight = refreshInFlight {
            return await inFlight.value
        }
        let task = Task<Bool, Never> { [weak self] in
            guard let self else { return false }
            return await self.performRefresh()
        }
        refreshInFlight = task
        let ok = await task.value
        refreshInFlight = nil
        return ok
    }

    private func performRefresh() async -> Bool {
        guard let stored = keychain.getString(for: .refreshToken) else { return false }
        do {
            let pair = try await refreshToken(stored)
            try keychain.save(pair.accessToken, for: .accessToken)
            if let newRefresh = pair.refreshToken {
                try keychain.save(newRefresh, for: .refreshToken)
            }
            // The web shell holds a copy of the access token as a cookie; tell
            // it to take the new one.
            await MainActor.run {
                NotificationCenter.default.post(name: .pingolinAccessTokenRefreshed, object: nil)
            }
            return true
        } catch let err as APIError {
            #if DEBUG
            print("[Note] refreshToken: failed code=\(err.code) server=\"\(err.message)\"")
            #endif
            return false
        } catch {
            #if DEBUG
            print("[Note] refreshToken: failed err=\(error)")
            #endif
            return false
        }
    }
}

// MARK: - Models

struct EmptyResponse: Codable {}

/// Server envelope (matches android Dtos.kt):
/// `{ success: Bool, data: T?, error: String?, error_code: String? }`.
/// A gated 402 additionally carries a structured `quota` object (shared
/// subscription-gating contract) so a caller can route a specific cap —
/// e.g. attachment storage — to the Premium explainer.
struct APIResponse<T: Decodable>: Decodable {
    let success: Bool?
    let data: T?
    let error: String?
    let errorCode: String?
    let quota: QuotaErrorInfo?
}

/// Structured quota context attached to a gated 402 (the shared
/// gating contract). `resource` is the canonical enum (e.g.
/// `attachment_bytes`, `notes`); `isCountLimit` distinguishes a hard
/// count/byte cap from a boolean feature gate. Decoded via the API's
/// `.convertFromSnakeCase` strategy.
struct QuotaErrorInfo: Codable {
    let resource: String?
    let isCountLimit: Bool?
    let current: Int?
    let limit: Int?
    let tier: String?

    private enum CodingKeys: String, CodingKey {
        case resource, isCountLimit, current, limit, tier
    }

    /// Lenient decode. A present-but-partial `quota` object — a missing
    /// subfield, an explicit null, or a backend shape/type change on any
    /// single field — must NOT throw, because that throw would propagate out
    /// of the enclosing `APIResponse` decode and take down the whole
    /// structured 402: the caller would lose `error_code` + the human message
    /// and the Premium explainer would degrade to a generic error. `try?` per
    /// field tolerates keyNotFound, valueNotFound (null) AND typeMismatch — a
    /// bad or absent subfield just reads `nil`; the outer container
    /// acquisition is likewise non-throwing, so even a non-object `quota`
    /// yields all-nil rather than a thrown error.
    init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else {
            resource = nil; isCountLimit = nil; current = nil; limit = nil; tier = nil
            return
        }
        resource = try? c.decode(String.self, forKey: .resource)
        isCountLimit = try? c.decode(Bool.self, forKey: .isCountLimit)
        current = try? c.decode(Int.self, forKey: .current)
        limit = try? c.decode(Int.self, forKey: .limit)
        tier = try? c.decode(String.self, forKey: .tier)
    }
}

struct APIError: Codable, LocalizedError {
    /// Backend `error_code` when present (e.g. `quota_storage_exceeded`),
    /// else a synthesized `http_<status>` fallback.
    let code: String
    let message: String
    /// HTTP status when this came from an HTTP response, else nil.
    /// Lets callers detect e.g. a 409 conflict without depending on
    /// the backend's `error_code` string, which `code` prefers over
    /// the synthesized `http_<status>` fallback.
    var status: Int? = nil
    /// Structured quota context when the backend attached one to a 402
    /// (shared gating contract). `nil` for every non-quota error. Lets a
    /// caller match on the canonical `resource` (e.g. `attachment_bytes`)
    /// rather than only the `code` string.
    var quota: QuotaErrorInfo? = nil

    /// What `.localizedDescription` shows: `plainLine`, never `message`.
    ///
    /// No server `error` text ever reaches the screen (as in the Track iOS
    /// app): it can carry technical wording, or whatever a hacked server
    /// wants a person to read. `message` is for logs.
    var errorDescription: String? { plainLine }

    /// What a person is told about this failure, by its code and HTTP status
    /// (track-ios's words; the status first, so auth's 503
    /// `rate_limiter_unavailable` is trouble, not too many tries). A caller
    /// with something better to say about a code it knows says that instead.
    var plainLine: String {
        if let line = Self.lines[code] { return line }
        let s = status ?? 0
        if s == 402 || quota != nil || code.hasPrefix("quota_") || code.hasPrefix("premium_required") {
            return Self.planLimitText
        }
        if s == 429 { return Self.tooManyText }
        if s >= 500 { return Self.troubleText }
        if code.hasPrefix("rate_") { return Self.tooManyText }
        if code.hasPrefix("server_") { return Self.troubleText }
        if s == 403 || code.hasPrefix("auth_not_") || code == "auth_insufficient_permissions" {
            return Self.notAllowedText
        }
        if s == 404 || code.hasSuffix("_not_found") { return Self.goneText }
        return Self.failedText
    }

    static let failedText = "That didn't work. Please try again."
    static let unreachableText = "Pingolin couldn't be reached. Check your connection and try again."
    static let troubleText = "Pingolin is having trouble just now. Please try again in a moment."
    static let tooManyText = "Too many tries just now. Please wait a moment and try again."
    static let notAllowedText = "You don't have permission to do that."
    static let goneText = "That isn't there any more."
    static let planLimitText = "That's beyond what your plan includes."

    /// The failures this app raises itself, in its own words.
    private static let lines: [String: String] = [
        "network_error": unreachableText,
    ]

    /// A create whose client-supplied id already exists. Only reachable when
    /// the caller supplies one, which is the restore path — so a restore reads
    /// this as "already restored" rather than as a failure. The route answers a
    /// plain 409 deliberately (a 500 would confirm to another tenant that an id
    /// exists), so there is no error code to match on.
    var isAlreadyPresent: Bool { status == 409 }
}

struct SRPStep1Request: Encodable { let email: String }

struct SRPStep1Response: Codable {
    let salt: String
    let serverPublic: String
    let sessionId: String
    let bcryptSalt: String?
}

struct SRPStep2Request: Encodable {
    let sessionId: String
    let clientPublic: String
    let clientProof: String
}

/// Mirrors android Dtos.kt. Server returns the encrypted-key
/// bundle inline so the client doesn't need a follow-up /me round-trip.
/// iOS keeps `requires2fa` / `twoFactorToken` as iOS-only extras even
/// though android doesn't model them — the server sends them when 2FA
/// is enrolled, and the sign-in goes on to the challenge with them.
struct SRPStep2Response: Decodable {
    let serverProof: String?
    let user: User?
    let accessToken: String?
    let refreshToken: String?
    let kdfParams: KdfParamsResponse?
    let encryptedKeys: EncryptedKeysResponse?
    /// The account's public keys, at the top level of the reply (auth's
    /// `LoginResponse`); `encrypted_keys` carries only the sealed blobs.
    let sharingPublicKey: String?
    let signingPublicKey: String?
    let twoFactorToken: String?
    let requires2fa: Bool?
    /// The second-step methods the challenge accepts, e.g. ["totp"],
    /// ["totp", "passkey"] or ["passkey"]. This app can only answer "totp"
    /// (a 6-digit code). nil — a server that lists no methods — is
    /// treated as TOTP.
    var availableMethods: [String]? = nil
}

extension SRPStep2Response {
    /// Decoded by hand because of ONE key, `requires_2fa`. Under the wire
    /// decoder's `.convertFromSnakeCase`, a key component that starts with a
    /// digit converts differently across Foundation versions: `requires2fa`
    /// before iOS 26, `requires2Fa` on iOS 26 ("2fa" is capitalised to "2Fa").
    /// The synthesised `requires2fa` would therefore decode as nil on iOS 26,
    /// the challenge would go unnoticed, and every 2FA sign-in would fail as
    /// "no access token". So the flag is read under whichever spelling the
    /// runtime produced; every other field keeps the key synthesis would have
    /// given it.
    private enum Field: String, CodingKey {
        case serverProof, user, accessToken, refreshToken, kdfParams, encryptedKeys,
             sharingPublicKey, signingPublicKey, twoFactorToken, availableMethods
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        serverProof = try c.decodeIfPresent(String.self, forKey: .serverProof)
        user = try c.decodeIfPresent(User.self, forKey: .user)
        accessToken = try c.decodeIfPresent(String.self, forKey: .accessToken)
        refreshToken = try c.decodeIfPresent(String.self, forKey: .refreshToken)
        kdfParams = try c.decodeIfPresent(KdfParamsResponse.self, forKey: .kdfParams)
        encryptedKeys = try c.decodeIfPresent(EncryptedKeysResponse.self, forKey: .encryptedKeys)
        sharingPublicKey = try c.decodeIfPresent(String.self, forKey: .sharingPublicKey)
        signingPublicKey = try c.decodeIfPresent(String.self, forKey: .signingPublicKey)
        twoFactorToken = try c.decodeIfPresent(String.self, forKey: .twoFactorToken)
        availableMethods = try c.decodeIfPresent([String].self, forKey: .availableMethods)

        let any = try decoder.container(keyedBy: WireKey.self)
        let flag = any.allKeys.first { $0.stringValue.lowercased() == "requires2fa" }
        requires2fa = try flag.flatMap { try any.decodeIfPresent(Bool.self, forKey: $0) }
    }
}

/// A key of any name, for a field whose converted name varies by runtime.
private struct WireKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

extension Notification.Name {
    /// APIService stored a freshly refreshed access token.
    static let pingolinAccessTokenRefreshed = Notification.Name("pingolinAccessTokenRefreshed")
}

struct Verify2FARequest: Encodable {
    /// Serialises as `two_factor_token` under .convertToSnakeCase. The server
    /// wants exactly this name; any other key (`temp_token`, say) is ignored
    /// and the request fails as a missing field.
    let twoFactorToken: String
    let code: String
    /// "totp" or "passkey". This is the code-entry path, so totp.
    let method: String
}

/// The server answers `/auth/login/2fa` with the same `LoginResponse` a
/// password-only sign-in gets, so everything needed to derive the vault key is
/// here and the 2FA path is not a second-class login.
struct Login2FAResponse: Decodable {
    let user: User
    let kdfParams: KdfParamsResponse
    let encryptedKeys: EncryptedKeysResponse
    /// Top level, as on SRP step 2.
    let sharingPublicKey: String?
    let signingPublicKey: String?
    let accessToken: String
    let refreshToken: String?
}

/// Reply to the authenticated SRP step-up. Mirrors track-ios.
struct ReauthStep2Response: Codable {
    /// Server's SRP proof M2, checked before the token is used; a reply
    /// without one is refused.
    let serverProof: String?
    /// Short-lived token the client hands to DELETE /api/v1/auth/me in place
    /// of the password. Required — its absence is an error.
    let reauthToken: String
}

struct DeleteAccountRequest: Encodable {
    /// Short-lived SRP step-up token (`reauth_token` on the wire via the
    /// encoder's convertToSnakeCase). Sent in place of the raw password so the
    /// plaintext credential never leaves the device on delete.
    let reauthToken: String?
    /// Legacy raw-password field, optional because the server may still
    /// accept it in place of a `reauth_token`. The reauth path leaves it
    /// nil and the synthesized Encodable omits nil optionals
    /// (encodeIfPresent), so no `password` key is emitted at all.
    let password: String?

    /// The user's explicit answer to the 409 the server returns when the account
    /// still holds credit it paid for. Deleting destroys it — the record goes
    /// with the account — so the server refuses the first attempt rather than
    /// doing it quietly. nil on a first attempt, and nil optionals are omitted.
    let forfeitCreditBalance: Bool?

    init(reauthToken: String? = nil, password: String? = nil, forfeitCreditBalance: Bool? = nil) {
        self.reauthToken = reauthToken
        self.password = password
        self.forfeitCreditBalance = forfeitCreditBalance
    }
}

/// What deleting the account did to the user's billing.
///
/// The server cancels every subscription it can reach. Two it cannot, and both
/// leave money moving after the account is gone:
///   - an App Store subscription, which only the customer can stop, in their
///     Apple account settings — Apple offers no server-side call
///   - a cancellation that failed at the provider, which deliberately does not
///     block the deletion, because erasure is a right and a payment API outage
///     is not a reason to refuse it
///
/// Defaults are present on every field but `deleted` so a build running against
/// an older backend decodes rather than throwing — a delete that succeeded must
/// never surface as a failure because the response gained a field.
struct DeleteAccountResponse: Codable {
    let deleted: Bool
    let subscriptionsCanceled: Int
    let appStoreSubscriptionsRemaining: Int
    let subscriptionCancellationsFailed: Int
    /// What happened to the location and note data: "completed",
    /// "not_applicable", "queued" or "failed" — told to the person after
    /// the deletion. Defaulted rather than required so an older backend
    /// decodes.
    let dataErasure: String
    /// Key off this rather than re-deriving it from the counts.
    let billingNeedsAttention: Bool

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deleted = try c.decode(Bool.self, forKey: .deleted)
        subscriptionsCanceled = try c.decodeIfPresent(Int.self, forKey: .subscriptionsCanceled) ?? 0
        dataErasure = try c.decodeIfPresent(String.self, forKey: .dataErasure) ?? "completed"
        appStoreSubscriptionsRemaining = try c.decodeIfPresent(Int.self, forKey: .appStoreSubscriptionsRemaining) ?? 0
        subscriptionCancellationsFailed = try c.decodeIfPresent(Int.self, forKey: .subscriptionCancellationsFailed) ?? 0
        billingNeedsAttention = try c.decodeIfPresent(Bool.self, forKey: .billingNeedsAttention) ?? false
    }
}

struct UpdateMeRequest: Encodable {
    let displayName: String
}

/// The whole of what `PATCH /api/v1/auth/me` returns:
/// `{ "display_name": string | null }`.
///
/// Its own type on purpose. `MeResponse` is the GET's shape and requires `id`
/// and `email`, neither of which this route sends — so reusing it here fails
/// on a reply that reports success. Optional `displayName` because the
/// server's field is nullable and clearing a name PATCHes null.
struct UpdateDisplayNameResponse: Decodable {
    let displayName: String?
}

/// What `/billing/apple/link` returns. Only `status` is read — the call is
/// made for its effect, and the tier the client actually shows comes from
/// `QuotaManager`, never from this.
struct AppleLinkResponse: Decodable {
    let status: String
}

/// The answer to "may this account start an App Store purchase for this
/// product", from the auth server's GET /api/v1/billing/apple/eligibility.
///
/// Asked BEFORE the purchase sheet, because it cannot be enforced afterwards:
/// once StoreKit completes, Apple has taken the money, and the server refusing
/// to record it would leave the customer charged with nothing. The server fails
/// closed, and so must the caller — a transport error means "do not sell", never
/// a default yes.
struct ApplePurchaseEligibility: Decodable {
    let canPurchase: Bool
    /// The server's copy for a refusal. Never shown: PremiumSheet drops it
    /// (`kept`) and says the refusal in this app's words. This app sets its
    /// own reason only for a check that failed.
    let reason: String?
    /// Which provider the blocking subscription is on. `"apple"` never blocks —
    /// StoreKit surfaces that as a restore rather than a second purchase.
    let existingProvider: String?
}

/// Mirrors the server's quota usage and android QuotaDto. Sizes are in bytes;
/// `maxNotes` of -1 means unlimited, and `remainingNotes` is `Int.max` for
/// unlimited — callers must check `tier == "paid"` rather than treating the
/// literal as a count.
struct QuotaDto: Decodable {
    let tier: String
    let maxNotes: Int
    let currentNotes: Int
    let remainingNotes: Int
    let maxAttachmentBytes: Int
    let currentAttachmentBytes: Int
    let remainingAttachmentBytes: Int
    let sharingEnabled: Bool
    let remindersEnabled: Bool
}

struct AttestationStatusResponse: Decodable {
    let appleAttestEnabled: Bool
    let googleIntegrityEnabled: Bool
    let androidKeystoreEnabled: Bool
    let turnstileEnabled: Bool
}

struct AttestationChallengeResponse: Decodable {
    let challenge: String
    /// Server-echoed platform identifier — should be "apple" for iOS.
    let method: String
    /// RFC3339 expiry of the challenge nonce.
    let expiresAt: String
}

struct AppleAttestVerifyRequest: Encodable {
    /// Base64-encoded attestation object from DCAppAttestService.
    let attestation: String
    let challenge: String
    let keyId: String
}

struct AttestationVerifyResponse: Decodable {
    let attestationToken: String
    let platform: String
    let expiresAt: String
}

struct TokenPairResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
}

struct User: Codable {
    let id: String
    let email: String
    let displayName: String?
    /// Proton-style recovery address, carried through from `/auth/me` so
    /// Settings can report its state without a second call.
    ///
    /// Both optional, and both must stay optional: the `User` rebuilt from the
    /// keychain on an offline launch, and the one built from the SRP step2
    /// response at login, know neither. A nil `recoveryEmailVerified` is what
    /// `RecoveryEmailStatus.resolve` reads as "we have not asked yet" rather
    /// than "there is not one".
    var recoveryEmail: String?
    var recoveryEmailVerified: Bool?
    /// True when a guardian set this account up and still holds its password.
    ///
    /// Optional and defaulting to nil for the same reason as the two above: the
    /// User rebuilt from the keychain on an offline launch does not know, and
    /// nil must read as "we have not asked" rather than "no". The disclosure is
    /// shown only on an explicit true.
    var guardianManaged: Bool?
}

struct MeResponse: Decodable {
    let id: String
    let email: String
    let displayName: String?
    let emailVerified: Bool?
    let status: String?
    /// The auth server's `recovery_email` / `recovery_email_verified`, mapped
    /// by the decoder's `.convertFromSnakeCase`. `recovery_email` is absent for
    /// an account that has none; `recovery_email_verified` is always sent, so
    /// it is optional here only to tolerate a server that omits the field.
    let recoveryEmail: String?
    let recoveryEmailVerified: Bool?
    // No key material: sign-in takes the keys from the SRP step-2 / 2FA
    // reply, and /me's password-wrapped master key is not relied on. This
    // type does not decode it, so nothing can fall back to it.
    /// True when somebody else set this account up and still holds its password
    /// — a guardian holding a young person's account.
    ///
    /// Drives a standing disclosure, because nothing else tells that person
    /// their notes are readable: sharing location is announced by iOS itself, a
    /// read produces no signal, and there is no new-sign-in email. Optional so
    /// a server that omits the field still decodes, and read as false when
    /// absent — showing a claim we cannot substantiate would be worse than
    /// showing nothing.
    let guardianManaged: Bool?
}

struct EncryptedKeysResponse: Decodable {
    let masterKey: EncryptedBlobResponse
    /// Optional on the wire, but a sign-in whose reply lacks it opens no
    /// keys: the vault key derives from the sharing key, and a session can't
    /// open a share without it. Only the same account then goes on with the
    /// keys it holds.
    let sharingPrivateKey: EncryptedBlobResponse?
    let signingPrivateKey: EncryptedBlobResponse?
    let sharingPublicKey: String?
    let signingPublicKey: String?

    init(
        masterKey: EncryptedBlobResponse,
        sharingPrivateKey: EncryptedBlobResponse?,
        signingPrivateKey: EncryptedBlobResponse?,
        sharingPublicKey: String?,
        signingPublicKey: String?
    ) {
        self.masterKey = masterKey
        self.sharingPrivateKey = sharingPrivateKey
        self.signingPrivateKey = signingPrivateKey
        self.sharingPublicKey = sharingPublicKey
        self.signingPublicKey = signingPublicKey
    }
}

struct EncryptedBlobResponse: Decodable {
    let nonce: String
    let ciphertext: String
}

struct KdfParamsResponse: Decodable {
    let salt: String
    let memoryKib: Int
    let iterations: Int
    let parallelism: Int
}

enum ItemType: Int, Codable {
    case note = 1
    case notebook = 2
    case label = 3
    /// The single per-user encrypted metadata blob (the server allows item
    /// types 1/2/3/10; note-android's `ItemDao` calls this one "The single
    /// user-metadata item (item_type = 10)"). Declared so these rows decode to
    /// a known type instead of `type == nil`, which would be indistinguishable
    /// from a genuinely unknown future type.
    case metadata = 10
}

struct Item: Codable, Identifiable {
    let id: String
    let userId: String
    let itemType: Int
    let encryptedContent: String
    let contentNonce: String
    let version: Int64
    let createdAt: Date
    let updatedAt: Date
    let deleted: Bool
    let deletedAt: Date?
    let circleId: String?
    let contentSize: Int
    let notebookId: String?
    let wrappedContentKey: String?
    let wrappedContentKeyNonce: String?
    /// Server-computed: THIS user has shared the item with someone. Drives the
    /// "Shared" badge without an N+1 of per-note share lookups.
    ///
    /// OPTIONAL on purpose, and not merely for tidiness: `.convertFromSnakeCase`
    /// maps `shared_by_me` automatically, but Swift's Codable THROWS on a
    /// missing non-optional key. A non-optional `Bool` here would fail to
    /// decode every item from any server that omits the field — turning a
    /// cosmetic badge into a total sync failure. Read it as `?? false`.
    /// `var` with a default, unlike its `let` neighbours, purely so the
    /// memberwise initializer keeps a default: a `let` optional gets NO
    /// implicit `nil` default, which would force the argument on every
    /// `Item(...)` call site for a field none of them know about.
    var sharedByMe: Bool? = nil
    /// Monotonic per-item content-key generation
    /// (`.convertFromSnakeCase` maps `content_key_generation`). The
    /// share signer binds it into the wrap signature — share-create
    /// under this value, rotate under this value + 1. `nil`/base 1 for
    /// rows from before generations existed.
    let contentKeyGeneration: Int64?

    var type: ItemType? { ItemType(rawValue: itemType) }
}

struct SyncResponse: Decodable {
    let items: [Item]
    let cursor: String?
    /// Tie-breaker paired with `cursor`: the id of the last item in the page.
    /// Echoed back as `since_id` so same-`updated_at` notes split across a page
    /// boundary are neither skipped nor re-sent. Decoded from `cursor_id` via
    /// the API's `.convertFromSnakeCase` strategy (no CodingKeys needed);
    /// absent from older backends → nil → safe fallback to `updated_at > since`.
    let cursorId: String?
    let hasMore: Bool
}

/// The accumulated result of a full/delta `/sync/pull` scan:
/// every gathered item, plus the server's newest keyset cursor so the caller can
/// persist a watermark and resume incrementally next time. `cursor` is nil only
/// when the scan neither started from nor produced a cursor (a single-page vault),
/// which is cheap to re-scan in full, so there's nothing to persist.
struct SyncPage {
    let items: [Item]
    let cursor: String?
    let cursorId: String?
}

struct CreateItemRequest: Encodable {
    var id: String? = nil
    let itemType: Int
    let encryptedContent: String
    let contentNonce: String
    var circleId: String? = nil
    var notebookId: String? = nil
    var wrappedContentKey: String? = nil
    var wrappedContentKeyNonce: String? = nil
}

/// Mirrors android Dtos.kt. `expectedVersion` is the version the
/// client thinks the server has; if it doesn't match the server rejects
/// with a 409 so the client can pull-then-merge before retrying.
struct UpdateItemRequest: Encodable {
    let encryptedContent: String
    let contentNonce: String
    var notebookId: String? = nil
    var wrappedContentKey: String? = nil
    var wrappedContentKeyNonce: String? = nil
    var expectedVersion: Int64? = nil
}

struct EmptyBody: Encodable {}

/// Body of `POST /auth/logout`. A nil token is left out.
struct LogoutRequest: Encodable {
    let refreshToken: String?
}

struct PublicKeyLookupRequest: Encodable {
    let emails: [String]
}

struct PublicKeyLookupResponse: Decodable {
    let users: [PublicKeyLookupEntry]
}

struct PublicKeyLookupEntry: Decodable {
    let email: String
    let userId: String?
    let sharingPublicKey: String?
    let signingPublicKey: String?
}

struct InboxShareResponse: Decodable, Identifiable {
    let shareId: String
    let itemId: String
    let ownerId: String
    let permission: String
    let wrappedKey: String?
    let sharerPublicKey: String?
    let ownerEmail: String?
    let wrapSignature: String?
    let encryptedContent: String
    let contentNonce: String
    let updatedAt: Date
    let createdAt: Date
    /// Monotonic per-item content-key generation. `.convertFromSnakeCase`
    /// maps `content_key_generation`. Threaded into wrap verify-both: a
    /// signature made under the real generation validates, while
    /// `nil`/absent (rows from before generations, an older server) is
    /// treated as 1 and the SDK still falls back to legacy gen 0.
    let contentKeyGeneration: Int64?
    /// What KIND of item was shared: 1 = note, 2 = notebook.
    ///
    /// Optional because an older server omits it — and Swift's `Decodable`
    /// THROWS on a missing non-optional key, which would fail the whole inbox
    /// decode rather than one field. Absent means note, which is what every
    /// client assumed before the field existed.
    let itemType: Int?

    /// The item type, treating an absent one as a note.
    var itemTypeOrNote: Int { itemType ?? 1 }
    var isNotebook: Bool { itemTypeOrNote == 2 }

    var id: String { shareId }
}

struct BlockSenderRequest: Encodable {
    let email: String
}

/// One blocked sender: the blocked email + when it was blocked.
/// `.convertFromSnakeCase` maps `blocked_email`/`created_at`; the
/// timestamp decodes via the shared `.iso8601` date strategy.
struct BlockedSenderDto: Decodable, Identifiable {
    let blockedEmail: String
    let createdAt: Date
    var id: String { blockedEmail }
}

struct AcquireLockRequest: Encodable {
    let displayName: String
}

struct LockRecordDto: Decodable {
    let holderUserId: String
    let holderDisplayName: String
    let acquiredAt: String
    let expiresAt: String
}

struct ReminderDto: Decodable, Identifiable {
    let id: String
    let itemId: String
    let triggerAt: String
    let repeatRule: String?
    let fired: Bool
    let dismissed: Bool
}

struct CreateReminderRequest: Encodable {
    let itemId: String
    let triggerAt: String
    var repeatRule: String? = nil
    var encryptedDetails: String? = nil
    var detailsNonce: String? = nil
}

struct APNsRegisterRequest: Encodable {
    let deviceId: String
    let apnsToken: String
    let bundleId: String
    let appVersion: String?
}

struct APNsUnregisterRequest: Encodable {
    let deviceId: String
}


// MARK: - Identities from before a password reset

/// A recovered pre-reset private key, sealed for this app by the account portal.
///
/// The portal's own copy is wrapped under the auth MASTER key, which this app
/// never holds — so it seals a second copy under a value the SDK derives from
/// the key we already have. Absent when the recovery predates that.
struct SealedPreviousIdentityResponse: Codable {
    let nonce: String
    let ciphertext: String
}

/// No explicit CodingKeys, on purpose. The wire decoder runs
/// `.convertFromSnakeCase`, which converts the JSON keys BEFORE matching, so
/// snake_case CodingKeys ("key_version", "app_sealed_private_key") could
/// never match: an empty list would decode, every non-empty one would throw,
/// `PreviousIdentityLoader` would import nothing, and notes from before a
/// reset would stay locked on iOS even after a restore in the account
/// portal.
struct PreviousIdentityResponse: Codable {
    let keyVersion: Int
    let appSealedPrivateKey: SealedPreviousIdentityResponse?
    /// The v2 blob. Only counted for the log here; this app imports v1.
    var appSealedPrivateKeyV2: SealedPreviousIdentityResponse? = nil
}

struct PreviousIdentitiesResponse: Codable {
    let identities: [PreviousIdentityResponse]
}
