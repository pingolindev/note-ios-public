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
import WebKit
import PingolinNoteSDK

/// The web shell's ONLY way to use this account's private keys.
///
/// The page is fetched live from the note origin on every launch, so whatever
/// the server — or anything in front of it — returns that day runs with
/// whatever the shell hands it. So it is never handed the X25519 sharing private
/// key (which also opens every Track circle-key wrap addressed to this account)
/// or the Ed25519 signing secret: it gets the vault key and the two PUBLIC keys
/// (`WebAppKeyHandoff`), and asks this bridge for the operations that need a
/// private key. The keys never leave the Keychain for the page; a malicious page
/// can use the bridge while it is being served, but cannot take the identity
/// with it.
///
/// Contract v1 (the Note web editor implements the page half — keep them in
/// step):
///
///     await window.webkit.messageHandlers.pingolinKeys.postMessage({op, ...})
///
///   op `openSealedKey`     {sealed}                          -> {key: b64 | null}
///   op `signShareWrap`     {senderUserId, recipientUserId,
///                           itemId, contentKeyVersion,
///                           wrappedKey}                      -> {signature: hex}
///   op `previousVaultKeys` {}                                -> {keys: [b64]}
///   op `keptTrust`         {v: 1, account}                   -> {v: 1, account, state: 'copy',
///                                                                 pins, floors, owners}
///                                                               | {v: 1, account, state: 'none'}
///                                                               | {v: 1, state: 'unreadable'}
///   op `keepTrust`         {v: 1, account, pins, floors,
///                           owners}                          -> {v: 1, state: 'kept'}
///
/// The last two are kept trust (the page's lib/keptTrust.ts, the Android app's
/// KeptWebTrustChannel): the account is the signed-in one in its one canonical
/// form or the request is refused, each blob is a string or null, and the
/// marker's `version` stays 1 — the page leaves bridge mode for anything else.
///
/// A request the bridge cannot serve rejects with one of `Failure`'s messages.
/// Every op is scoped to what Note needs and no more:
///  - `openSealedKey` opens only a libsodium sealed box addressed to this
///    account and returns only a 32-byte result — a Note share's content key.
///    Track's circle-key wraps are a different construction (ephemeral X25519 →
///    BLAKE3 → XChaCha20-Poly1305 with a random nonce) that a sealed-box open
///    cannot decrypt, so this is not a way into Track.
///  - `signShareWrap` never signs caller-chosen bytes: the SDK builds the
///    canonical `pingolin.sig.v1.note_share_invite` input from the fields, and
///    the sender must be the signed-in account.
///  - `previousVaultKeys` returns derived vault keys only, never the recovered
///    private keys they come from.
enum WebKeyBridge {
    static let handlerName = "pingolinKeys"
    static let version = 1

    /// Where key material comes from. Production reads the Keychain (`live`);
    /// tests inject their own.
    struct KeySource {
        var sharingPrivateKeyBase64: () -> String?
        var signingSeedBase64: () -> String?
        var userId: () -> String?
        var previousVaultKeys: () async -> [String]
        /// Kept trust: this account's copy, and keeping one.
        var keptTrust: (String) async -> KeptWebTrustStore.Kept = { _ in .unreadable }
        var keepTrust: (String, String?, String?, String?) async -> Bool = { _, _, _, _ in false }
    }

    enum Failure: String, Error {
        case originNotAllowed = "origin not allowed"
        case signedOut = "signed out"
        case invalidRequest = "invalid request"
        case unknownOp = "unknown op"
        case signingUnavailable = "signing unavailable"
        case senderMismatch = "sender mismatch"
        case notThisAccount = "not this account"
        case notKept = "not kept"
    }

    static let live = KeySource(
        sharingPrivateKeyBase64: { KeychainService.shared.getString(for: .sharingPrivateKey) },
        signingSeedBase64: { KeychainService.shared.getString(for: .signingPrivateKey) },
        userId: { KeychainService.shared.getString(for: .userId) },
        previousVaultKeys: {
            await previousVaultKeys(from: .shared, pageAsked: { await IdentityRecheck.shared.pageAsked() })
        },
        keptTrust: { await KeptWebTrustStore.shared.get($0) },
        keepTrust: { await KeptWebTrustStore.shared.keep($0, pins: $1, floors: $2, owners: $3) }
    )

    /// The page's op `previousVaultKeys`. The first call of a session is the
    /// start-up load. The page asks AGAIN only when it comes back with notes
    /// still locked: that is the locked signal this app lacks for notes it
    /// never cached, so a repeat call runs the gated re-check — at most one
    /// GET per window, however often the page asks. The load may await the
    /// network: if a sign-out or account switch happened meanwhile, hand the
    /// page nothing rather than what is now the next account's (the rule for
    /// every key load that awaits the network).
    static func previousVaultKeys(
        from loader: PreviousIdentityLoader,
        pageAsked: (@MainActor () async -> Void)?
    ) async -> [String] {
        let before = loader.currentGeneration
        let asksAgain = loader.isLoaded
        await loader.ensureLoaded()
        if asksAgain, let pageAsked { await pageAsked() }
        guard loader.currentGeneration == before else { return [] }
        return loader.vaultKeys()
    }

    /// Only the MAIN frame of exactly `origin` (scheme, host, effective port)
    /// may use the bridge. WKScriptMessage reports the origin of the frame
    /// that actually sent the message, which the page cannot forge.
    static func isAllowed(isMainFrame: Bool, scheme: String, host: String, port: Int, origin: String) -> Bool {
        guard isMainFrame,
              let expected = URLComponents(string: origin),
              let expectedScheme = expected.scheme?.lowercased(),
              let expectedHost = expected.host?.lowercased()
        else { return false }
        let defaultPort = expectedScheme == "https" ? 443 : (expectedScheme == "http" ? 80 : -1)
        let expectedPort = expected.port ?? defaultPort
        let actualPort = port == 0 ? defaultPort : port
        return scheme.lowercased() == expectedScheme
            && host.lowercased() == expectedHost
            && actualPort == expectedPort
    }

    /// Serve one request. `body` is what the page posted.
    static func handle(_ body: Any, keys: KeySource) async -> Result<[String: Any], Failure> {
        guard let request = body as? [String: Any], let op = request["op"] as? String else {
            return .failure(.invalidRequest)
        }
        guard keys.userId() != nil, let sharingPriv = keys.sharingPrivateKeyBase64() else {
            return .failure(.signedOut)
        }
        switch op {
        case "openSealedKey":
            guard let sealed = request["sealed"] as? String, sealed.count <= 4096,
                  Data(base64Encoded: sealed) != nil,
                  let priv = Data(base64Encoded: sharingPriv), priv.count == 32
            else { return .failure(.invalidRequest) }
            // Not opening is an answer, not an error: same contract as the
            // page's own unwrapContentKeyFromSender returning null.
            guard let key = PingolinNoteSDK.openSeal(wrappedB64: sealed, privateKey: priv), key.count == 32 else {
                return .success(["key": NSNull()])
            }
            return .success(["key": key.base64EncodedString()])

        case "signShareWrap":
            guard let sender = request["senderUserId"] as? String,
                  let recipient = request["recipientUserId"] as? String,
                  let itemId = request["itemId"] as? String,
                  let wrapped = request["wrappedKey"] as? String,
                  Data(base64Encoded: wrapped) != nil,
                  let version = uint32(request["contentKeyVersion"])
            else { return .failure(.invalidRequest) }
            guard let me = keys.userId(), sameUUID(sender, me) else { return .failure(.senderMismatch) }
            // 32-byte RFC 8032 seed normally; some accounts' blob held the
            // 64-byte seed||pub, which the SDK trims.
            guard let seedB64 = keys.signingSeedBase64(), let seed = Data(base64Encoded: seedB64),
                  seed.count == 32 || seed.count == 64
            else { return .failure(.signingUnavailable) }
            do {
                let signature = try PingolinNoteSDK.signNoteShareWrap(
                    secretSeed: seed,
                    params: NoteShareWrapParams(
                        // The page's own spelling of our id (checked equal to
                        // the signed-in account above), so the signed input is
                        // byte-for-byte what the page would have signed.
                        senderUserId: sender,
                        recipientUserId: recipient,
                        itemId: itemId,
                        contentKeyVersion: version,
                        wrappedKeyB64: wrapped
                    )
                )
                return .success(["signature": signature])
            } catch {
                return .failure(.invalidRequest)
            }

        case "previousVaultKeys":
            return .success(["keys": await keys.previousVaultKeys()])

        case "keptTrust", "keepTrust":
            return await keptTrust(op, request, keys: keys)

        default:
            return .failure(.unknownOp)
        }
    }

    /// Kept trust (the page's keptTrust.ts). Only for the signed-in
    /// account, named in its one form in every reply; a refusal is a rejection,
    /// which the page reads as no answer.
    private static func keptTrust(_ op: String, _ request: [String: Any],
                                  keys: KeySource) async -> Result<[String: Any], Failure> {
        guard let v = request["v"] as? NSNumber, CFGetTypeID(v) != CFBooleanGetTypeID(), v.doubleValue == 1 else {
            return .failure(.invalidRequest)
        }
        guard let me = CanonicalId.of(keys.userId()),
              let asked = request["account"] as? String, CanonicalId.of(asked) == me
        else { return .failure(.notThisAccount) }
        if op == "keptTrust" {
            switch await keys.keptTrust(me) {
            case .copy(let pins, let floors, let owners):
                return .success(["v": 1, "account": me, "state": "copy",
                                 "pins": pins ?? NSNull(), "floors": floors ?? NSNull(), "owners": owners ?? NSNull()])
            case .none:
                return .success(["v": 1, "account": me, "state": "none"])
            case .unreadable:
                return .success(["v": 1, "state": "unreadable"])
            }
        }
        var blobs: [String?] = []
        for name in KeptWebTrustStore.blobNames {
            switch request[name] {
            case nil, is NSNull: blobs.append(nil)
            case let blob as String: blobs.append(blob)
            default: return .failure(.invalidRequest)
            }
        }
        guard await keys.keepTrust(me, blobs[0], blobs[1], blobs[2]) else { return .failure(.notKept) }
        return .success(["v": 1, "state": "kept"])
    }

    /// A JS number that is an integer in 0...UInt32.max (never a boolean).
    private static func uint32(_ value: Any?) -> UInt32? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        guard d.isFinite, d >= 0, d <= Double(UInt32.max), d == d.rounded() else { return nil }
        return UInt32(d)
    }

    /// UUIDs compare with or without hyphens, in any case (as `uuidToBytes` reads them).
    private static func sameUUID(_ a: String, _ b: String) -> Bool {
        a.replacingOccurrences(of: "-", with: "").lowercased()
            == b.replacingOccurrences(of: "-", with: "").lowercased()
    }
}

/// WebKit adapter: origin gate, then `WebKeyBridge.handle`.
final class WebKeyBridgeHandler: NSObject, WKScriptMessageHandlerWithReply {
    private let origin: String
    private let keys: WebKeyBridge.KeySource

    init(origin: String, keys: WebKeyBridge.KeySource = WebKeyBridge.live) {
        self.origin = origin
        self.keys = keys
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        let frame = message.frameInfo
        let so = frame.securityOrigin
        guard WebKeyBridge.isAllowed(isMainFrame: frame.isMainFrame, scheme: so.protocol,
                                     host: so.host, port: so.port, origin: origin)
        else {
            replyHandler(nil, WebKeyBridge.Failure.originNotAllowed.rawValue)
            return
        }
        let body = message.body
        Task { @MainActor in
            switch await WebKeyBridge.handle(body, keys: keys) {
            case .success(let reply): replyHandler(reply, nil)
            case .failure(let failure): replyHandler(nil, failure.rawValue)
            }
        }
    }
}
