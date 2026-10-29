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
import Security
import XCTest
@testable import Note

/// No chain carrying a leaked emSign key is trusted, whatever the system says: the system evaluates
/// first, and `TrustBlocklist` refuses a chain it trusts when any certificate in it carries one of the
/// eight leaked keys or the emSign ECC Root CA - G3 key.
///
/// The certificates in Fixtures/trust are all public. Each leaked key is in two of them, both from
/// Mozilla's CCADB list of revoked intermediates: emSign's own issue, and Sectigo's cross-sign from
/// "AAA Certificate Services". The G3 root is there too. For contrast there is our hosts' chain as
/// served (pingolin.com: GTS WE1, GTS Root R4, cross-signed by GlobalSign Root CA) and a Let's Encrypt
/// one (valid-isrgrootx1.letsencrypt.org).
final class TrustBlocklistTests: XCTestCase {

    private func fixture(_ name: String) throws -> SecCertificate {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/trust/\(name).der")
        return try XCTUnwrap(SecCertificateCreateWithData(nil, try Data(contentsOf: url) as CFData), name)
    }

    private let leaked = ["EMDVTLSCAG3B", "EMDVTLSCAG3C", "EMEVTLSCAG3B", "EMEVTLSCAG3C",
                          "EMOVCSCAG3B", "EMOVCSCAG3C", "EMOVTLSCAG3B", "EMOVTLSCAG3C"]

    private func issuedBy(_ key: String) -> [String] {
        let root = key.hasPrefix("EMOVCS") ? "emSignRootCSCA-G3" : "emSignRootTLSCA-G3"
        return ["\(key)-by-\(root)", "\(key)-by-AAACertificateServices"]
    }

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    /// The list, key for key: the eight leaked emSign keys and the emSign ECC Root CA - G3 key.
    /// Not AAA: it still anchors sound Sectigo chains.
    func testTheListIsTheEightLeakedKeysAndTheG3Root() {
        XCTAssertEqual(TrustBlocklist.refusedKeys, [
            "ebed6475c2c2d80fcb199f3fe8dd6e6b3ce60b77eb15d4e42c3dec0c6f5b5105",
            "49dd353dc2b919a3770645117d0e60c16115e7d1bc259eefe734b00ea434fe5f",
            "e0254c7fcdc265e2f0f8a428dabb75ab4ae039b4872d62f5ee57f0877d5a8a41",
            "5c0660a2b164910d8ff589c18e14552e9e0ec237dcefe2cb736d41a4811f81a0",
            "ec4ffa1ad0ac88081314b7aaffef6a91f97cd57291bb5ba686c5415f5eb4f6b6",
            "92c063d67e8f14db71d288e11266ffdaf69cbf115f7bab14f3bc2f68d25e0e30",
            "43bffa19d6ef651451f6841e019931e96f6f2eaeff28ab4b6f1ce4576de2717b",
            "63ecefee431d49523bc1136c4e72d0206a477086caf606cd5cf025686c109cf8",
            "8d417db2dd8bf5e3084d1e3f196d583849d81bdd4c00c70b9d39369e96b8c782",
        ])
    }

    /// Every one of the sixteen public certificates carrying a leaked key is refused, whoever issued it (emSign's G3
    /// root, or AAA's cross-sign), and so is the G3 root.
    func testEveryCertificateOfALeakedKeyIsRefused() throws {
        let names = leaked.flatMap(issuedBy)
        XCTAssertEqual(names.count, 16)
        for name in names + ["emSign-ECC-Root-CA-G3"] {
            XCTAssertTrue(TrustBlocklist.carriesRefusedKey(try fixture(name)), name)
        }
    }

    /// Our hosts' chain and a Let's Encrypt one carry none, and every key in them is read.
    func testOurHostsChainAndALetsEncryptChainCarryNone() throws {
        for name in ["pingolin-com-0", "pingolin-com-1", "pingolin-com-2",
                     "letsencrypt-0", "letsencrypt-1", "letsencrypt-2"] {
            let certificate = try fixture(name)
            XCTAssertNotNil(TrustBlocklist.subjectPublicKeyInfo(in: SecCertificateCopyData(certificate) as Data), name)
            XCTAssertFalse(TrustBlocklist.carriesRefusedKey(certificate), name)
        }
    }

    /// The key is read whole, as openssl reads it: `openssl x509 -pubkey | openssl pkey -pubin -outform der |
    /// sha256sum` gives these for GTS Root R4 (an EC P-384 key, with its [0] version) and the G3 root.
    func testTheKeyIsReadWholeAsOpensslReadsIt() throws {
        for (name, expected) in [
            ("pingolin-com-2", "9847e5653e5e9e847516e5cb818606aa7544a19be67fd7366d506988e8d84347"),
            ("emSign-ECC-Root-CA-G3", "8d417db2dd8bf5e3084d1e3f196d583849d81bdd4c00c70b9d39369e96b8c782"),
        ] {
            let key = try XCTUnwrap(TrustBlocklist.subjectPublicKeyInfo(in: SecCertificateCopyData(try fixture(name)) as Data))
            XCTAssertEqual(SHA256Hex.of(key), expected, name)
        }
        XCTAssertNil(TrustBlocklist.subjectPublicKeyInfo(in: Data([0x30, 0x82, 0xff])), "a DER that can't be followed")
    }

    /// The rule: the system trusts the chain, and no certificate in it carries a refused key.
    func testAChainIsAcceptedOnlyWhenTheSystemTrustsItAndNoKeyIsRefused() throws {
        let ours = try ["pingolin-com-0", "pingolin-com-1", "pingolin-com-2"].map(fixture)
        XCTAssertTrue(TrustBlocklist.accepts(evaluated: true, chain: ours))
        XCTAssertFalse(TrustBlocklist.accepts(evaluated: false, chain: ours), "the system's no stands")
        for name in leaked.flatMap(issuedBy) {
            XCTAssertFalse(TrustBlocklist.accepts(evaluated: true, chain: [ours[0], try fixture(name), ours[2]]), name)
        }
    }

    /// A real evaluation of our hosts' chain for its name, on the day it was served and without the network: the
    /// system trusts it, and the check lets it through.
    func testOurHostsChainIsTrustedAndPassesTheCheck() throws {
        let chain = try ["pingolin-com-0", "pingolin-com-1", "pingolin-com-2"].map(fixture)
        var made: SecTrust?
        XCTAssertEqual(SecTrustCreateWithCertificates(chain as CFArray, SecPolicyCreateSSL(true, "pingolin.com" as CFString),
                                                      &made), errSecSuccess)
        let trust = try XCTUnwrap(made)
        SecTrustSetNetworkFetchAllowed(trust, false)
        SecTrustSetVerifyDate(trust, ISO8601DateFormatter().date(from: "2026-10-25T12:00:00Z")! as CFDate)
        let evaluated = SecTrustEvaluateWithError(trust, nil)
        XCTAssertTrue(evaluated)
        let built = SecTrustCopyCertificateChain(trust) as? [SecCertificate] ?? []
        XCTAssertFalse(built.isEmpty)
        XCTAssertTrue(TrustBlocklist.accepts(evaluated: evaluated, chain: built))
    }

    /// Every session the app makes asks the check: none is made outside `TrustBlocklist`, none uses
    /// `URLSession.shared`; and the web editor's server-trust challenges get the same check.
    func testEverySessionAndTheEditorAskTheCheck() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var offending: [String] = []
        for folder in ["App", "Shared", "NoteShareExt", "NoteWidgets"] {
            let files = try XCTUnwrap(FileManager.default.enumerator(at: root.appendingPathComponent(folder),
                                                                     includingPropertiesForKeys: nil))
                .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" && $0.lastPathComponent != "TrustBlocklist.swift" }
            for file in files {
                for (index, line) in try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n").enumerated() {
                    let code = line.trimmingCharacters(in: .whitespaces)
                    if code.hasPrefix("//") || code.hasPrefix("///") { continue }
                    if code.contains("URLSession(") || code.contains("URLSession.shared") {
                        offending.append("\(file.lastPathComponent):\(index + 1): \(code)")
                    }
                }
            }
        }
        XCTAssertEqual(offending, [], "a session without the leaked-key check")
        let block = try source("App/Services/TrustBlocklist.swift")
        XCTAssertTrue(block.contains("        URLSession(configuration: configuration, delegate: Delegate(), delegateQueue: nil)\n"))
        XCTAssertTrue(block.contains("            completionHandler(TrustBlocklist.answer(challenge), nil)\n"))
        XCTAssertTrue(block.contains("""
                let evaluated = SecTrustEvaluateWithError(trust, nil)
                let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate] ?? []
                return accepts(evaluated: evaluated, chain: chain) ? .performDefaultHandling : .cancelAuthenticationChallenge
        """))
        XCTAssertTrue(block.contains("""
                        let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate] ?? []
                        let accepted = accepts(evaluated: evaluated, chain: chain)
        """))
        XCTAssertTrue(try source("App/Services/APIService.swift")
            .contains("        self.session = TrustBlocklist.session(configuration: Self.makeSessionConfiguration())\n"))
        let shell = try source("App/Views/WebShellView.swift")
        XCTAssertTrue(shell.contains("""
                guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                      let trust = challenge.protectionSpace.serverTrust else {
                    completionHandler(.performDefaultHandling, nil)
                    return
                }
                TrustBlocklist.evaluate(trust) { [weak self] accepted in
                    if !accepted { self?.loadFailed = true }
                    completionHandler(accepted ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
                }
        """), "the editor's challenges; a refused one shows the retry")
    }

    /// The editor's path, run for real on a chain the system trusts: our hosts' chain is accepted, on the main
    /// thread.
    func testTheEditorsPathAcceptsOurHostsChain() throws {
        let chain = try ["pingolin-com-0", "pingolin-com-1", "pingolin-com-2"].map(fixture)
        var made: SecTrust?
        XCTAssertEqual(SecTrustCreateWithCertificates(chain as CFArray, SecPolicyCreateSSL(true, "pingolin.com" as CFString),
                                                      &made), errSecSuccess)
        let trust = try XCTUnwrap(made)
        SecTrustSetNetworkFetchAllowed(trust, false)
        SecTrustSetVerifyDate(trust, ISO8601DateFormatter().date(from: "2026-10-25T12:00:00Z")! as CFDate)
        let answered = expectation(description: "answered")
        TrustBlocklist.evaluate(trust) { accepted in
            XCTAssertTrue(accepted)
            XCTAssertTrue(Thread.isMainThread)
            answered.fulfill()
        }
        wait(for: [answered], timeout: 10)
    }
}

/// SHA-256, lowercase hex.
private enum SHA256Hex {
    static func of(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
