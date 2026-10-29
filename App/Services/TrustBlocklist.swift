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
import Foundation
import Security

/// Keys that no certificate chain to a server this app talks to may carry.
///
/// Eight emSign intermediate keys leaked. Each is in two certificates: one issued by emSign's G3 TLS or CS
/// root, and one cross-signed by Sectigo's "AAA Certificate Services", which Apple's store still trusts. So
/// system trust alone would accept a certificate for one of our hosts made with any of them: the session
/// token on every request, and the vault key the web editor is handed. The emSign ECC Root CA - G3 key is
/// refused too. Keys are matched by the SHA-256 of the certificate's SubjectPublicKeyInfo, so every
/// certificate carrying one is refused, whoever signed it. AAA itself is not on the list: it still anchors
/// other, sound Sectigo chains. CCADB lists all sixteen certificates as revoked.
///
/// It only ever takes trust away: the system evaluates the chain first, and a chain it trusts is refused when
/// any certificate in it carries one of these keys. No CA is pinned, so Cloudflare changing the CA that
/// issues our certificates breaks nothing. Every URLSession of the app is made here
/// (`session(configuration:)`, `shared`), with the delegate that asks; `URLSession.shared` can have none. The
/// web editor's challenges come here too (`evaluate`, from `WebShellModel`).
enum TrustBlocklist {
    /// SubjectPublicKeyInfo SHA-256, lowercase hex.
    static let refusedKeys: Set<String> = [
        "ebed6475c2c2d80fcb199f3fe8dd6e6b3ce60b77eb15d4e42c3dec0c6f5b5105", // EM DV TLS CA - G3B
        "49dd353dc2b919a3770645117d0e60c16115e7d1bc259eefe734b00ea434fe5f", // EM DV TLS CA - G3C
        "e0254c7fcdc265e2f0f8a428dabb75ab4ae039b4872d62f5ee57f0877d5a8a41", // EM EV TLS CA - G3B
        "5c0660a2b164910d8ff589c18e14552e9e0ec237dcefe2cb736d41a4811f81a0", // EM EV TLS CA - G3C
        "ec4ffa1ad0ac88081314b7aaffef6a91f97cd57291bb5ba686c5415f5eb4f6b6", // EM OV CS CA - G3B
        "92c063d67e8f14db71d288e11266ffdaf69cbf115f7bab14f3bc2f68d25e0e30", // EM OV CS CA - G3C
        "43bffa19d6ef651451f6841e019931e96f6f2eaeff28ab4b6f1ce4576de2717b", // EM OV TLS CA - G3B
        "63ecefee431d49523bc1136c4e72d0206a477086caf606cd5cf025686c109cf8", // EM OV TLS CA - G3C
        "8d417db2dd8bf5e3084d1e3f196d583849d81bdd4c00c70b9d39369e96b8c782", // emSign ECC Root CA - G3
    ]

    /// Whether a chain may be used: the system trusted it, and no certificate in it carries a refused key.
    static func accepts(evaluated: Bool, chain: [SecCertificate]) -> Bool {
        evaluated && !chain.contains(where: carriesRefusedKey)
    }

    /// Whether `certificate` carries one of the refused keys. One whose key can't be read counts as carrying one:
    /// the system has just accepted it, so its DER is sound, and a reader that can't follow it must not wave it
    /// through.
    static func carriesRefusedKey(_ certificate: SecCertificate) -> Bool {
        guard let key = subjectPublicKeyInfo(in: SecCertificateCopyData(certificate) as Data) else { return true }
        return refusedKeys.contains(SHA256.hash(data: key).map { String(format: "%02x", $0) }.joined())
    }

    /// A DER element: where it starts, where its content starts, where it ends.
    private struct Element {
        let start: Int
        let content: Int
        let end: Int
    }

    /// The SubjectPublicKeyInfo of an X.509 certificate's DER, whole (its tag and length too), as
    /// `openssl x509 -pubkey | openssl pkey -pubin -outform der` gives it; nil when the DER can't be followed.
    static func subjectPublicKeyInfo(in der: Data) -> Data? {
        let bytes = [UInt8](der)
        func element(at index: Int) -> Element? {
            guard index + 1 < bytes.count else { return nil }
            var length = Int(bytes[index + 1])
            var header = 2
            if length & 0x80 != 0 {
                let count = length & 0x7f
                guard count > 0, count <= 4, index + 2 + count <= bytes.count else { return nil }
                length = bytes[(index + 2)..<(index + 2 + count)].reduce(0) { $0 << 8 | Int($1) }
                header += count
            }
            guard index + header + length <= bytes.count else { return nil }
            return Element(start: index, content: index + header, end: index + header + length)
        }
        func children(of parent: Element) -> [Element]? {
            var found: [Element] = []
            var index = parent.content
            while index < parent.end {
                guard let child = element(at: index) else { return nil }
                found.append(child)
                index = child.end
            }
            return index == parent.end ? found : nil
        }
        // Certificate ::= SEQUENCE { tbsCertificate SEQUENCE { [0] version OPTIONAL, serialNumber, signature,
        // issuer, validity, subject, subjectPublicKeyInfo, ... }, ... }
        guard bytes.first == 0x30, let certificate = element(at: 0),
              let tbs = children(of: certificate)?.first, bytes[tbs.start] == 0x30,
              var fields = children(of: tbs) else { return nil }
        if let version = fields.first, bytes[version.start] == 0xa0 { fields.removeFirst() }
        guard fields.count > 5, bytes[fields[5].start] == 0x30 else { return nil }
        return Data(bytes[fields[5].start..<fields[5].end])
    }

    /// A challenge's answer. For server trust: the system's evaluation, then the keys of the chain it built; a
    /// chain that passes both is left to the system's own handling. Anything else is left to the system.
    static func answer(_ challenge: URLAuthenticationChallenge) -> URLSession.AuthChallengeDisposition {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else { return .performDefaultHandling }
        let evaluated = SecTrustEvaluateWithError(trust, nil)
        let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate] ?? []
        return accepts(evaluated: evaluated, chain: chain) ? .performDefaultHandling : .cancelAuthenticationChallenge
    }

    /// The same check for a challenge WebKit hands over (the editor's `webView(_:didReceive:completionHandler:)`):
    /// evaluated off the main thread, as an evaluation can fetch; `then` runs on the main thread.
    static func evaluate(_ trust: SecTrust, then: @escaping (Bool) -> Void) {
        let queue = DispatchQueue.global(qos: .userInitiated)
        queue.async {
            SecTrustEvaluateAsyncWithError(trust, queue) { trust, evaluated, _ in
                let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate] ?? []
                let accepted = accepts(evaluated: evaluated, chain: chain)
                DispatchQueue.main.async { then(accepted) }
            }
        }
    }

    /// A session that asks `answer` on every server-trust challenge.
    static func session(configuration: URLSessionConfiguration) -> URLSession {
        URLSession(configuration: configuration, delegate: Delegate(), delegateQueue: nil)
    }

    /// In place of `URLSession.shared`: the default configuration (so `URLCache.shared` too), with the check.
    static let shared = session(configuration: .default)

    /// The session delegate: every server-trust challenge goes to `answer`, on the session's own queue, never the
    /// main thread (an evaluation can fetch).
    final class Delegate: NSObject, URLSessionDelegate {
        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            completionHandler(TrustBlocklist.answer(challenge), nil)
        }
    }
}
