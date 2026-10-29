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

import Security
import WebKit
import XCTest
@testable import Note

/// A chain the editor refuses shows the retry, not a blank page. The load's own failure is a "cancelled", which
/// `didFailProvisionalNavigation` passes over (a navigation the shell replaced), so the refusal itself sets
/// `loadFailed` before it cancels the challenge. A chain it accepts leaves `loadFailed` alone, so the retry never
/// covers a working editor. Both run for real through the shell's own `webView(_:didReceive:completionHandler:)`.
final class EditorRefusalShowsRetryTests: XCTestCase {

    private func certificate(_ path: String) throws -> SecCertificate {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(path).der")
        return try XCTUnwrap(SecCertificateCreateWithData(nil, try Data(contentsOf: url) as CFData), path)
    }

    /// The shell's answer to a server-trust challenge for `chain` (evaluated for `host`, without the network, at
    /// `date` when given), and `loadFailed` after it.
    @MainActor
    private func answer(_ chain: [String], host: String, date: String? = nil) async throws
        -> (disposition: URLSession.AuthChallengeDisposition, loadFailed: Bool) {
        var made: SecTrust?
        XCTAssertEqual(SecTrustCreateWithCertificates(try chain.map(certificate) as CFArray,
                                                      SecPolicyCreateSSL(true, host as CFString), &made), errSecSuccess)
        let trust = try XCTUnwrap(made)
        SecTrustSetNetworkFetchAllowed(trust, false)
        if let date { SecTrustSetVerifyDate(trust, ISO8601DateFormatter().date(from: date)! as CFDate) }
        let challenge = URLAuthenticationChallenge(protectionSpace: TrustSpace(trust), proposedCredential: nil,
                                                   previousFailureCount: 0, failureResponse: nil, error: nil,
                                                   sender: NoSender())
        let model = WebShellModel.shared
        let before = model.loadFailed
        defer { model.loadFailed = before }
        model.loadFailed = false

        let disposition: URLSession.AuthChallengeDisposition = await withCheckedContinuation { done in
            model.webView(WKWebView(frame: .zero), didReceive: challenge) { disposition, _ in
                done.resume(returning: disposition)
            }
        }
        return (disposition, model.loadFailed)
    }

    /// The refused chain: our host's leaf after a leaked emSign intermediate, as AAA Certificate Services
    /// cross-signed it.
    @MainActor
    func testARefusedChainShowsTheRetry() async throws {
        let result = try await answer(["trust-contract/accept-gts-1-leaf-pingolindev.com",
                                       "trust-contract/leaked-EM_DV_TLS_CA_G3B-by-AAA",
                                       "trust-contract/root-AAA_Certificate_Services"], host: "note.pingolindev.com")
        XCTAssertEqual(result.disposition, .cancelAuthenticationChallenge, "refused")
        XCTAssertTrue(result.loadFailed, "the retry shows")
    }

    /// Our hosts' chain as served (GTS WE1, GTS Root R4, cross-signed by GlobalSign Root CA),
    /// evaluated on the day it was captured: accepted, and the editor is left alone.
    @MainActor
    func testAnAcceptedChainLeavesTheEditorAlone() async throws {
        let result = try await answer(["trust/pingolin-com-0", "trust/pingolin-com-1", "trust/pingolin-com-2"],
                                      host: "pingolin.com", date: "2026-10-25T12:00:00Z")
        XCTAssertEqual(result.disposition, .performDefaultHandling, "accepted")
        XCTAssertFalse(result.loadFailed, "no retry over a working editor")
    }
}

/// A server-trust protection space carrying a trust of the test's making.
private final class TrustSpace: URLProtectionSpace {
    private let trust: SecTrust

    init(_ trust: SecTrust) {
        self.trust = trust
        super.init(host: "note.pingolindev.com", port: 443, protocol: NSURLProtectionSpaceHTTPS, realm: nil,
                   authenticationMethod: NSURLAuthenticationMethodServerTrust)
    }

    required init?(coder: NSCoder) { nil }

    override var serverTrust: SecTrust? { trust }
}

private final class NoSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}
