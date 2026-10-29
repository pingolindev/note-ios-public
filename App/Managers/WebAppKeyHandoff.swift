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
import Sodium
import PingolinNoteSDK

/// Builds the document-start script that hands the web app what it needs to
/// open notes without asking for the password again — and NOTHING that would
/// let it act as this account on its own.
///
/// The page is fetched live from the note origin, so it is whatever the server
/// returns when it loads. It gets (sessionStorage names are the cross-platform
/// contract with the Note web editor's `restoreFromSession()`, libsodium
/// ORIGINAL base64):
///
///   pingolin_note_session_key   note vault key
///   pingolin_note_sharing_pub   X25519 sharing PUBLIC key
///   pingolin_note_sign_public   Ed25519 PUBLIC key (when this device can sign)
///
/// and a marker, `window.__pingolinKeyBridge = {version: 1, signing: Bool}`,
/// telling it to ask `WebKeyBridge` for anything that needs a private key.
/// It is NOT given the X25519 sharing private key (which also opens this
/// account's Track circle keys) or the Ed25519 signing secret, which older
/// versions stored here as `pingolin_note_sharing_priv` /
/// `pingolin_note_sign_secret`. The script actively removes those two names,
/// so a value left in this tab by an older version cannot outlive it.
///
/// A push, never a pull: the values are written once at document start.
/// WKUserScript has no per-origin allowlist (Android's addDocumentStartJavaScript
/// does), so the script *self-guards* on `location.origin` as its first
/// statement — every other origin the WebView could visit (the account portal
/// above all) gets a script that returns before touching anything.
enum WebAppKeyHandoff {

    struct Keys {
        let vaultKeyB64: String
        let sharingPubB64: String
        /// Present when this device holds the account's real Ed25519 seed.
        let signPublicB64: String?
        var signingAvailable: Bool { signPublicB64 != nil }
    }

    /// The two sessionStorage names this build never writes, and removes.
    static let retiredPrivateKeyNames = ["pingolin_note_sharing_priv", "pingolin_note_sign_secret"]

    /// The Note web editor's client key: the wrapping key for the account's
    /// server-held encrypted private key (`/auth/client-key`). The page never
    /// uses it in this shell (bridge mode refuses that restore), but an earlier
    /// page could have left one in the store — older versions of the web
    /// editor kept it in LOCAL storage, where it outlives every session. The
    /// store is not cleared on update (it may hold unsynced edits), so the
    /// handoff removes this one value from both storages instead.
    static let legacyWrappingKeyName = "pingolin_note_client_key"

    /// Valid base64 cannot contain a quote, backslash or newline, so rather
    /// than escape into a JS string literal we refuse anything else outright —
    /// an unexpected character means something upstream is wrong, and building
    /// a script out of it is how an injection bug starts.
    private static let base64Pattern = "^[A-Za-z0-9+/]+={0,2}$"

    private static func valid(_ value: String?) -> Bool {
        guard let value else { return false }
        return value.range(of: base64Pattern, options: .regularExpression) != nil
    }

    /// Read what the page may have. nil when this device cannot open notes —
    /// no vault key, or no sharing PRIVATE key for the bridge to open shares
    /// with — in which case the shell must not load the page at all (a
    /// keyless page would mint a throwaway vault key); the caller sends the
    /// user to sign in again instead.
    static func collectKeys() -> Keys? {
        let keychain = KeychainService.shared
        guard let vault = keychain.getString(for: .vaultKey),
              let sharingPriv = keychain.getString(for: .sharingPrivateKey)
        else { return nil }

        // The public half is stored at login; an account from before it was
        // persisted has none, so derive it from the private scalar through the
        // SDK (never reimplemented here).
        let sodium = Sodium()
        var sharingPub = keychain.getString(for: .sharingPublicKey)
        if sharingPub == nil,
           let priv = sodium.utils.base642bin(sharingPriv, variant: .ORIGINAL),
           let hex = deriveSharingPublicKey(privateKey: Data(priv)),
           let pub = sodium.utils.hex2bin(hex) {
            sharingPub = sodium.utils.bin2base64(pub, variant: .ORIGINAL)
        }
        guard let sharingPub else { return nil }

        // Signing is optional: an account never provisioned with an Ed25519
        // seed has none, and the page then refuses to share rather than sign
        // with the wrong identity. The page only ever sees the PUBLIC key.
        var signPublic: String?
        if let seedB64 = keychain.getString(for: .signingPrivateKey),
           let raw = sodium.utils.base642bin(seedB64, variant: .ORIGINAL) {
            // Nominally the 32-byte seed, but some accounts' server blob stores
            // the FULL 64-byte secret (seed||pub): the public key is its tail.
            if raw.count == 32, let pair = sodium.sign.keyPair(seed: raw) {
                signPublic = sodium.utils.bin2base64(pair.publicKey, variant: .ORIGINAL)
            } else if raw.count >= 64 {
                signPublic = sodium.utils.bin2base64(Array(raw[32..<64]), variant: .ORIGINAL)
            }
        }

        return Keys(vaultKeyB64: vault, sharingPubB64: sharingPub, signPublicB64: signPublic)
    }

    /// Returns the script, or nil when there is nothing safe to hand over.
    /// `origin` is the ONLY origin allowed to see the values; it is compared
    /// against `location.origin` before anything is written.
    static func buildScript(keys: Keys?, origin: String) -> String? {
        guard let keys, valid(keys.vaultKeyB64), valid(keys.sharingPubB64) else { return nil }
        let signPublic = valid(keys.signPublicB64) ? keys.signPublicB64 : nil

        var body = ""
        for name in retiredPrivateKeyNames + [legacyWrappingKeyName] { body += "s.removeItem('\(name)');" }
        func set(_ key: String, _ value: String) { body += "s.setItem('\(key)','\(value)');" }
        set("pingolin_note_session_key", keys.vaultKeyB64)
        set("pingolin_note_sharing_pub", keys.sharingPubB64)
        if let signPublic {
            set("pingolin_note_sign_public", signPublic)
        } else {
            body += "s.removeItem('pingolin_note_sign_public');"
        }
        body += "window.__pingolinKeyBridge=Object.freeze({version:\(WebKeyBridge.version),signing:\(signPublic != nil)});"

        // The origin guard first, outside everything. Then swallow failures —
        // a thrown exception at document start would take the whole page down —
        // with localStorage in its own block, so a store that refuses access
        // cannot cost the page its keys.
        return "(function(){if(location.origin!=='\(origin)')return;" +
            "try{var s=window.sessionStorage;\(body)}catch(e){}" +
            "try{window.localStorage.removeItem('\(legacyWrappingKeyName)');}catch(e){}})();"
    }
}
