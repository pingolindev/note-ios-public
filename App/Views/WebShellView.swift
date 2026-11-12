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

import CryptoKit
import SwiftUI
import WebKit

/// The single-store shell: the deployed web app (the note origin) IS the
/// note UI, presented in one retained WKWebView. Mirrors note-android's
/// `WebAppActivity` — same `pingolin-close` / `pingolin-settings` /
/// `pingolin-signout` scheme contract, same `pingolinNudge` / `pingolinSave`
/// message channels.
///
/// Divergences from Android, all deliberate:
///  - No back contract. `__pingolinBack` exists for a system back BUTTON;
///    iOS has none. In-page history still works via the edge-swipe gesture.
///  - The page comes from the network. Android serves it from the APK via
///    `shouldInterceptRequest`; WKWebView cannot intercept https (a
///    WKURLSchemeHandler may not claim it), and a custom-scheme origin would
///    make every API call and the collab WebSocket cross-origin, losing the
///    same-site cookie session and the service worker. Because the page is
///    whatever the server returns when it loads, it is NOT given the private
///    keys: the handoff carries the vault key and the public keys only, and
///    `WebKeyBridge` performs the private-key operations natively.
///  - No service worker. The web editor registers none in this shell, and
///    the shell removes any registration at launch, before the first load
///    (`removeServiceWorkersOnce`): a worker's own fetches belong to no page,
///    both the document and assets it serves and its update, so the editor's
///    leaked-key check would never see them. A cold start with no network
///    shows the retry view; a warm shell keeps working offline because the
///    document is already loaded.
///  - Its WebKit data is kept out of backups, and the page holds only a
///    short-lived access-token cookie (`WebShellDataStore`, `seedCookies`).
final class WebShellModel: NSObject, ObservableObject {
    static let shared = WebShellModel()

    @Published var showSignOutConfirm = false
    @Published var showSettings = false
    /// Which native group the page asked for, from `?section=`. nil means the
    /// whole screen — which is what the failure view uses, since a person
    /// whose page will not load needs everything, not one group.
    @Published var settingsSection: String?
    @Published var showPremium = false
    /// Which cap the page says the person just hit, from `?focus=`. nil is the
    /// generic sheet.
    @Published var premiumFocus: PremiumSheet.Focus?
    @Published var shareFileURL: URL?
    @Published var loadFailed = false
    /// The JavaScript dialog the page is currently blocked on, if any.
    /// See `JSDialogRequest` and the `WKUIDelegate` panel methods below.
    @Published var jsDialog: JSDialogRequest?

    private(set) var webView: WKWebView?
    /// Published so RootView can hold the opening splash over the shell until
    /// the page has actually painted, instead of leaving the user looking at a
    /// BLANK WKWebView for the whole web boot. Still only this class may set
    /// it.
    @Published private(set) var pageReady = false
    private var pendingPath: String?
    private var lastNudgeAt: TimeInterval = 0
    /// Matches Android's NUDGE_MIN_INTERVAL_MS: the page nudges on every
    /// mutation; native sync needs at most one kick per burst.
    private let nudgeMinInterval: TimeInterval = 5

    private var origin: String { AppConfiguration.shared.webBaseURL }

    /// Starts the session's refresh at the first foreground signal.
    private var foregroundRefresh: ForegroundRefreshTrigger?
    /// Refreshes a stale session when the network is back, and every 30 s
    /// while it stays stale in the foreground.
    private var catchUp: SessionCatchUp?
    /// The token the page was last given (a digest), so each new one reaches
    /// it once.
    private var seeded = SeededToken()

    private override init() {
        super.init()
        // Back in the foreground, the session's refresh starts at the FIRST
        // signal of it, before the app is active (`ForegroundRefreshTrigger`).
        foregroundRefresh = ForegroundRefreshTrigger { [weak self] in self?.startForegroundRefresh() }
        catchUp = SessionCatchUp(hooks: .init(
            isStale: { SessionCatchUp.isStale(KeychainService.shared.getString(for: .accessToken)) },
            isForeground: { MainActor.assumeIsolated { UIApplication.shared.applicationState != .background } },
            expiry: { KeychainService.shared.getString(for: .accessToken).flatMap(APIService.accessTokenExpiry) },
            now: { Date() },
            stamp: { AuthManager.SessionStamp.current() },
            refresh: { await APIService.shared.refreshAccessTokenIfExpiring(within: 120) },
            reseed: { [weak self] in await self?.reseedIfBehind() },
            refused: { stamp in
                MainActor.assumeIsolated { AuthManager.shared.expireSessionRefusedByServer(since: stamp) }
            },
            schedule: SessionCatchUp.mainRunLoopOnce
        ))
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshDeviceSnapshot),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        // The page's `auth_token` cookie is a copy of the native access token;
        // when native refreshes it, the page's copy must follow (the page
        // holds no refresh token to do it itself).
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reseedCookies),
            name: .pingolinAccessTokenRefreshed,
            object: nil
        )
    }

    // MARK: - WebView lifecycle

    /// Build (or return) the retained WKWebView. Recreated only after
    /// `teardown()` — i.e. once per authenticated session — so navigation
    /// state, the decrypted document and the page's caches all survive
    /// SwiftUI view churn.
    @MainActor
    func ensureWebView() -> WKWebView {
        if let webView { return webView }

        // No keys, no page. The page cannot open a note without the vault
        // key, nothing shared with this account opens without the sharing
        // key, and a keyless page would mint a throwaway vault key. Only a
        // sign-in derives them — so end this session (the tokens only; the
        // offline outbox is kept, as on any expiry) and let RootView show the
        // sign-in screen with the reason. The view returned meanwhile loads
        // nothing.
        guard let keyScript = WebAppKeyHandoff.buildScript(
            keys: WebAppKeyHandoff.collectKeys(), origin: origin
        ) else {
            Task { @MainActor in AuthManager.shared.expireSessionForMissingKeys() }
            let inert = WKWebViewConfiguration()
            inert.websiteDataStore = .nonPersistent()
            return WKWebView(frame: .zero, configuration: inert)
        }

        let controller = WKUserContentController()
        controller.add(self, name: "pingolinNudge")
        controller.add(self, name: "pingolinSave")
        controller.addUserScript(WKUserScript(
            source: WebAppDeviceState.buildScript(
                device: WebAppDeviceState.from(AppConfiguration.shared),
                origin: origin,
                onLoad: true
            ),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        controller.addUserScript(WKUserScript(
            source: markerScript(),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        // The key handoff: the vault key and the two PUBLIC keys, plus the
        // `__pingolinKeyBridge` marker. The private keys stay in the Keychain;
        // the page asks WebKeyBridge for the operations that need them.
        controller.addUserScript(WKUserScript(
            source: keyScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        controller.addScriptMessageHandler(
            WebKeyBridgeHandler(origin: origin),
            contentWorld: .page,
            name: WebKeyBridge.handlerName
        )

        let config = WKWebViewConfiguration()
        config.userContentController = controller
        // The default store, kept out of backups and never cleared on update —
        // it holds any edit the page has not synced yet (WebShellDataStore).
        config.websiteDataStore = WebShellDataStore.store()
        config.allowsInlineMediaPlayback = true
        // Opt into App-Bound Domains (the list is WKAppBoundDomains in
        // Info.plist). WebKit disables service workers in a WKWebView that has
        // not opted in — `navigator.serviceWorker` is absent, not merely
        // inert. The shell keeps no service worker
        // (`removeServiceWorkersOnce`); this opt-in is independent of that.
        //
        // What it costs: user scripts and the pingolinNudge/pingolinSave
        // message handlers work only on app-bound domains (the note origin is
        // one), and a main-frame navigation off the list fails rather than
        // loads. decidePolicyFor already sends those to Safari and cancels,
        // so every page the shell allows in-view stays reachable — the portal
        // is listed.
        config.limitsNavigationsToAppBoundDomains = true

        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true
        #if DEBUG
        if #available(iOS 16.4, *) { web.isInspectable = true }
        #endif

        webView = web
        pageReady = false
        Task { @MainActor [weak self] in
            await self?.removeServiceWorkersOnce()
            await self?.holdFirstLoadForTheLaunchRefresh()
        }
        return web
    }

    /// The end of a session as RootView sees it. An expiry keeps the page's
    /// website data for the same account, after the page's last keep of its
    /// kept trust — run FIRST, while the outgoing account's `.userId` and
    /// sharing key are still there for the bridge (expireSession deletes
    /// neither). Every other end wipes it; a sign-out's last keep ran at the
    /// start of logout().
    @MainActor
    func endSession(keepData: Bool) async {
        if keepData { _ = await keepTrustNow() }
        teardown(keepData: keepData)
    }

    /// The page's last keep (`window.__pingolinKeepTrustNow`), bounded:
    /// true when the page says the shell kept its trust. No web view, no page
    /// or no hook (an older page) returns at once; a page that never answers
    /// is cut at `timeout`.
    @MainActor
    func keepTrustNow(timeout: Double = 1) async -> Bool {
        guard let webView else { return false }
        return await Self.bounded(timeout) {
            let kept = try? await webView.callAsyncJavaScript(
                "return await (typeof window.__pingolinKeepTrustNow === 'function'"
                    + " ? window.__pingolinKeepTrustNow() : false);",
                arguments: [:], in: nil, contentWorld: .page
            )
            return (kept as? Bool) == true
        }
    }

    /// `work`'s answer, or false once `seconds` have passed, whichever is
    /// first. Not a task group: a group waits for every child, and a script
    /// call can't be cancelled, so a group would wait as long as the page did.
    static func bounded(_ seconds: Double, _ work: @escaping @MainActor () async -> Bool) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = ResumeOnce(continuation)
            Task { @MainActor in once.resume(await work()) }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                once.resume(false)
            }
        }
    }

    /// Resumes its continuation exactly once, from whichever side gets there first.
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?
        init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
        func resume(_ value: Bool) {
            lock.lock()
            let c = continuation
            continuation = nil
            lock.unlock()
            c?.resume(returning: value)
        }
    }

    /// Destroy the shell and, unless `keepData`, everything the page persisted.
    /// Called whenever the session ends — from the shell's own sign-out AND
    /// from native Settings' logout (RootView watches `isAuthenticated`) —
    /// because the WebView's storage holds decrypted note content and the
    /// sessionStorage key handoff. The keychain wipe alone does not touch
    /// either. `keepData` only after an expiry (endSession): that data stays
    /// with the `.userId` the expiry keeps, and a different account's sign-in
    /// empties it before its page loads (AuthManager's switch).
    @MainActor
    func teardown(keepData: Bool = false) {
        webView?.stopLoading()
        webView?.configuration.userContentController.removeAllUserScripts()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "pingolinNudge")
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "pingolinSave")
        webView?.configuration.userContentController.removeScriptMessageHandler(
            forName: WebKeyBridge.handlerName, contentWorld: .page
        )
        webView = nil
        pageReady = false
        pendingPath = nil
        tokenRefreshTimer?.invalidate()
        tokenRefreshTimer = nil
        catchUp?.stop()
        seeded.forget()
        seeding = nil
        if !keepData { WebShellDataStore.wipe() }
    }

    func loadHome() {
        loadFailed = false
        if let url = URL(string: origin) {
            webView?.load(URLRequest(url: url))
        }
    }

    /// SPA-navigate the page (deep links, push taps). Uses the page's
    /// `__pingolinNavigate` hook so the document is not torn down; queued
    /// until the first load finishes when the shell is still booting.
    func navigate(to path: String) {
        guard pageReady, let webView else {
            pendingPath = path
            return
        }
        let js = "(function(){var n=window.__pingolinNavigate;" +
            "if(typeof n==='function'){n('\(path)');return true;}return false;})();"
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            // The hook is defined by the deployed page; an older deploy
            // falls back to a plain load of the same path.
            if (result as? Bool) != true {
                if let url = URL(string: (self?.origin ?? "") + path) {
                    webView.load(URLRequest(url: url))
                }
            }
        }
    }

    // MARK: - Cookie bridge

    /// Fires shortly before the seeded access token expires, so a page left
    /// open outlives its token without ever seeing a 401.
    private var tokenRefreshTimer: Timer?

    /// Give the page this session's ACCESS token, as the `auth_token` cookie
    /// the auth server itself sets (`HttpOnly; Secure; SameSite=Lax; Path=/`,
    /// Max-Age = the token's own remaining lifetime). They are the SAME
    /// credential — the auth server puts the JWT native login holds into
    /// `auth_token` for the web — so no second login is needed.
    ///
    /// The REFRESH token is never given to the page: a 30-day cookie in a
    /// backup-eligible store would ride every backup. Native refreshes
    /// instead — before seeding, on a timer ahead of expiry, and whenever
    /// APIService refreshes on a 401 — and re-seeds the short-lived access
    /// token. Any `refresh_token` cookie in the store (an earlier build's, or
    /// one the portal set during an in-shell sign-in) is deleted.
    ///
    /// `refreshFirst: false` when the caller has already settled the refresh
    /// (the first load, the foreground). `keepExpired` seeds an expired token
    /// too: the first load never goes out with NO cookie while a session is
    /// stored (`cookieLifetime`).
    @MainActor
    func seedCookies(refreshFirst: Bool = true, keepExpired: Bool = false) async {
        if refreshFirst { await APIService.shared.refreshAccessTokenIfExpiring(within: 120) }
        // One seed at a time, in the order asked. Each reads the Keychain's
        // token when its turn comes, so the last one seeded is the newest, and
        // a slow seed can't land an older token after a newer one, or empty
        // the jar under it.
        let previous = seeding
        let mine = Task { @MainActor [weak self] in
            // A seed stuck on the cookie store holds the next one back at most
            // `seedQueueWait`, and none past a sign-out (teardown lets go).
            if let previous {
                _ = await WebShellModel.settled(within: WebShellModel.seedQueueWait) { await previous.value }
            }
            await self?.seedNow(keepExpired: keepExpired)
        }
        seeding = mine
        await mine.value
    }

    /// The seed in progress, which the next one waits for (`seedCookies`).
    private var seeding: Task<Void, Never>?
    /// How long a seed waits for the one before it.
    static let seedQueueWait: Double = 5

    /// The one seed whose turn it is.
    @MainActor
    private func seedNow(keepExpired: Bool) async {
        // However this ends, a token still stale keeps the catch-up retrying
        // (`SessionCatchUp`); a fresh one stops it.
        defer { catchUp?.evaluate() }
        guard let access = KeychainService.shared.getString(for: .accessToken),
              let url = URL(string: origin) else { return }
        // Never an older token over a newer one (by `iat`).
        guard !seeded.isOlder(access) else { return }
        let dataStore = WebShellDataStore.store()
        if !cookieJarReset {
            await Self.resetCookieJar(dataStore)
            cookieJarReset = true
        }
        let store = dataStore.httpCookieStore
        for cookie in await store.allCookies() where cookie.name == "refresh_token" {
            await store.deleteCookie(cookie)
        }
        let expiry = APIService.accessTokenExpiry(access)
        guard let lifetime = Self.cookieLifetime(expiry: expiry, keepExpired: keepExpired),
              let cookie = Self.authCookie(token: access, domain: Self.cookieDomain(for: origin),
                                           url: url, maxAge: lifetime)
        else { return }
        await store.setCookie(cookie)
        // A seed held past `seedQueueWait` can finish after a newer one. If a
        // newer token was recorded meanwhile, this one has just written over
        // it: the Keychain's token is seeded again.
        guard !seeded.isOlder(access) else {
            Task { @MainActor [weak self] in await self?.seedCookies(refreshFirst: false) }
            return
        }
        seeded.record(access)
        scheduleTokenRefresh(before: expiry)
    }

    /// The page's copy follows the Keychain's token: re-seeded when the token
    /// there is newer than the one the page was last given, once per token.
    @MainActor
    func reseedIfBehind() async {
        guard webView != nil, seeded.isBehind(KeychainService.shared.getString(for: .accessToken)) else { return }
        await seedCookies(refreshFirst: false)
    }

    /// The cookie's Max-Age: the token's own remaining life; the fallback when
    /// its expiry can't be read, or when an expired token is kept
    /// (`keepExpired`; the next refresh re-seeds it). nil, no cookie, for an
    /// expired token otherwise.
    static func cookieLifetime(expiry: Date?, keepExpired: Bool, now: Date = Date()) -> Int? {
        guard let expiry else { return authCookieFallbackMaxAge }
        let left = Int(expiry.timeIntervalSince(now))
        if left > 0 { return left }
        return keepExpired ? authCookieFallbackMaxAge : nil
    }

    /// How long the first load waits for the launch's refresh, and the pause
    /// before that refresh's one retry.
    static let firstLoadWait: Double = 5
    static let firstLoadRetryPause: Double = 0.5

    /// The first load waits for the launch's refresh to settle, as the
    /// Android shell does: the page asks `/auth/me` with the cookie it is
    /// given, and a dead copy of the access token there reads as a sign-out.
    @MainActor
    func holdFirstLoadForTheLaunchRefresh() async {
        let stamp = AuthManager.SessionStamp.current()
        await Self.firstLoad(
            wait: Self.firstLoadWait,
            refresh: { await APIService.shared.refreshAccessTokenIfExpiring(within: 120) },
            refused: { AuthManager.shared.expireSessionRefusedByServer(since: stamp) },
            seed: { [weak self] in await self?.seedCookies(refreshFirst: false, keepExpired: true) },
            load: { [weak self] in self?.loadHome() }
        )
    }

    /// The first load against the launch's refresh, at most `wait`.
    /// Refreshed: seed, then load. Refused: the session is over; nothing loads
    /// and the person signs in natively (a refusal that ends nothing, for a
    /// session no longer the one stored, loads as for no answer). No answer:
    /// one retry within the wait, then the stored token is seeded even if
    /// expired (never NO cookie while a session is stored) and the page loads.
    /// A refresh still running when the wait ends is let run: cut short, it
    /// could leave its rotated pair unsaved; when it lands, its notification
    /// re-seeds the page.
    @MainActor
    static func firstLoad(wait: Double, retryPause: Double = firstLoadRetryPause,
                          refresh: @escaping () async -> RefreshOutcome,
                          refused: () -> Bool,
                          seed: () async -> Void,
                          load: () -> Void) async {
        let outcome = await settled(within: wait) { () async -> RefreshOutcome in
            let first = await refresh()
            guard first == .noAnswer else { return first }
            try? await Task.sleep(for: .seconds(retryPause))
            return await refresh()
        } ?? .noAnswer
        if outcome == .refused, refused() { return }
        await seed()
        load()
    }

    /// `work`'s answer, or nil once `seconds` have passed, whichever is first.
    /// `work` is never cancelled (see `bounded`).
    static func settled<T>(within seconds: Double, _ work: @escaping () async -> T) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let once = FirstAnswer(continuation)
            Task { once.resume(await work()) }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                once.resume(nil)
            }
        }
    }

    /// Resumes its continuation with the first answer given, once.
    private final class FirstAnswer<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T?, Never>?
        init(_ continuation: CheckedContinuation<T?, Never>) { self.continuation = continuation }
        func resume(_ value: T?) {
            lock.lock()
            let c = continuation
            continuation = nil
            lock.unlock()
            c?.resume(returning: value)
        }
    }

    /// Whether this launch has emptied the page's cookie jar yet.
    private var cookieJarReset = false

    /// Whether this launch has removed the page's service workers yet.
    private var serviceWorkersRemoved = false

    /// Once per launch, before the first load: the page's service workers go.
    @MainActor
    func removeServiceWorkersOnce() async {
        guard !serviceWorkersRemoved else { return }
        await Self.removeServiceWorkers(WebShellDataStore.store())
        serviceWorkersRemoved = true
    }

    /// Remove the page's service-worker registrations, and nothing else: never
    /// the IndexedDB that holds edits not yet synced. The web editor clears an
    /// old worker itself on a normal start, but an old worker serves its own
    /// document, so the page's own cleanup never runs in it. And a worker's
    /// own fetches belong to no page, both the document and assets it serves
    /// and its update, so WebKit asks no navigation delegate about their
    /// server trust: the editor's leaked-key check (`TrustBlocklist`) never
    /// sees them. The web editor registers none in this shell, so none comes
    /// back.
    static func removeServiceWorkers(_ dataStore: WKWebsiteDataStore) async {
        await dataStore.removeData(ofTypes: [WKWebsiteDataTypeServiceWorkerRegistrations], modifiedSince: .distantPast)
    }

    /// Empty the page's cookie jar — cookies only, never the IndexedDB that
    /// holds edits not yet synced. Done once per launch before the first load:
    /// the store is not cleared on update, and an earlier build may have left
    /// a 30-day, non-HttpOnly `refresh_token` in it. Deleting that one by name
    /// is not enough this early — WebKit has not loaded its persisted cookies
    /// yet, so the cookie survives. The page needs no cookie but the
    /// `auth_token` seeded after this.
    static func resetCookieJar(_ dataStore: WKWebsiteDataStore) async {
        await dataStore.removeData(ofTypes: [WKWebsiteDataTypeCookies], modifiedSince: .distantPast)
    }

    private func scheduleTokenRefresh(before expiry: Date?) {
        tokenRefreshTimer?.invalidate()
        guard let expiry else { return }
        let fireAt = expiry.addingTimeInterval(-90)
        guard fireAt > Date() else { return }
        let timer = Timer(fire: fireAt, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in await self?.seedCookies() }
        }
        RunLoop.main.add(timer, forMode: .common)
        tokenRefreshTimer = timer
    }

    /// APIService refreshed the token (on a 401 elsewhere, or for the
    /// foreground): the page's copy follows.
    @objc private func reseedCookies() {
        guard webView != nil else { return }
        Task { @MainActor in await reseedIfBehind() }
    }

    /// A foregrounded shell may have sat in the switcher past the access
    /// token's TTL, and the page re-checks its session the moment it is
    /// visible again: a 401 there reads as a sign-out. So the session is
    /// checked at the first foreground signal (`ForegroundRefreshTrigger`), on
    /// APIService's actor at once rather than behind the main thread's own
    /// foreground work: a token near its expiry is refreshed, a fresh one is
    /// asked about once, so a session revoked elsewhere meanwhile comes back
    /// refused (`checkSessionOnReturn`). The page's copy is re-seeded once it
    /// settles.
    private func startForegroundRefresh() {
        guard webView != nil else { return }
        let stamp = AuthManager.SessionStamp.current()
        let refresh = Task.detached(priority: .userInitiated) {
            await APIService.shared.checkSessionOnReturn(within: 120)
        }
        Task { @MainActor [weak self] in
            let outcome = await refresh.value
            await WebShellModel.afterForegroundRefresh(
                outcome,
                refused: { AuthManager.shared.expireSessionRefusedByServer(since: stamp) },
                reseed: { await self?.reseedIfBehind() },
                evaluate: { self?.catchUp?.evaluate() }
            )
        }
    }

    /// What the foreground does with its check. Refused: the session ended
    /// while away (it timed out, it was revoked, or every device was signed
    /// out), so the native sign-in comes at once, as at the first load, before
    /// the page's visible re-check can wipe and land on the portal. Otherwise,
    /// and for a refusal that ends nothing (a session no longer the one
    /// stored), the page's copy follows and the catch-up looks again.
    @MainActor
    static func afterForegroundRefresh(_ outcome: RefreshOutcome, refused: () -> Bool,
                                       reseed: () async -> Void, evaluate: () -> Void) async {
        if outcome == .refused, refused() { return }
        await reseed()
        evaluate()
    }

    /// Used only if a token's `exp` cannot be read: the server's 15-minute
    /// native access-token TTL, the shortest it issues.
    static let authCookieFallbackMaxAge = 15 * 60

    /// The `auth_token` cookie, built from the same Set-Cookie line the auth
    /// server sends so its attributes (HttpOnly above all) cannot drift from
    /// the server's.
    static func authCookie(token: String, domain: String, url: URL, maxAge: Int) -> HTTPCookie? {
        let line = "auth_token=\(token); Domain=\(domain); Path=/; Max-Age=\(maxAge); Secure; HttpOnly; SameSite=Lax"
        return HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": line], for: url).first
    }

    /// Re-push `window.__pingolinDevice` and tell an open Settings panel to
    /// re-read it.
    ///
    /// Called on a foreground transition and when the settings sheet closes:
    /// this is what makes a value the person just changed show up on the row
    /// they came from — without it the panel would keep displaying the
    /// document-start snapshot until the next full load. Android does the
    /// same on resume.
    ///
    /// `evaluateJavaScript` has no origin allowlist of its own, which is why
    /// the guard lives inside the script rather than here.
    /// Not private: the settings sheet's `onDismiss` calls this directly. See
    /// the note there for why the foreground notification alone is not enough.
    @objc func refreshDeviceSnapshot() {
        guard let webView else { return }
        webView.evaluateJavaScript(
            WebAppDeviceState.buildScript(
                device: WebAppDeviceState.from(AppConfiguration.shared),
                origin: origin,
                onLoad: false
            )
        )
    }

    /// The native re-check opened earlier identities the page does not
    /// have yet. The page asks the bridge again (op `previousVaultKeys`) and
    /// re-decrypts what was locked; it makes no request of its own for them.
    @MainActor
    func notifyIdentitiesChanged() {
        guard let webView else { return }
        webView.evaluateJavaScript(IdentityRecheck.pageEventScript(origin: origin))
    }

    /// The purchase sheet closed, so the plan the page shows may be out of
    /// date. The page asks `/auth/me` at once instead of at its next minute: a
    /// SwiftUI sheet opens in the same scene, so closing one posts no
    /// foreground notification and fires no `visibilitychange`.
    ///
    /// A page too old to listen ignores the event, and a build without this
    /// call leaves the page to its minute timer, so the two ship in any order.
    @MainActor
    func notifyAccountMayHaveChanged() {
        guard let webView else { return }
        webView.evaluateJavaScript(Self.accountEventScript(origin: origin))
    }

    /// The origin guard sits inside the script, as in `IdentityRecheck`'s:
    /// `evaluateJavaScript` has no allowlist, and the account portal renders
    /// in this web view too.
    nonisolated static func accountEventScript(origin: String) -> String {
        "(function(){try{if(location.origin!==\(WebAppDeviceState.quote(origin)))return;"
            + "document.dispatchEvent(new CustomEvent('pingolin-account'));}catch(e){}})();"
    }

    /// `https://note.pingolin.com` -> `.pingolin.com`, matching the cookie
    /// domain the server sets, so the cookie also covers `account.` for the
    /// client-key handoff. The port must not survive into the domain — a
    /// cookie whose domain carries one is rejected outright, which reads as
    /// "the session just didn't work" with nothing logged.
    static func cookieDomain(for baseURL: String) -> String {
        let host = baseURL
            .components(separatedBy: "://").last!
            .components(separatedBy: "/").first!
            .components(separatedBy: ":").first!
        let registrable = host.split(separator: ".").dropFirst().joined(separator: ".")
        return registrable.contains(".") ? ".\(registrable)" : host
    }

    // MARK: - Shell hooks (document start)

    /// Announce the shell and bridge the page's Android-shaped message
    /// objects onto WKScriptMessageHandler. The page posts to
    /// `window.pingolinNudge` / `window.pingolinSave` — objects Android's
    /// `addWebMessageListener` injects natively — so this shim gives WebKit
    /// the same surface and the page needs zero platform branches.
    private func markerScript() -> String {
        """
        (function(){try{if(location.origin!=='\(origin)')return;
        window.__pingolinNativeShell='pingolin-close';
        window.__pingolinShellSettings='pingolin-settings';
        window.__pingolinShellSignOut='pingolin-signout';
        window.__pingolinShellUpgrade='pingolin-upgrade';
        window.pingolinNudge={postMessage:function(m){window.webkit.messageHandlers.pingolinNudge.postMessage(String(m));}};
        window.pingolinSave={postMessage:function(m){window.webkit.messageHandlers.pingolinSave.postMessage(String(m));}};
        }catch(e){}})();
        """
    }
}

// MARK: - WKNavigationDelegate

extension WebShellModel: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        switch url.scheme {
        case "pingolin-close":
            // Home mode: the page navigates itself to the grid before firing
            // the close scheme, so the close is already done. There is no
            // activity stack to pop on iOS — nothing to do.
            decisionHandler(.cancel)
        case "pingolin-settings":
            // The page's Settings panel asked for the NATIVE settings (app
            // lock, push mode — neither can live inside the page).
            //
            // `?section=` opens ONE group rather than the whole screen, which
            // is what makes the crossing feel like part of the page instead of
            // a second Settings app. Android does the same thing by hiding
            // every other group (`applySectionFocus`); here the sheet simply
            // renders the one group asked for.
            settingsSection = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "section" })?.value
            showSettings = true
            decisionHandler(.cancel)
        case "pingolin-upgrade":
            // The page's Upgrade CTA. Apple 3.1.1 requires the purchase go
            // through StoreKit, so the shell presents the native IAP sheet
            // instead of letting the web billing page load. (Android answers
            // the same marker with its read-only Premium explainer.)
            //
            // `?focus=` is read the same way `pingolin-settings` reads
            // `?section=`: a 402 for a specific cap lands on a PremiumSheet
            // explainer framed around THAT benefit rather than the generic
            // three-up. A page that sends no focus gets the generic sheet.
            premiumFocus = PremiumSheet.Focus(
                URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "focus" })?.value
            )
            showPremium = true
            decisionHandler(.cancel)
        case "pingolin-signout":
            // Confirm with the same warning native Settings shows, then run
            // the same teardown — otherwise the page's sign-out would
            // strand the shell on the in-WebView account portal with the
            // native session still alive.
            showSignOutConfirm = true
            decisionHandler(.cancel)
        case "http", "https":
            // Keep the shell on Pingolin origins. Anything else opens in the
            // system browser: iOS has no back button, so an external site
            // inside the shell would be a dead end. (Android lets the WebView
            // wander because hardware back can always return.)
            let target = "\(url.scheme ?? "")://\(url.host ?? "")"
            let portal = AppConfiguration.shared.accountBaseURL

            // The account portal is allowed to render in-shell, but its billing
            // pages are not. `pingolin-upgrade` above is the sanctioned route and
            // presents the native StoreKit sheet, as Apple 3.1.1 requires — and
            // that gate is worth nothing if the user can simply navigate to the
            // portal's own /subscription, which opens Paddle.Checkout. The
            // sidebar links to it on every portal page, so this is not a
            // hypothetical path: it is two taps from Settings, and App Review
            // does click around.
            //
            // Opened in the system browser rather than blocked outright: the page
            // is legitimate, it just must not be a purchase surface INSIDE the app.
            let path = url.path
            if portal.hasPrefix(target),
               path.hasPrefix("/subscription") || path.hasPrefix("/payment") {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
                return
            }

            if navigationAction.targetFrame?.isMainFrame != false,
               target != origin, !portal.hasPrefix(target) {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        default:
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageReady = true
        loadFailed = false
        if let path = pendingPath {
            pendingPath = nil
            navigate(to: path)
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        // No bundled offline snapshot on iOS (see the type comment): surface
        // a retry instead of a silent white screen.
        if (error as NSError).code != NSURLErrorCancelled {
            loadFailed = true
        }
    }

    /// The editor's server-trust challenges get the app's check
    /// (`TrustBlocklist`): the system's evaluation, then the leaked emSign
    /// keys. The page is handed the vault key, so a chain carrying one of them
    /// must never load it. A refused chain fails the load, and the retry shows:
    /// the failure itself is a "cancelled", which `didFailProvisionalNavigation`
    /// passes over (a navigation the shell replaced), so the refusal says so.
    func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        TrustBlocklist.evaluate(trust) { [weak self] accepted in
            if !accepted { self?.loadFailed = true }
            completionHandler(accepted ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
        }
    }
}

// MARK: - JavaScript dialogs

/// One `alert()` / `confirm()` / `prompt()` the page is blocked on.
///
/// ## Why this exists at all
///
/// `WKWebView` presents NO panel of its own: with the three `WKUIDelegate`
/// methods below unimplemented, `alert()` is a silent no-op, `confirm()`
/// returns false and `prompt()` returns nil, with nothing shown and nothing
/// logged. The web editor uses them in its shell-only branches
/// (`if (shellSaveAvailable())`) — messages that would otherwise fire only
/// where they cannot be seen — and its backup import asks for a sealed
/// backup's passphrase with `window.prompt`, treating nil as "cancelled", so
/// restoring an encrypted backup would return to the note list with no error
/// at all. Android shows all of these, because its WebChromeClient does not
/// override onJsAlert and the base implementation lets the WebView draw its
/// own dialog.
///
/// ## This is the BACKSTOP, not the primary fix
///
/// The right fix is the page's own in-app dialogs: they theme correctly, can
/// say more than one line, and fix web + Android + iOS at once. This exists
/// because a page deploy is NOT atomic with an App Store release: an
/// already-installed build must not silently swallow a dialog a newer page
/// adds. If the page never calls these, nothing here ever runs.
///
/// ## The completion-handler contract
///
/// WebKit requires the handler to run EXACTLY once. Never calling it blocks
/// the page's JavaScript forever; calling it twice raises inside WKWebView.
/// SwiftUI can end an alert by paths other than a button tap, so `finish` is
/// latched and `deinit` answers on behalf of a request that was dropped
/// without one. That is not belt-and-braces — it is what makes both halves of
/// the contract hold whichever path fires.
final class JSDialogRequest: Identifiable {
    enum Kind { case alert, confirm, prompt }

    let id = UUID()
    let kind: Kind
    /// The page's own words, shown verbatim. See the title note in
    /// `WebShellView` for why this becomes the alert's title rather than its
    /// message body.
    let message: String
    let defaultText: String
    /// Mask the input. `window.prompt` renders cleartext everywhere it works,
    /// which would put a backup passphrase on screen in the clear — the
    /// Android app masks a 4-digit PIN (dialog_pin_input.xml) and this app
    /// must not do less for the key to every note.
    let secure: Bool

    private var completion: ((String?) -> Void)?

    init(
        kind: Kind,
        message: String,
        defaultText: String = "",
        secure: Bool = false,
        completion: @escaping (String?) -> Void
    ) {
        self.kind = kind
        self.message = message
        self.defaultText = defaultText
        self.secure = secure
        self.completion = completion
    }

    /// `nil` means dismissed/cancelled — JS gets `false` from `confirm()` and
    /// `null` from `prompt()`. Safe to call more than once; only the first
    /// call reaches WebKit.
    func finish(_ value: String?) {
        guard let completion else { return }
        self.completion = nil
        completion(value)
    }

    deinit {
        // Dropped without an answer. Releasing the page is always better than
        // leaving its JS blocked on a dialog that is no longer on screen.
        // `deinit` can run on any thread and WebKit wants its handler on the
        // main one, so hop rather than call in place. `completion` is captured
        // by value; nothing touches `self` after this point.
        guard let completion else { return }
        DispatchQueue.main.async { completion(nil) }
    }

    /// Whether a prompt is asking for something that must not be echoed. The
    /// only signal WebKit hands us is the prompt string itself, so this is a
    /// heuristic — it matches the web editor's backup-passphrase prompt
    /// ("…Enter its passphrase:") and degrades to a plain field for anything
    /// else. Failing towards masked is the safe direction.
    static func looksSecret(_ prompt: String) -> Bool {
        let lowered = prompt.lowercased()
        return lowered.contains("passphrase")
            || lowered.contains("password")
            || lowered.contains("secret")
    }
}

// MARK: - WKUIDelegate

extension WebShellModel: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        jsDialog = JSDialogRequest(kind: .alert, message: message) { _ in
            completionHandler()
        }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        jsDialog = JSDialogRequest(kind: .confirm, message: message) { value in
            completionHandler(value != nil)
        }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        jsDialog = JSDialogRequest(
            kind: .prompt,
            message: prompt,
            defaultText: defaultText ?? "",
            secure: JSDialogRequest.looksSecret(prompt)
        ) { value in
            completionHandler(value)
        }
    }

    /// target=_blank: same-origin popups collapse into the shell; everything
    /// else goes to the system browser (same dead-end rule as above).
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url {
            let target = "\(url.scheme ?? "")://\(url.host ?? "")"
            if target == origin {
                webView.load(navigationAction.request)
            } else {
                UIApplication.shared.open(url)
            }
        }
        return nil
    }
}

// MARK: - WKScriptMessageHandler

extension WebShellModel: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        switch message.name {
        case "pingolinNudge":
            // The page just mutated something through its own API client;
            // kick a native sync so widgets and the share extension's cache
            // catch up promptly instead of on the periodic schedule.
            let now = Date().timeIntervalSince1970
            guard now - lastNudgeAt >= nudgeMinInterval else { return }
            lastNudgeAt = now
            Task { await SyncService.shared.sync() }
        case "pingolinSave":
            // {filename, mimeType, dataBase64} — a WebView cannot download a
            // blob: URL, so the page hands the bytes over and the shell
            // offers the system share sheet (the iOS spelling of Android's
            // MediaStore Downloads insert).
            guard let body = message.body as? String,
                  let data = body.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let filename = payload["filename"] as? String,
                  let dataB64 = payload["dataBase64"] as? String,
                  let bytes = Data(base64Encoded: dataB64)
            else { return }
            // The filename crosses from page content to the filesystem:
            // keep it to a basename.
            let safeName = (filename as NSString).lastPathComponent
                .replacingOccurrences(of: ":", with: "_")
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent(safeName.isEmpty ? "download" : safeName)
            do {
                try bytes.write(to: dest, options: .atomic)
                shareFileURL = dest
            } catch { /* the page already surfaced its own failure copy */ }
        default:
            break
        }
    }
}

// MARK: - SwiftUI wrapper

struct WebShellView: View {
    @ObservedObject private var model = WebShellModel.shared
    @ObservedObject private var keyStore = KeyStoreRecovery.shared
    @EnvironmentObject private var authManager: AuthManager
    /// Backing store for a `prompt()` dialog's field. Seeded and cleared by the
    /// `onChange` at the bottom of `body`.
    @State private var jsPromptText = ""

    var body: some View {
        ZStack {
            // `.container`, NAMED — never the bare `.ignoresSafeArea()`.
            //
            // Without this the WKWebView is laid out inside the safe area and
            // the strips above and below it are painted by the window
            // (systemBackground: #FFFFFF / #000000), which cannot match the
            // page (#fafafa / #1a1a2e). In dark that is a navy page in
            // pure-black bars, for the whole session. The launch screen
            // carries the page's two values exactly
            // (LaunchScreenBackground.colorset); this carries them through
            // the rest of the session.
            //
            // No page change is needed, and that is the reason for the default
            // viewport: the web editor does NOT set `viewport-fit=cover` and
            // uses no env(safe-area-inset-*), so WebKit keeps the page's
            // CONTENT inside the safe area by itself while --bg-primary paints
            // the full screen, notch included.
            //
            // DO NOT widen this to the default region set. `.all` is
            // [.container, .keyboard]; dropping .keyboard stops the frame
            // resizing, WebKit overlays the keyboard, 100dvh stops recomputing
            // (the on-screen keyboard is excluded from the dynamic viewport --
            // it is why `interactive-widget` exists) and the editor's
            // Save/Discard/Close footer ends up behind the keys. SwiftUI's
            // keyboard avoidance is accidentally doing the job
            // `interactive-widget=resizes-content` would do, on a platform
            // where that attribute is in no public Safari release and where a
            // 17.0 deployment floor would need a fallback anyway.
            //
            // underPageBackgroundColor is deliberately left at its default,
            // which WebKit derives from the page. Setting it explicitly would
            // mean guessing the web app's theme, which native does not know.
            WebShellContainer()
                .ignoresSafeArea(.container, edges: .all)
                // The SDK's key store doesn't decode: said once per launch,
                // once the page has painted (or failed to), and the app
                // stays usable. Sign Out is the usual Logout confirmation.
                // On this view, not the ZStack: the page's own dialogs have
                // the ZStack's alert.
                .alert(
                    KeyStoreRecovery.syncNoticeText,
                    isPresented: Binding(
                        get: { keyStore.showsSyncNotice && (model.pageReady || model.loadFailed) },
                        set: { if !$0 { keyStore.showsSyncNotice = false } }
                    )
                ) {
                    Button("Sign Out", role: .destructive) {
                        // After this alert is gone: one presentation at a time.
                        Task { @MainActor in model.showSignOutConfirm = true }
                    }
                    Button("OK", role: .cancel) {}
                }
            if model.loadFailed {
                VStack(spacing: 16) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("Couldn't reach Note")
                        .font(.title3.weight(.semibold))
                    Text("Check your connection and try again.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Retry") { model.loadHome() }
                        .buttonStyle(A11yProminentButtonStyle())
                        .frame(maxWidth: 220)
                    // The native Settings screen exists so those controls work
                    // when the page is not loaded. `showSettings` is otherwise
                    // set only inside the `pingolin-settings` handler, which
                    // needs the page to have rendered its Settings panel first
                    // — so without this button a signed-in user whose page
                    // would not load could not reach app lock, or even sign
                    // out.
                    Button("Settings") {
                        model.settingsSection = nil
                        model.showSettings = true
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("load-failed-settings")
                    // The SIGN OUT half of the same escape hatch.
                    // `showSignOutConfirm` is otherwise written only by the
                    // `pingolin-signout` scheme handler, which needs the page
                    // to have loaded and fired it, and the native Settings
                    // screen deliberately carries no sign-out (the page owns
                    // it, see SettingsView). Without this button the escape
                    // hatch would offer Delete Account and not Logout: the
                    // irreversible action available and the recoverable one
                    // not, to somebody already having a bad time. Sign-out
                    // stays the page's job in the happy path; this is the only
                    // other door.
                    Button("Sign Out", role: .destructive) {
                        model.showSignOutConfirm = true
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("load-failed-sign-out")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemBackground))
            }
        }
        .sheet(isPresented: $model.showSettings, onDismiss: {
            // Clear the focus so the next opener gets what IT asked for. Left
            // set, a later open from the failure view would inherit whichever
            // group the page last deep-linked to.
            model.settingsSection = nil
            // Re-push the device snapshot into the live document.
            //
            // A SwiftUI sheet is presented in the same scene, so the app
            // never leaves the foreground and willEnterForegroundNotification
            // never posts when it closes. The person went to the sheet
            // precisely to change one of these values, so this is the one
            // moment they are guaranteed stale: without it the panel's
            // Device row keeps showing "Apple Push Notifications" two inches
            // above the control that just set it to Polling. The Android app
            // re-pushes at the same moment (its DeviceSettingsSheet).
            model.refreshDeviceSnapshot()
        }) {
            SettingsView(focus: model.settingsSection)
        }
        .sheet(isPresented: $model.showPremium, onDismiss: {
            // Clear it, for the same reason settingsSection is cleared: a later
            // generic Upgrade tap must not inherit the last 402's framing.
            model.premiumFocus = nil
            // `buy` closes this sheet only after the server has the purchase,
            // so the page's plan row can turn as it comes back into view.
            model.notifyAccountMayHaveChanged()
        }) {
            PremiumSheet(focus: model.premiumFocus)
        }
        .sheet(item: $model.shareFileURL) { url in
            ActivityShareSheet(items: [url])
        }
        .confirmationDialog(
            "Logout",
            isPresented: $model.showSignOutConfirm,
            titleVisibility: .visible
        ) {
            Button("Logout", role: .destructive) {
                Task {
                    await authManager.logout()
                    WebShellModel.shared.teardown(keepData: false)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Log out? Any unsynced changes will be uploaded first. If you're offline, unsynced notes may be lost.")
        }
        // The page's own alert()/confirm()/prompt(), which WKWebView otherwise
        // discards in silence. See `JSDialogRequest` for why this is a
        // backstop rather than the fix.
        //
        // The page's text becomes the alert's TITLE and there is no message
        // body: every string that reaches here is a whole sentence written for
        // the person reading it, and inventing a short title above it ("Note",
        // "Error") would be putting words in the page's mouth. It is also what
        // a plain UIAlertController with one line does.
        .alert(
            model.jsDialog?.message ?? "",
            isPresented: Binding(
                get: { model.jsDialog != nil },
                set: { shown in
                    // Covers every non-button exit too. `finish` is latched, so
                    // a button that already answered makes this a no-op.
                    if !shown {
                        model.jsDialog?.finish(nil)
                        model.jsDialog = nil
                    }
                }
            ),
            presenting: model.jsDialog
        ) { request in
            switch request.kind {
            case .alert:
                Button("OK") { request.finish("") }
            case .confirm:
                // SwiftUI places the `.cancel` role itself; source order only
                // decides which of the others is the default.
                Button("OK") { request.finish("") }
                Button("Cancel", role: .cancel) { request.finish(nil) }
            case .prompt:
                if request.secure {
                    SecureField("", text: $jsPromptText)
                } else {
                    TextField("", text: $jsPromptText)
                }
                Button("OK") { request.finish(jsPromptText) }
                Button("Cancel", role: .cancel) { request.finish(nil) }
            }
        }
        // Seed the field from the page's defaultText each time a NEW dialog
        // appears, and clear it after — a passphrase must not sit in this
        // @State waiting for the next prompt to show it.
        .onChange(of: model.jsDialog?.id) { _, id in
            jsPromptText = id == nil ? "" : (model.jsDialog?.defaultText ?? "")
        }
    }
}

/// URL is Identifiable for .sheet(item:) via its absoluteString.
extension URL: Identifiable {
    public var id: String { absoluteString }
}

private struct WebShellContainer: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        WebShellModel.shared.ensureWebView()
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

/// Fires at the FIRST signal that the app is coming back to the foreground: a
/// scene's `willEnterForeground` or the application's, whichever is posted
/// first, inside that notification. Never later, at `didBecomeActive`: WebKit
/// shows the page again as the app enters the foreground, and the page
/// re-checks its session at once. Once per trip; the next background re-arms
/// it.
final class ForegroundRefreshTrigger {
    private let center: NotificationCenter
    private let fire: () -> Void
    private var observers: [NSObjectProtocol] = []
    private var armed = true

    init(center: NotificationCenter = .default, fire: @escaping () -> Void) {
        self.center = center
        self.fire = fire
        for name in [UIScene.willEnterForegroundNotification, UIApplication.willEnterForegroundNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.enteringForeground()
            })
        }
        for name in [UIScene.didEnterBackgroundNotification, UIApplication.didEnterBackgroundNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.armed = true
            })
        }
    }

    deinit {
        for observer in observers { center.removeObserver(observer) }
    }

    private func enteringForeground() {
        guard armed else { return }
        armed = false
        fire()
    }
}

/// The access token the page was last given, kept as a digest: the shell
/// holds no second copy of the token itself.
struct SeededToken {
    private var digest: SHA256.Digest?
    private var issuedAt: Date?

    /// Whether `token` is newer than the one last seeded. Any other token is:
    /// a session's token only moves forward, and a sign-out forgets the last.
    func isBehind(_ token: String?) -> Bool {
        guard let token else { return false }
        return SHA256.hash(data: Data(token.utf8)) != digest
    }

    /// Whether `token` was issued (`iat`) before the one last seeded: an older
    /// token never replaces a newer one in the page's jar. Unknown either way:
    /// not older.
    func isOlder(_ token: String) -> Bool {
        guard let issuedAt, let theirs = APIService.accessTokenIssuedAt(token) else { return false }
        return theirs < issuedAt
    }

    mutating func record(_ token: String) {
        digest = SHA256.hash(data: Data(token.utf8))
        issuedAt = APIService.accessTokenIssuedAt(token)
    }

    mutating func forget() {
        digest = nil
        issuedAt = nil
    }
}

/// A stale session catches up. While the stored access token is expired, or
/// within 120 s of its expiry, the page's copy is dead or about to be; a
/// refresh that got no answer (offline at launch or at the foreground, the
/// auth server failing) leaves it so, and nothing else refreshes until some
/// native request happens to. So when the network comes back, and on a retry
/// while the token is stale and the app is in the foreground, the one
/// refresher runs and the page is re-seeded with the new token. The retries
/// come quickly at first, 1, 2 and 4 s apart, inside the page's own retries
/// after a 401 (300 ms, 1 s, 2 s), so a passing failure is caught before the
/// page believes its 401; then every 30 s. They stop once the token is fresh
/// (the next stale spell starts quick again), on background, and on sign-out
/// (the shell's teardown). The page's cookie dies with the token: when a
/// retry would land past the token's expiry, the quick retries start again
/// there (1, 2 and 4 s after it), as the page's requests then go out with no
/// cookie. A refused session gets the usual sign-out, for the session the
/// attempt started under, and nothing else; a refusal that sign-out drops (a
/// sign-out or erasure under way, another session meanwhile) keeps the
/// retries going.
///
/// Used on the main thread: the observers run where the notification is
/// posted (UIKit's and the connectivity monitor's are on the main thread), and
/// the timers are on the main run loop.
final class SessionCatchUp {
    struct Hooks {
        var isStale: () -> Bool
        var isForeground: () -> Bool
        /// The stored token's expiry, when it can be read.
        var expiry: () -> Date?
        var now: () -> Date
        /// The session an attempt starts under, handed back with its refusal.
        var stamp: () -> AuthManager.SessionStamp
        var refresh: () async -> RefreshOutcome
        var reseed: () async -> Void
        /// Ends the session the attempt started under; answers whether it did.
        var refused: (AuthManager.SessionStamp) -> Bool
        /// Runs `fire` once after `delay`; returns what cancels it.
        var schedule: (_ delay: TimeInterval, _ fire: @escaping () -> Void) -> () -> Void
    }

    /// The first retries of a stale spell, then `retryEvery`.
    static let quickRetries: [TimeInterval] = [1, 2, 4]
    static let retryEvery: TimeInterval = 30

    private let hooks: Hooks
    private let center: NotificationCenter
    private var observers: [NSObjectProtocol] = []
    private var cancelPending: (() -> Void)?
    private var retriesSoFar = 0
    private var attempting = false

    /// Whether a retry is pending or an attempt is out.
    var isRetrying: Bool { cancelPending != nil || attempting }

    init(center: NotificationCenter = .default, hooks: Hooks) {
        self.center = center
        self.hooks = hooks
        observers.append(center.addObserver(forName: .pingolinNetworkRegained, object: nil, queue: nil) { [weak self] _ in
            self?.networkRegained()
        })
        for name in [UIScene.didEnterBackgroundNotification, UIApplication.didEnterBackgroundNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.stop()
            })
        }
    }

    deinit {
        for observer in observers { center.removeObserver(observer) }
        cancelPending?()
    }

    /// After every seed, and once an attempt settles: a retry is pending
    /// exactly while the token is stale and the app is in the foreground.
    func evaluate() {
        guard hooks.isStale(), hooks.isForeground() else { return stop() }
        guard cancelPending == nil, !attempting else { return }
        var delay = retriesSoFar < Self.quickRetries.count ? Self.quickRetries[retriesSoFar] : Self.retryEvery
        retriesSoFar += 1
        // The page's cookie dies at the token's expiry, and its requests then
        // go out with none: a retry that would land past it is brought to it,
        // and the quick retries start again from there.
        let now = hooks.now()
        if let expiry = hooks.expiry(), now < expiry, now.addingTimeInterval(delay) > expiry {
            delay = expiry.timeIntervalSince(now) + Self.quickRetries[0]
            retriesSoFar = 1
        }
        cancelPending = hooks.schedule(delay) { [weak self] in
            self?.cancelPending = nil
            self?.retry()
        }
    }

    /// Fresh, in the background, or signed out: nothing pending, and the next
    /// stale spell starts with the quick retries again.
    func stop() {
        cancelPending?()
        cancelPending = nil
        retriesSoFar = 0
    }

    /// The network came back: a stale session catches up at once.
    func networkRegained() {
        if hooks.isStale() { attempt() }
    }

    func retry() {
        guard hooks.isStale(), hooks.isForeground() else { return stop() }
        attempt()
    }

    /// One attempt at a time, through the one refresher.
    private func attempt() {
        guard !attempting else { return }
        attempting = true
        cancelPending?()
        cancelPending = nil
        let stamp = hooks.stamp()
        let hooks = self.hooks
        Task { @MainActor [weak self] in
            let outcome = await hooks.refresh()
            self?.attempting = false
            switch outcome {
            case .refreshed:
                await hooks.reseed()
                self?.evaluate()
            case .refused:
                // Judged first: a refusal the sign-out drops keeps the
                // retries going, as for no answer.
                if hooks.refused(stamp) { self?.stop() } else { self?.evaluate() }
            case .noAnswer:
                self?.evaluate()
            }
        }
    }

    /// Whether a stored access token is expired or within `margin` of its
    /// expiry. None, or one whose expiry can't be read, is not stale here:
    /// there is nothing to catch up, and the 401 paths see to the rest.
    static func isStale(_ token: String?, now: Date = Date(), margin: TimeInterval = 120) -> Bool {
        guard let token, let expiry = APIService.accessTokenExpiry(token) else { return false }
        return expiry.timeIntervalSince(now) <= margin
    }

    /// The real scheduler: once, on the main run loop, in every mode.
    static func mainRunLoopOnce(after delay: TimeInterval, fire: @escaping () -> Void) -> () -> Void {
        let timer = Timer(timeInterval: delay, repeats: false) { _ in fire() }
        RunLoop.main.add(timer, forMode: .common)
        return { timer.invalidate() }
    }
}
