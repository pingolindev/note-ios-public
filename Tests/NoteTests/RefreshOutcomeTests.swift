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
import UIKit
import XCTest
@testable import Note

/// The session refresh's three outcomes, note-android's rule: only the auth server's own refusal, a JSON 401 from
/// `/api/v1/auth/refresh`, ends a session (and so does having no refresh token at all to present). Everything else is
/// no answer, and the session is kept.
final class RefreshOutcomeTests: XCTestCase {

    func testTheTable() {
        let table: [(RefreshOutcome.Attempt, RefreshOutcome)] = [
            (.stored, .refreshed),
            (.answered(status: 401, json: true), .refused),
            (.noRefreshToken, .refused),
            (.answered(status: 401, json: false), .noAnswer),
            (.answered(status: 400, json: true), .noAnswer),
            (.answered(status: 403, json: true), .noAnswer),
            (.answered(status: 403, json: false), .noAnswer),
            (.answered(status: 404, json: true), .noAnswer),
            (.answered(status: 429, json: true), .noAnswer),
            (.answered(status: 500, json: true), .noAnswer),
            (.answered(status: 502, json: false), .noAnswer),
            (.answered(status: 503, json: true), .noAnswer),
            (.noResponse, .noAnswer),
            (.lockWaitRanOut, .noAnswer),
            (.keychainUnreadable, .noAnswer),
            (.sessionChanged, .noAnswer),
        ]
        for (attempt, outcome) in table {
            XCTAssertEqual(RefreshOutcome.of(attempt), outcome, "\(attempt)")
        }
    }

    /// From the refresh route's HTTP answer to the outcome, through the very error `execute` throws for it.
    func testFromTheRefreshRoutesAnswer() {
        let envelope = Data(#"{"success":false,"error":"Session ended","error_code":"auth_session_revoked"}"#.utf8)
        let page = Data("<html><body>blocked</body></html>".utf8)
        func outcome(_ status: Int, _ contentType: String?, _ body: Data) -> RefreshOutcome {
            let error = APIService.httpError(status: status, contentType: contentType, body: body, decoder: wireDecoder())
            return .of(RefreshOutcome.attempt(failedWith: error))
        }
        XCTAssertEqual(outcome(401, "application/json", envelope), .refused)
        XCTAssertEqual(outcome(401, "application/json; charset=utf-8", envelope), .refused)
        XCTAssertEqual(outcome(401, "Application/JSON", envelope), .refused)
        XCTAssertEqual(outcome(401, "text/html", page), .noAnswer, "an edge's page is not the auth server's refusal")
        XCTAssertEqual(outcome(401, "text/plain", envelope), .noAnswer, "not said to be JSON")
        XCTAssertEqual(outcome(401, nil, envelope), .noAnswer, "no content type: not said to be JSON")
        XCTAssertEqual(outcome(400, "application/json", envelope), .noAnswer)
        XCTAssertEqual(outcome(403, "application/json", envelope), .noAnswer)
        XCTAssertEqual(outcome(429, "application/json", envelope), .noAnswer)
        XCTAssertEqual(outcome(500, "application/json", envelope), .noAnswer)
        XCTAssertEqual(outcome(502, "text/html", page), .noAnswer)
        XCTAssertEqual(outcome(503, "application/json", envelope), .noAnswer)
        let noStatus = APIError(code: "network_error", message: "Invalid response")
        XCTAssertEqual(RefreshOutcome.of(RefreshOutcome.attempt(failedWith: noStatus)), .noAnswer)
    }

    func testTheErrorKeepsTheEnvelopeAndWhetherItWasJSON() {
        let refusal = APIService.httpError(
            status: 401, contentType: "application/json",
            body: Data(#"{"success":false,"error":"x","error_code":"auth_session_revoked"}"#.utf8),
            decoder: wireDecoder())
        XCTAssertEqual(refusal.code, "auth_session_revoked")
        XCTAssertEqual(refusal.status, 401)
        XCTAssertEqual(refusal.isJSON, true)
        let edge = APIService.httpError(status: 502, contentType: "text/html", body: Data("<html>".utf8),
                                        decoder: wireDecoder())
        XCTAssertEqual(edge.code, "http_502")
        XCTAssertEqual(edge.status, 502)
        XCTAssertEqual(edge.isJSON, false)
    }

    /// A refresh that got no answer fails as network trouble: the launch check keeps the session for it, and only a
    /// 401 that stood after the refresh ends it.
    func testOnlyA401ThatStoodEndsTheSessionAtLaunch() {
        XCTAssertNil(APIError.refreshNoAnswer.status)
        XCTAssertEqual(APIError.refreshNoAnswer.plainLine, APIError.unreachableText)
        XCTAssertFalse(AuthManager.launchCheckEndsSession(APIError.refreshNoAnswer))
        XCTAssertTrue(AuthManager.launchCheckEndsSession(APIError(code: "http_401", message: "", status: 401)))
        XCTAssertFalse(AuthManager.launchCheckEndsSession(APIError(code: "http_503", message: "", status: 503)))
        XCTAssertFalse(AuthManager.launchCheckEndsSession(URLError(.notConnectedToInternet)))
        XCTAssertFalse(AuthManager.launchCheckEndsSession(URLError(.timedOut)))
    }

    /// `execute`'s 401: retried after a refresh, left standing when refused, a network failure when no answer came.
    /// And `performRefresh` reads its paths through the table.
    func testTheRefreshPathsGoThroughTheTable() throws {
        let api = try repoSource("App/Services/APIService.swift")
        let start = try XCTUnwrap(api.range(of: "// Generic 401 → try to refresh the access token once, then retry."))
        assertInOrder(String(api[start.upperBound...].prefix(1800)),
                      ["switch await tryRefreshAccessToken() {",
                       "case .refreshed:", "return try await execute(retried, attempt: attempt, didRefresh: true)",
                       "case .refused:", "break",
                       "case .noAnswer:", "throw APIError.refreshNoAnswer"], "execute's 401")
        let perform = try XCTUnwrap(api.range(of: "private func performRefresh() async -> RefreshOutcome {"))
        let performBody = String(api[perform.upperBound...].prefix(4800))
        assertInOrder(performBody,
                      ["switch keychain.read(.refreshToken) {",
                       "case .notFound: return .of(.noRefreshToken)",
                       "case .unreadable: return .of(.keychainUnreadable)",
                       "if lock != nil, held == nil { return .of(.lockWaitRanOut) }",
                       "return .of(.stored)",
                       "let pair = try await refreshToken(stored)",
                       "guard keychain.getString(for: .refreshToken) == stored,",
                       "keychain.updateRefreshedPair(access: pair.accessToken, refresh: pair.refreshToken)",
                       "else { return .of(.sessionChanged) }",
                       "return .of(.stored)",
                       "return .of(RefreshOutcome.attempt(failedWith: err))",
                       "return .of(.noResponse)"], "performRefresh")
        XCTAssertFalse(performBody.contains("keychain.save(pair.accessToken"),
                       "a refreshed pair is only ever an update of the session it was made from")
        let auth = try repoSource("App/Managers/AuthManager.swift")
        XCTAssertTrue(auth.contains("            if Self.launchCheckEndsSession(error) {\n"))
        let finisher = try repoSource("App/Managers/InAppFinisher.swift")
        XCTAssertTrue(finisher.contains("guard await APIService.shared.refreshAccessTokenIfExpiring(within: 60) == .refreshed,"))
    }

    /// A refusal ends only the session it was for: none already ended, none whose sign-out or erasure is under way
    /// (that end empties the page's website data; an expiry over it would keep it), and none other than the session
    /// the refresh presented (signed out, or another sign-in, meanwhile).
    func testARefusalEndsOnlyTheSessionItWasForAndNeverASignOutUnderWay() {
        typealias Stamp = AuthManager.SessionStamp
        let session = Stamp(account: "a", refreshToken: SHA256.hash(data: Data("r1".utf8)))
        let sameAgain = Stamp(account: "a", refreshToken: SHA256.hash(data: Data("r1".utf8)))
        let signedInAgain = Stamp(account: "a", refreshToken: SHA256.hash(data: Data("r2".utf8)))
        let otherAccount = Stamp(account: "b", refreshToken: SHA256.hash(data: Data("r9".utf8)))
        let signedOut = Stamp(account: nil, refreshToken: nil)
        func ends(_ authenticated: Bool, _ ending: Bool, _ now: Stamp) -> Bool {
            AuthManager.refusalEndsSession(isAuthenticated: authenticated, endingSession: ending,
                                           startedUnder: session, now: now)
        }
        XCTAssertTrue(ends(true, false, sameAgain))
        XCTAssertFalse(ends(false, false, sameAgain), "already ended")
        XCTAssertFalse(ends(true, true, sameAgain), "a sign-out or an erasure under way: its end stands")
        XCTAssertFalse(ends(true, false, signedOut), "signed out meanwhile")
        XCTAssertFalse(ends(true, false, otherAccount), "another account signed in meanwhile")
        XCTAssertFalse(ends(true, false, signedInAgain), "a new session of the same account")
    }

    /// The sign-out and the erasure mark themselves under way before their first suspension, so a refusal landing
    /// during them is ignored; the refusal reads that mark and the stamp.
    func testASignOutOrAnErasureUnderWayIsNeverTurnedIntoAnExpiry() throws {
        let auth = try repoSource("App/Managers/AuthManager.swift")
        let logout = try functionBody(auth, "func logout(ending: SessionEnd = .signedOut) async {")
        assertInOrder(logout, ["endingSession = true", "defer { endingSession = false }", "sessionEnd = ending",
                               "await lastWebKeep()", "keychain.deleteAll()", "isAuthenticated = false"], "logout")
        let delete = try XCTUnwrap(auth.range(of: "func deleteAccount("))
        assertInOrder(String(auth[delete.upperBound...].prefix(3000)),
                      ["let token = try await reauthenticate(password: password)", "endingSession = true",
                       "defer { endingSession = false }", "let result = try await api.deleteAccount(",
                       "await logout(ending: .erased)"], "deleteAccount")
        let refusal = try functionBody(auth, "func expireSessionRefusedByServer(since stamp: SessionStamp) -> Bool {")
        assertInOrder(refusal, ["guard Self.refusalEndsSession(isAuthenticated: isAuthenticated, endingSession: endingSession,",
                                "startedUnder: stamp, now: .current(keychain)) else { return false }",
                                "expireSession()", "return true"], "the refusal")
    }

    func testTheIssueTimeIsReadFromTheJWT() {
        func jwt(_ claims: String) -> String {
            let b = Data(claims.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            return "eyJhbGciOiJIUzI1NiJ9.\(b).c2ln"
        }
        let token = jwt(#"{"sub":"u","iat":1900000000,"exp":1900000900}"#)
        XCTAssertEqual(APIService.accessTokenIssuedAt(token)?.timeIntervalSince1970, 1_900_000_000)
        XCTAssertEqual(APIService.accessTokenExpiry(token)?.timeIntervalSince1970, 1_900_000_900)
        XCTAssertNil(APIService.accessTokenIssuedAt(jwt(#"{"sub":"u","exp":1900000900}"#)))
        XCTAssertNil(APIService.accessTokenIssuedAt("not-a-jwt"))
    }

    private func wireDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}

/// Back in the foreground with a token still fresh, a session revoked elsewhere would only be noticed natively near
/// the token's expiry, after the page's own re-check lands on the portal. So the return asks once: one `/auth/me` that
/// doesn't refresh by itself; its JSON 401 goes through the one refresher, whose answer says whether the session is over.
final class SessionOnReturnTests: XCTestCase {

    func testTheRule() async {
        func check(fresh: Bool, probe: APIService.SessionProbe, refresh: RefreshOutcome)
            async -> (RefreshOutcome, probes: Int, refreshes: Int) {
            var probes = 0
            var refreshes = 0
            let outcome = await APIService.sessionCheck(fresh: fresh,
                                                        probe: { probes += 1; return probe },
                                                        refresh: { refreshes += 1; return refresh })
            return (outcome, probes, refreshes)
        }
        var r = await check(fresh: false, probe: .alive, refresh: .refreshed)
        XCTAssertEqual(r.0, .refreshed); XCTAssertEqual(r.probes, 0); XCTAssertEqual(r.refreshes, 1)
        r = await check(fresh: false, probe: .alive, refresh: .refused)
        XCTAssertEqual(r.0, .refused, "near expiry: the refresh answers, as before")
        r = await check(fresh: true, probe: .alive, refresh: .refused)
        XCTAssertEqual(r.0, .refreshed); XCTAssertEqual(r.probes, 1); XCTAssertEqual(r.refreshes, 0)
        r = await check(fresh: true, probe: .unauthorized, refresh: .refused)
        XCTAssertEqual(r.0, .refused, "revoked elsewhere: the native sign-in"); XCTAssertEqual(r.refreshes, 1)
        r = await check(fresh: true, probe: .unauthorized, refresh: .refreshed)
        XCTAssertEqual(r.0, .refreshed, "the server wanted a new token: it has one")
        r = await check(fresh: true, probe: .noAnswer, refresh: .refused)
        XCTAssertEqual(r.0, .noAnswer); XCTAssertEqual(r.refreshes, 0, "no answer proves nothing")
    }

    /// The probe is one `/auth/me` with the stored token that does NOT refresh on a 401 (`didRefresh: true`); only the
    /// auth server's JSON 401 counts as unauthorized; the return check runs it only while the token is fresh.
    func testTheProbeIsOneAuthMeThatDoesNotRefreshByItself() throws {
        let api = try repoSource("App/Services/APIService.swift")
        let probe = try functionBody(api, "private func probeSession() async -> SessionProbe {")
        assertInOrder(probe, ["URL(string: config.authBaseURL + \"/api/v1/auth/me\")!", "req.httpMethod = \"GET\"",
                              "try addHeaders(to: &req, auth: true)",
                              "let _: MeResponse = try await execute(req, didRefresh: true)", "return .alive",
                              "catch let error as APIError where error.status == 401 && error.isJSON == true {",
                              "return .unauthorized", "return .noAnswer"], "probeSession")
        let check = try functionBody(api, "func checkSessionOnReturn(within seconds: TimeInterval) async -> RefreshOutcome {")
        assertInOrder(check, ["guard let token = keychain.getString(for: .accessToken) else { return .noAnswer }",
                              "let fresh = Self.accessTokenExpiry(token).map { $0.timeIntervalSinceNow > seconds } ?? false",
                              "probe: { await self.probeSession() },",
                              "refresh: { await self.tryRefreshAccessToken() })"], "checkSessionOnReturn")
    }
}

/// The first page load waits for the launch's refresh (at most `firstLoadWait`), as the Android shell does: a page
/// that asks `/auth/me` with a dead copy of the access token reads the 401 as a sign-out.
@MainActor
final class FirstLoadTests: XCTestCase {

    /// A scripted launch refresh, and what the first load did with it.
    @MainActor
    private final class Launch {
        private var answers: [RefreshOutcome]
        private let hang: Double
        var refreshes = 0
        var steps: [String] = []
        /// What the sign-out does with the refusal: ends the session, or drops it.
        var refusalEnds = true

        init(_ answers: [RefreshOutcome], hang: Double = 0) {
            self.answers = answers
            self.hang = hang
        }

        func run(wait: Double = 5) async {
            await WebShellModel.firstLoad(
                wait: wait, retryPause: 0.01,
                refresh: { await self.refresh() },
                refused: {
                    self.steps.append("sign in")
                    return self.refusalEnds
                },
                seed: { self.steps.append("seed") },
                load: { self.steps.append("load") }
            )
        }

        private func refresh() async -> RefreshOutcome {
            refreshes += 1
            if hang > 0 { try? await Task.sleep(for: .seconds(hang)) }
            return answers.isEmpty ? .noAnswer : answers.removeFirst()
        }
    }

    func testRefreshedSeedsThenLoads() async {
        let launch = Launch([.refreshed])
        await launch.run()
        XCTAssertEqual(launch.steps, ["seed", "load"])
        XCTAssertEqual(launch.refreshes, 1)
    }

    func testRefusedLoadsNothingAndSignsInNatively() async {
        let launch = Launch([.refused])
        await launch.run()
        XCTAssertEqual(launch.steps, ["sign in"], "no seed, no load: never the portal")
        XCTAssertEqual(launch.refreshes, 1)
    }

    func testNoAnswerIsRetriedOnceThenLoads() async {
        let launch = Launch([.noAnswer, .refreshed])
        await launch.run()
        XCTAssertEqual(launch.steps, ["seed", "load"])
        XCTAssertEqual(launch.refreshes, 2)
    }

    func testNoAnswerTwiceSeedsWhatIsStoredAndLoads() async {
        let launch = Launch([.noAnswer, .noAnswer, .refreshed])
        await launch.run()
        XCTAssertEqual(launch.steps, ["seed", "load"])
        XCTAssertEqual(launch.refreshes, 2, "one retry, not more")
    }

    /// A refusal the sign-out drops (another session meanwhile) ends nothing, and the page loads as for no answer.
    func testARefusalThatEndsNothingLoadsAsForNoAnswer() async {
        let launch = Launch([.refused])
        launch.refusalEnds = false
        await launch.run()
        XCTAssertEqual(launch.steps, ["sign in", "seed", "load"])
    }

    func testRefusedOnTheRetrySignsIn() async {
        let launch = Launch([.noAnswer, .refused])
        await launch.run()
        XCTAssertEqual(launch.steps, ["sign in"])
        XCTAssertEqual(launch.refreshes, 2)
    }

    /// A refresh still running when the wait ends is let run (cut short, it could leave its rotated pair unsaved),
    /// and the page loads at the wait with what is stored.
    func testARefreshStillRunningAtTheWaitIsLetRunAndThePageLoads() async {
        let launch = Launch([.refreshed], hang: 2)
        let started = Date()
        await launch.run(wait: 0.3)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
        XCTAssertEqual(launch.steps, ["seed", "load"])
        XCTAssertEqual(launch.refreshes, 1)
    }

    /// Never NO cookie while a session is stored: the first load seeds the stored token even when it has expired.
    func testTheFirstLoadSeedsAnExpiredTokenToo() throws {
        let now = Date()
        let fallback = WebShellModel.authCookieFallbackMaxAge
        XCTAssertEqual(WebShellModel.cookieLifetime(expiry: now.addingTimeInterval(-60), keepExpired: true, now: now), fallback)
        XCTAssertNil(WebShellModel.cookieLifetime(expiry: now.addingTimeInterval(-60), keepExpired: false, now: now))
        XCTAssertEqual(WebShellModel.cookieLifetime(expiry: now.addingTimeInterval(300), keepExpired: true, now: now), 300)
        XCTAssertEqual(WebShellModel.cookieLifetime(expiry: now.addingTimeInterval(300), keepExpired: false, now: now), 300)
        XCTAssertEqual(WebShellModel.cookieLifetime(expiry: nil, keepExpired: false, now: now), fallback)
        let shell = try repoSource("App/Views/WebShellView.swift")
        let hold = try functionBody(shell, "func holdFirstLoadForTheLaunchRefresh() async {")
        assertInOrder(hold, ["let stamp = AuthManager.SessionStamp.current()",
                             "wait: Self.firstLoadWait",
                             "refresh: { await APIService.shared.refreshAccessTokenIfExpiring(within: 120) }",
                             "refused: { AuthManager.shared.expireSessionRefusedByServer(since: stamp) }",
                             "seed: { [weak self] in await self?.seedCookies(refreshFirst: false, keepExpired: true) }",
                             "load: { [weak self] in self?.loadHome() }"], "the first load")
        XCTAssertEqual(WebShellModel.firstLoadWait, 5)
    }
}

/// Back in the foreground, the session's refresh starts at the FIRST signal of it: inside a scene's (or the
/// application's) `willEnterForeground`, before the app is active. WebKit shows the page again as the app enters the
/// foreground, and the page re-checks its session at once.
final class ForegroundRefreshTriggerTests: XCTestCase {

    func testTheRefreshStartsInsideTheFirstForegroundSignalBeforeTheAppIsActive() {
        let center = NotificationCenter()
        var events: [String] = []
        let trigger = ForegroundRefreshTrigger(center: center) { events.append("refresh") }
        let active = center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil,
                                        queue: nil) { _ in events.append("active") }
        defer { center.removeObserver(active) }

        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        center.post(name: UIScene.willEnterForegroundNotification, object: nil)
        XCTAssertEqual(events, ["refresh"], "started inside the scene's willEnterForeground")
        center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        XCTAssertEqual(events, ["refresh", "active"], "once per trip, and before the app is active")
        withExtendedLifetime(trigger) {}
    }

    func testTheApplicationsSignalAloneStartsIt() {
        let center = NotificationCenter()
        var fired = 0
        let trigger = ForegroundRefreshTrigger(center: center) { fired += 1 }
        center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        XCTAssertEqual(fired, 1)
        withExtendedLifetime(trigger) {}
    }

    func testBecomingActiveAloneStartsNothing() {
        let center = NotificationCenter()
        var fired = 0
        let trigger = ForegroundRefreshTrigger(center: center) { fired += 1 }
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        center.post(name: UIScene.didActivateNotification, object: nil)
        XCTAssertEqual(fired, 0)
        withExtendedLifetime(trigger) {}
    }

    func testEachTripToTheBackgroundArmsItAgain() {
        let center = NotificationCenter()
        var fired = 0
        let trigger = ForegroundRefreshTrigger(center: center) { fired += 1 }
        center.post(name: UIScene.willEnterForegroundNotification, object: nil)
        center.post(name: UIScene.willEnterForegroundNotification, object: nil)
        XCTAssertEqual(fired, 1)
        center.post(name: UIScene.didEnterBackgroundNotification, object: nil)
        center.post(name: UIScene.willEnterForegroundNotification, object: nil)
        XCTAssertEqual(fired, 2)
        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        XCTAssertEqual(fired, 3)
        withExtendedLifetime(trigger) {}
    }

    /// Refused in the foreground: the session ended while away, so the native sign-in comes at once (before the
    /// page's visible re-check can wipe and land on the portal), and nothing else. Otherwise the page's copy follows,
    /// and the catch-up looks again.
    @MainActor
    func testARefusalInTheForegroundSignsInAtOnceAndNothingElse() async {
        for (outcome, ends, expected) in [(RefreshOutcome.refused, true, ["sign in"]),
                                          (.refused, false, ["sign in", "reseed", "evaluate"]),
                                          (.refreshed, true, ["reseed", "evaluate"]),
                                          (.noAnswer, true, ["reseed", "evaluate"])] {
            var steps: [String] = []
            await WebShellModel.afterForegroundRefresh(outcome,
                                                       refused: {
                                                           steps.append("sign in")
                                                           return ends
                                                       },
                                                       reseed: { steps.append("reseed") },
                                                       evaluate: { steps.append("evaluate") })
            XCTAssertEqual(steps, expected, "\(outcome), refusal ends: \(ends)")
        }
    }

    /// The shell's trigger starts the refresh on APIService's actor at once, then re-seeds; the old observer, whose
    /// refresh started behind the main thread's foreground work, is gone.
    func testTheShellStartsItsRefreshFromTheTrigger() throws {
        let shell = try repoSource("App/Views/WebShellView.swift")
        XCTAssertTrue(shell.contains(
            "foregroundRefresh = ForegroundRefreshTrigger { [weak self] in self?.startForegroundRefresh() }"))
        let start = try functionBody(shell, "private func startForegroundRefresh() {")
        assertInOrder(start, ["guard webView != nil else { return }",
                              "let stamp = AuthManager.SessionStamp.current()",
                              "Task.detached(priority: .userInitiated) {",
                              "await APIService.shared.checkSessionOnReturn(within: 120)",
                              "let outcome = await refresh.value",
                              "await WebShellModel.afterForegroundRefresh(",
                              "refused: { AuthManager.shared.expireSessionRefusedByServer(since: stamp) },",
                              "reseed: { await self?.reseedIfBehind() },",
                              "evaluate: { self?.catchUp?.evaluate() }"], "the foreground refresh")
        XCTAssertFalse(shell.contains("""
                    selector: #selector(reseedCookies),
                    name: UIApplication.willEnterForegroundNotification,
        """))
    }
}

private func repoSource(_ path: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
}

/// The body of `func <name>` up to the next `\n    }\n` at its depth.
private func functionBody(_ text: String, _ signature: String) throws -> String {
    let start = try XCTUnwrap(text.range(of: signature), "no \(signature)")
    let rest = text[start.upperBound...]
    let end = try XCTUnwrap(rest.range(of: "\n    }\n"), "no end of \(signature)")
    return String(rest[..<end.lowerBound])
}

private func assertInOrder(_ text: String, _ marks: [String], _ what: String,
                           file: StaticString = #filePath, line: UInt = #line) {
    var at = text.startIndex
    for mark in marks {
        guard let r = text.range(of: mark, range: at..<text.endIndex) else {
            return XCTFail("\(what): \(mark) missing or out of order", file: file, line: line)
        }
        at = r.upperBound
    }
}
