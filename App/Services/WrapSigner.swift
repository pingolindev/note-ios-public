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
import PingolinNoteSDK

/// Per-note share wrap verification via the SDK's `verify_note_share_wrap_gen`,
/// for a share this account receives. The wraps this account sends are signed
/// by the page, through `WebKeyBridge` (op `signShareWrap`).
enum WrapSigner {
    /// Verification helper for an inbound share: returns a verdict, it does
    /// not itself accept or reject. The verdict is consumed by
    /// `SharesInboxStore.decide` as a FAIL-CLOSED gate — for a pinned
    /// sender a stripped, invalid, or rolled-back signature DROPS the share
    /// (it is never unwrapped), matching android's fail-closed
    /// `verifyNoteShareWrap` usage (`if (ok != true)`).
    @MainActor
    static func verifyInboundGen(
        signingPubkeyHex: String,
        signatureHex: String,
        senderUserId: String,
        recipientUserId: String,
        itemId: String,
        contentKeyVersion: UInt32,
        wrappedKeyB64: String
    ) -> (verified: Bool, effectiveGeneration: UInt32)? {
        do {
            // Verify-both: tries this generation, then legacy 0. Returns the
            // generation the sig ACTUALLY verified under — the passed version,
            // or 0 on the legacy fallback (never the caller-claimed value), so
            // the reader's rollback floor can't be laundered by a relabelled
            // legacy-0 wrap. nil ⇒ the SDK threw on malformed inputs.
            let r = try verifyNoteShareWrapGen(
                signingPubkeyHex: signingPubkeyHex,
                signatureHex: signatureHex,
                params: NoteShareWrapParams(
                    senderUserId: senderUserId,
                    recipientUserId: recipientUserId,
                    itemId: itemId,
                    contentKeyVersion: contentKeyVersion,
                    wrappedKeyB64: wrappedKeyB64
                )
            )
            return (r.verified, r.effectiveGeneration)
        } catch {
            #if DEBUG
            print("[Note] verifyNoteShareWrapGen threw: \(error)")
            #endif
            return nil
        }
    }
}
