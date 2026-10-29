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
import OSLog
import PingolinNoteSDK

/// Shared-with-me notes, materialized from the shares inbox.
///
/// iOS analog of android SharesInboxRepository's content-key registry
/// plus its share materialization:
/// `/sync/pull` never delivers shared items — the recipient's sync
/// watermark is only bumped by writes to their OWN items — so the
/// inbox payload (which already carries each note's encrypted_content
/// + content_nonce + a content key sealed to us) is the row source.
/// `refresh()` unwraps each share's content key, decrypts, and
/// synthesizes a server-shaped `Item` for each.
///
/// The content keys held here are also the ONLY correct way to encrypt
/// an edit of a shared note. The vault path would mint a recipient
/// wrap, and PUTting any wrap value (even "") would overwrite the
/// owner's wrapped_content_key server-side and lock the owner — and
/// every other recipient — out of the note. Shared-note updates must
/// omit the wrap fields entirely (android NoteRepository.updateSharedNote).
@MainActor
final class SharesInboxStore: ObservableObject {
    static let shared = SharesInboxStore()

    struct SharedNote: Identifiable {
        let item: Item
        /// The inbound share row id (`InboxShareResponse.shareId`),
        /// distinct from `item.id` (the note id). Needed to dismiss THIS share via
        /// `POST /shares/inbox/{shareId}/dismiss` — the row's `id` is the item id.
        let shareId: String
        let note: DecodedNote?        // nil when key-unseal or decrypt failed
        let decryptError: String?
        let ownerEmail: String?
        let permission: String
        var id: String { item.id }
    }

    enum RefreshError: LocalizedError {
        case missingSharingKeys
        var errorDescription: String? { "no sharing keys" }
    }

    /// itemId → materialized share. Replaced wholesale by `refresh()`;
    /// kept on failure so a network blip doesn't blank the list.
    @Published private(set) var sharedNotes: [String: SharedNote] = [:]

    /// A share sender whose current directory key no longer matches the key
    /// we TOFU-pinned; their shares are dropped until the user compares the
    /// safety number out-of-band and approves the rotated key.
    struct KeyChangeAlarm: Identifiable {
        var id: String { ownerId }
        let ownerId: String
        let email: String?
        let newSigningPub: String
        let newSharingPub: String?
        let safetyNumber: String?
        let affectedCount: Int
    }
    @Published private(set) var keyChangeAlarms: [KeyChangeAlarm] = []

    /// An incoming share this client refused to open, with the reason.
    ///
    /// Refusing an unverifiable wrap is the right verdict; refusing it in
    /// silence is not — the recipient would see an inbox that simply looks
    /// empty while the sender is told the share went through. None of these
    /// are unwrapped; the user is told a note exists and what to do.
    struct BlockedShare: Identifiable {
        var id: String { shareId }
        let shareId: String
        let itemId: String
        let ownerId: String
        let ownerEmail: String?
        /// Human-readable, actionable reason.
        let reason: String
    }
    @Published private(set) var blockedShares: [BlockedShare] = []

    /// itemId → unwrapped content key (android
    /// SharesInboxRepository.getContentKey). Only populated for shares
    /// whose seal opened — entries here are safe to encrypt with.
    private var contentKeys: [String: [UInt8]] = [:]

    /// By the item id's one form: the registry is keyed that way.
    func contentKey(for itemId: String) -> [UInt8]? { CanonicalId.of(itemId).flatMap { contentKeys[$0] } }
    func isShared(_ itemId: String) -> Bool { contentKey(for: itemId) != nil }

    /// Full teardown for `AuthManager.logout()`: drop every piece of decrypted,
    /// account-scoped state — materialized shared notes (plaintext titles/bodies),
    /// unwrapped content keys, and stale key-change alarms — so account A's
    /// shared content can't linger in memory for account B on the same device.
    func reset() {
        sharedNotes = [:]
        keyChangeAlarms = []
        blockedShares = []
        contentKeys = [:]
    }

    /// Pull the inbox and rebuild the registry. Mirrors android
    /// SharesInboxRepository.refresh() + materializeSharedNotes().
    func refresh(sharingPrivateKeyBase64: String?, sharingPublicKey: String?) async throws {
        guard let priv = sharingPrivateKeyBase64, let pub = sharingPublicKey else {
            throw RefreshError.missingSharingKeys
        }
        // This account's own id first, in its one form, from the stored `.userId`:
        // the pins, floors and item owners below are its, and the SDK binds it into
        // every wrap signature. Without one — none stored, or a Keychain read that
        // failed — nothing is fetched, decided or written. (Not `currentUser`: a
        // cold launch may not have set it yet, and every share would then go to
        // first contact.)
        guard let me = CanonicalId.of(KeychainService.shared.getString(for: .userId)) else { return }
        // Both trust stores are read before anything is decided. One that can't
        // be read is never "none": the inbox stays as it was, and the next
        // refresh reads it again.
        do {
            try SenderKeyPinStore.shared.ensureReadable()
            try NoteGenFloorStore.shared.ensureReadable()
        } catch {
            Self.log.error("INBOX NOT REFRESHED: a stored trust record (pins, rollback floors or item owners) can't be read; nothing was fetched, opened or changed: \(String(describing: error), privacy: .public)")
            return
        }
        let inbox = try await APIService.shared.listInbox()
        // The account is checked again after every await: a sign-out or another
        // account's sign-in landing in one must not have this refresh decide or
        // write anything. `priv` is captured by value into the detached unwrap
        // below, so without these checks account A's decrypted shares could be
        // published into B's registry and A's senders pinned into B's store.
        guard Self.acting(me) else { return }
        // The senders' directory keys come BEFORE the verdict: they count
        // only when the entry an e-mail finds names that share's owner.
        let myEmail = AuthManager.shared.currentUser?.email.lowercased()
        let directory = await Self.lookupDirectory(emails: inbox.compactMap { $0.ownerEmail } + [myEmail].compactMap { $0 })
        guard Self.acting(me) else { return }

        let vaults = Self.ourVaults()
        let verdict: Verdict
        do {
            verdict = try Self.decide(inbox, me: me, directory: directory, trust: .live(vaults: vaults))
        } catch {
            Self.log.error("INBOX NOT REFRESHED: a stored trust record (pins, rollback floors or item owners) can't be read; no share was opened or published: \(String(describing: error), privacy: .public)")
            return
        }

        // The per-share unwrap+decrypt below runs a sealed-box open (X25519) +
        // XChaCha20-Poly1305 decrypt + JSON decode; on a large inbox that janks
        // the main actor. Do it off-main and republish the result on MainActor.
        // Only the shares the verdict let through are ever unwrapped.
        let admitted = verdict.admitted.map(\.share)
        let (notes, keys, noteNotebooks, opened) = await Task.detached {
            Self.decryptInbox(admitted, sharingPrivateKeyBase64: priv, sharingPublicKey: pub)
        }.value
        guard Self.acting(me) else { return }
        sharedNotes = notes
        contentKeys = keys
        blockedShares = verdict.blocked
        noteShareNotebooks = noteNotebooks

        // A first contact that opened TOFU-pins its sender's directory keys and
        // binds its item; a pinned sender's changed directory keys raise
        // the key-change alarm. No await follows, so these writes run for the
        // account checked just above.
        keyChangeAlarms = Self.afterOpening(verdict, opened: opened, directory: directory, me: me, myEmail: myEmail)
    }

    private static let log = Logger(subsystem: "com.pingolin.note", category: "inbox")

    /// Is `me` still the account signed in here, by the stored `.userId`?
    private static func acting(_ me: String) -> Bool {
        CanonicalId.of(KeychainService.shared.getString(for: .userId)) == me
    }

    /// A sender's keys as the directory publishes them; `userId` is the account
    /// the entry names.
    struct DirectoryKeys: Equatable {
        let userId: String?
        let signingPub: String
        let sharingPub: String?
    }

    /// One batch lookup of every sender's directory keys, by lower-cased e-mail.
    /// Senders it can't resolve have no entry: their shares stay first contacts
    /// with nothing to pin.
    private static func lookupDirectory(emails: [String]) async -> [String: DirectoryKeys] {
        let unique = Array(Set(emails.map { $0.lowercased() }))
        guard !unique.isEmpty,
              let resp = try? await APIService.shared.lookupPublicKeys(emails: unique) else { return [:] }
        var out: [String: DirectoryKeys] = [:]
        for entry in resp.users {
            guard let signing = entry.signingPublicKey else { continue }
            out[entry.email.lowercased()] = DirectoryKeys(userId: entry.userId, signingPub: signing, sharingPub: entry.sharingPublicKey)
        }
        return out
    }

    /// One share the verdict lets through.
    struct Admitted {
        /// The share, its item and owner ids in their one form.
        let share: InboxShareResponse
        /// Its owner had no pin when it was graded: a first contact, pinned and
        /// its item bound once it opens.
        let firstContact: Bool
        /// The owner's directory keys, when the entry names that owner.
        let dirKeys: DirectoryKeys?
    }

    /// What one refresh decided, before any key was touched.
    struct Verdict {
        var admitted: [Admitted] = []
        var blocked: [BlockedShare] = []
        /// Pinned owners whose directory keys differ from the pin: the keys, the
        /// e-mail, and how many of their shares were refused against the pin.
        var changedKeys: [String: (keys: DirectoryKeys, email: String?, refused: Int)] = [:]
    }

    /// What the verdict reads and writes, injected so the tests drive the real
    /// rules against real stores.
    struct Trust {
        var pinned: (String) throws -> SenderKeyPinStore.PinRecord?
        var owner: (String) throws -> String?
        var floor: (String) throws -> Int64
        var accept: (_ item: String, _ owner: String, _ generation: Int64) throws -> Void
        var verify: @MainActor (_ signingPubHex: String, _ signatureHex: String, _ sender: String, _ recipient: String,
                                _ item: String, _ generation: UInt32, _ wrapped: String) -> (verified: Bool, effectiveGeneration: UInt32)?
        /// This device's row with that id, if any.
        var row: (String) -> ItemRecord?
        /// A wrap on the row opens under one of this account's vault keys.
        var opensUnderOurVault: (ItemRecord) -> Bool

        static func live(vaults: [String]) -> Trust {
            Trust(
                pinned: { try SenderKeyPinStore.shared.getPinned($0) },
                owner: { try NoteGenFloorStore.shared.owner($0) },
                floor: { try NoteGenFloorStore.shared.floor($0) },
                accept: { try NoteGenFloorStore.shared.accept($0, owner: $1, generation: $2) },
                verify: { WrapSigner.verifyInboundGen(signingPubkeyHex: $0, signatureHex: $1, senderUserId: $2, recipientUserId: $3, itemId: $4, contentKeyVersion: $5, wrappedKeyB64: $6) },
                row: { NoteStore.shared.fetchById($0) },
                opensUnderOurVault: { SharesInboxStore.opensUnder($0, vaults: vaults) }
            )
        }
    }

    /// This account's vault keys: the current one and every recovered identity's
    /// (the keys the pull's decrypt tries).
    private static func ourVaults() -> [String] {
        [KeychainService.shared.getString(for: .vaultKey)].compactMap { $0 } + PreviousIdentityLoader.shared.vaultKeys()
    }

    /// One of `vaults` opens `row`: a wrap on it, or, for a row with no wrap (a
    /// note from before per-note keys, which is never shared), its body itself.
    /// It is ours, whatever its user id says.
    nonisolated static func opensUnder(_ row: ItemRecord, vaults: [String]) -> Bool {
        guard let wrap = row.wrappedContentKey, let nonce = row.wrappedContentKeyNonce else {
            return vaults.contains { vault in
                guard let key = Data(base64Encoded: vault) else { return false }
                return (try? NoteCrypto.decryptItem(row.encryptedContent, contentNonce: row.contentNonce,
                                                    contentKey: Array(key), itemId: row.id)) != nil
            }
        }
        return vaults.contains { NoteCrypto.unwrapRetiredContentKeyBase64(wrap: wrap, nonce: nonce, vaultKeyBase64: $0) != nil }
    }

    /// Is `row` a share's: the inbox holds a key for its id, and it isn't one of
    /// ours? A note is sent as what opened it. The refresh refuses a share of a
    /// row it can see, but it runs before the pull, so one of ours can land
    /// while the inbox still names its id. The drain asks this, never
    /// `isShared(id)` alone.
    func isSharedWithUs(_ row: ItemRecord) -> Bool {
        Self.isSharesRow(row, inboxNamesIt: isShared(row.id),
                         me: CanonicalId.of(KeychainService.shared.getString(for: .userId)), vaults: Self.ourVaults())
    }

    /// `isSharedWithUs`'s rule: named by the inbox, and neither this account's by
    /// its user id nor opened by one of its vault keys. With no own id, nothing
    /// is a share's (the drain doesn't run signed out).
    nonisolated static func isSharesRow(_ row: ItemRecord, inboxNamesIt: Bool, me: String?, vaults: [String]) -> Bool {
        guard inboxNamesIt, let me else { return false }
        return !(CanonicalId.same(row.userId, me) || opensUnder(row, vaults: vaults))
    }

    private static let notConfirmed = "This share couldn't be confirmed as coming from its sender, so it wasn't opened. Ask them to share it again."
    private static let forged = "This share couldn't be confirmed as coming from its sender, so it wasn't opened. Check with them another way before trusting a new copy."
    private static let damaged = "This share is damaged, so it couldn't be opened. Ask the sender to share it again."
    private static let outOfDate = "This share is out of date, so it wasn't opened. Ask the sender to share it again."

    /// The verdict for every inbound share, decided BEFORE any key material is
    /// touched. A share is refused — never unwrapped, decrypted or published —
    /// when:
    /// - its owner or item id isn't a UUID (every id below is canonical);
    /// - it names this account as its sender, or an item this device holds that
    ///   isn't that owner's: one of ours by its user id or by a wrap our vault
    ///   opens, or another owner's;
    /// - its item is bound to another owner, or it is unbound and named by two
    ///   owners in this refresh;
    /// - it is a first contact whose directory entry names another account;
    /// - its owner is pinned and the wrap's signature is missing, doesn't verify
    ///   against the PIN (never a key the server hands us), or is below the
    ///   item's floor.
    /// A share verified against its owner's pin binds its item and raises its
    /// floor (in one call). Throws when a store can't be read: the caller
    /// stops, and nothing it decided is published.
    static func decide(_ inbox: [InboxShareResponse], me: String, directory: [String: DirectoryKeys], trust: Trust) throws -> Verdict {
        var verdict = Verdict()
        func block(_ share: InboxShareResponse, _ reason: String) {
            verdict.blocked.append(BlockedShare(
                shareId: share.shareId, itemId: share.itemId, ownerId: share.ownerId,
                ownerEmail: share.ownerEmail, reason: reason
            ))
        }
        // The pair rule: an unbound item named by shares from two different
        // owners in this one refresh is bound to nobody this time, and each of
        // those shares is refused — nothing says which came first.
        var ownersNaming: [String: Set<String>] = [:]
        for share in inbox {
            guard let item = CanonicalId.of(share.itemId), let owner = CanonicalId.of(share.ownerId),
                  try trust.owner(item) == nil else { continue }
            ownersNaming[item, default: []].insert(owner)
        }
        for served in inbox {
            guard let owner = CanonicalId.of(served.ownerId) else { block(served, notConfirmed); continue }
            guard let item = CanonicalId.of(served.itemId) else { block(served, damaged); continue }
            let share = served.withIds(item: item, owner: owner)

            // Never a share from this account itself, and never one of an item
            // this device holds that isn't that owner's.
            if owner == me { block(share, notConfirmed); continue }
            if let row = trust.row(item) {
                let ours = CanonicalId.same(row.userId, me) || trust.opensUnderOurVault(row)
                if ours || !CanonicalId.same(row.userId, owner) {
                    log.warning("REFUSING a share of an item this device holds as someone else's itemId=\(item, privacy: .public)")
                    block(share, notConfirmed)
                    continue
                }
            }

            // Bound to its owner, or unbound and named by one owner.
            if let bound = try trust.owner(item) {
                guard bound == owner else { block(share, notConfirmed); continue }
            } else if (ownersNaming[item]?.count ?? 0) > 1 {
                block(share, notConfirmed)
                continue
            }

            // The directory keys count only when the entry names this owner.
            let entry = share.ownerEmail.flatMap { directory[$0.lowercased()] }
            let dirKeys = entry.flatMap { CanonicalId.same($0.userId, owner) ? $0 : nil }
            let pinned = try trust.pinned(owner)
            if entry != nil, dirKeys == nil, pinned == nil { block(share, notConfirmed); continue }

            guard let pinned else {
                // GRACE: an unpinned owner is a first contact (TOFU). It is
                // unwrapped; its sender is pinned and its item bound once it opens.
                verdict.admitted.append(Admitted(share: share, firstContact: true, dirKeys: dirKeys))
                continue
            }
            // A pinned owner's changed directory keys raise the key-change alarm.
            if let dirKeys, dirKeys.signingPub.lowercased() != pinned.signingPubHex.lowercased()
                || (dirKeys.sharingPub != nil && pinned.sharingPubHex != nil
                    && dirKeys.sharingPub?.lowercased() != pinned.sharingPubHex?.lowercased()) {
                let held = verdict.changedKeys[owner]
                verdict.changedKeys[owner] = (dirKeys, share.ownerEmail, held?.refused ?? 0)
            }
            func refusedAgainstThePin(_ reason: String) {
                block(share, reason)
                if let held = verdict.changedKeys[owner] {
                    verdict.changedKeys[owner] = (held.keys, held.email, held.refused + 1)
                }
            }
            guard let sig = share.wrapSignature else { refusedAgainstThePin(notConfirmed); continue }
            guard let wrapped = share.wrappedKey else {
                // Signature but no wrapped key: nothing to verify or unwrap;
                // decryptInbox reports the missing key.
                verdict.admitted.append(Admitted(share: share, firstContact: false, dirKeys: dirKeys))
                continue
            }
            let result = pinned.signingPubHex == SenderKeyPinStore.conflictKeyHex ? nil : trust.verify(
                pinned.signingPubHex, sig, owner, me, item,
                UInt32(truncatingIfNeeded: share.contentKeyGeneration ?? 1), wrapped
            )
            guard let result, result.verified else { refusedAgainstThePin(forged); continue }
            let generation = Int64(result.effectiveGeneration)
            let floor = try trust.floor(item)
            if generation > 0 && generation < floor { refusedAgainstThePin(outOfDate); continue }
            // Verified against the owner's pin: the item is theirs, and a real
            // generation raises its floor (one call).
            try trust.accept(item, owner, generation)
            verdict.admitted.append(Admitted(share: share, firstContact: false, dirKeys: dirKeys))
        }
        return verdict
    }

    /// Unwrap + decrypt every share the verdict let through. `nonisolated` so
    /// `refresh()` can run it off the main actor via `Task.detached`; it returns
    /// plain value types the caller republishes on MainActor. `opened` holds the
    /// items whose content decrypted. Mirrors android SharesInboxRepository.refresh()'s
    /// per-share unwrap + decrypt loop.
    private nonisolated static func decryptInbox(
        _ inbox: [InboxShareResponse],
        sharingPrivateKeyBase64 priv: String,
        sharingPublicKey pub: String
    ) -> (
        notes: [String: SharedNote],
        keys: [String: [UInt8]],
        noteNotebooks: [String: String],
        opened: Set<String>
    ) {
        var notes: [String: SharedNote] = [:]
        var keys: [String: [UInt8]] = [:]
        // Share id -> the notebook each shared NOTE says it belongs to.
        var noteNotebooks: [String: String] = [:]
        var opened: Set<String> = []
        for share in inbox {
            var decoded: DecodedNote?
            var decryptError: String?
            if let wrapped = share.wrappedKey {
                do {
                    let key = try NoteCrypto.openSealedContentKey(
                        wrappedB64: wrapped,
                        sharingPrivateKeyBase64: priv,
                        sharingPublicKey: pub
                    )
                    keys[share.itemId] = key
                    let plaintext = try NoteCrypto.decryptItem(
                        share.encryptedContent,
                        contentNonce: share.contentNonce,
                        contentKey: key,
                        itemId: share.itemId
                    )
                    decoded = try DecodedNote.decode(from: plaintext)
                    opened.insert(share.itemId)
                } catch {
                    decryptError = error.localizedDescription
                }
            } else {
                decryptError = "share missing wrapped_key"
            }
            // A NOTEBOOK never becomes a note. The notebook object carries a
            // collection's name and its roster, not a document, so listing it
            // here puts a phantom note titled with the notebook's name in the
            // recipient's list. Its content key is still kept above, in the
            // keys `isShared` reads.
            if share.isNotebook {
                continue
            }
            // Remember which notebook each shared NOTE claims, so declining a
            // notebook can take its notes with it. Read from the note's OWN
            // content: `items.notebook_id` names a notebook in the SENDER's
            // account and is not the recipient's to act on.
            // `notebook_id` is not a DecodedNote field — unknown keys land in
            // `extras` verbatim, so it is read from there. Both spellings are
            // checked: the decoder converts snake_case for KNOWN keys only, and
            // which form survives into extras is not something to guess at.
            if case .string(let nb)? = decoded?.extras["notebook_id"] ?? decoded?.extras["notebookId"],
               !nb.isEmpty {
                noteNotebooks[share.shareId] = nb
            }
            notes[share.itemId] = SharedNote(
                item: synthesizeItem(from: share),
                shareId: share.shareId,
                note: decoded,
                decryptError: decryptError,
                ownerEmail: share.ownerEmail,
                permission: share.permission
            )
        }
        return (notes, keys, noteNotebooks, opened)
    }

    /// After the shares opened: a first contact whose content decrypted TOFU-pins
    /// its sender's directory keys (the entry that names that owner) and
    /// binds its item to that owner; a pinned owner whose directory keys
    /// changed gets a key-change alarm, with the symmetric safety number when
    /// this account's own directory keys are known. A pin is never overwritten:
    /// a changed key goes through out-of-band approval. A store that can't be
    /// written now is logged; the next refresh tries again.
    static func afterOpening(
        _ verdict: Verdict, opened: Set<String>, directory: [String: DirectoryKeys], me: String, myEmail: String?,
        pin: (_ owner: String, _ keys: DirectoryKeys) throws -> Void = {
            try SenderKeyPinStore.shared.pin(ownerId: $0, signingPubHex: $1.signingPub, sharingPubHex: $1.sharingPub)
        },
        bind: (_ item: String, _ owner: String) throws -> Void = {
            try NoteGenFloorStore.shared.accept($0, owner: $1)
        }
    ) -> [KeyChangeAlarm] {
        for admitted in verdict.admitted where admitted.firstContact && opened.contains(admitted.share.itemId) {
            let share = admitted.share
            do {
                if let keys = admitted.dirKeys { try pin(share.ownerId, keys) }
                try bind(share.itemId, share.ownerId)
            } catch {
                log.error("a first share's sender or owner was not recorded this time: \(String(describing: error), privacy: .public)")
            }
        }
        let mine = myEmail.flatMap { directory[$0] }
        return verdict.changedKeys.map { owner, changed in
            let sas: String? = {
                guard let mine, let selfSharing = mine.sharingPub, let peerSharing = changed.keys.sharingPub else { return nil }
                return try? computeNoteSafetyNumber(
                    selfUserId: me,
                    selfSharingPubkeyHex: selfSharing,
                    selfSigningPubkeyHex: mine.signingPub,
                    peerUserId: owner,
                    peerSharingPubkeyHex: peerSharing,
                    peerSigningPubkeyHex: changed.keys.signingPub
                )
            }()
            return KeyChangeAlarm(
                ownerId: owner,
                email: changed.email,
                newSigningPub: changed.keys.signingPub,
                newSharingPub: changed.keys.sharingPub,
                safetyNumber: sas,
                affectedCount: changed.refused
            )
        }
    }

    /// Re-pin a sender's rotated keys after the user confirmed the safety
    /// number out-of-band, then re-run refresh so the shares dropped against
    /// the OLD pin verify + materialize under the new pin. The only in-app
    /// recovery from a legitimate sender key rotation.
    func approveKeyChange(_ alarm: KeyChangeAlarm) async {
        do {
            try SenderKeyPinStore.shared.approve(
                ownerId: alarm.ownerId,
                newSigningPubHex: alarm.newSigningPub,
                newSharingPubHex: alarm.newSharingPub
            )
        } catch {
            // Nothing approved: the alarm stays for another try.
            Self.log.error("a changed key was not approved: \(String(describing: error), privacy: .public)")
            return
        }
        keyChangeAlarms.removeAll { $0.ownerId == alarm.ownerId }
        try? await refresh(
            sharingPrivateKeyBase64: AuthManager.shared.sharingPrivateKeyBase64,
            sharingPublicKey: AuthManager.shared.sharingPublicKey
        )
    }

    /// Hide an alarm without approving (its shares stay dropped). Reappears
    /// on the next refresh while the server still advertises the changed key.
    func dismissKeyChange(ownerId: String) {
        keyChangeAlarms.removeAll { $0.ownerId == ownerId }
    }

    /// Recipient consent: DISMISS a single shared note. Marks the inbound share
    /// row dismissed server-side (drops it from the inbox + stops re-push), then
    /// removes it from the materialized registry so the row disappears at once.
    /// `shareId` is the inbox row id (`SharedNote.shareId`); `itemId` keys the
    /// registry. Throws on API failure so the caller can surface it and the local
    /// drop only happens once the server actually dismissed.
    func dismissShare(shareId: String, itemId: String) async throws {
        try await APIService.shared.dismissInboxShare(shareId)
        let item = CanonicalId.of(itemId) ?? itemId
        sharedNotes.removeValue(forKey: item)
        contentKeys.removeValue(forKey: item)
    }

    /// Recipient consent: BLOCK a sender by email. The server records the block
    /// and retroactively dismisses every current inbound share from that email
    /// (future ones auto-dismiss at write time), so we drop every materialized
    /// row from that sender locally to match. Case-insensitive on the email, as
    /// the server is. Throws on API failure (no local drop then).
    func blockSender(ownerEmail: String) async throws {
        try await APIService.shared.blockShareSender(email: ownerEmail)
        let target = ownerEmail.lowercased()
        // Collect keys first — never mutate the dictionary while iterating it.
        let victims = sharedNotes.filter { $0.value.ownerEmail?.lowercased() == target }.map(\.key)
        for itemId in victims {
            sharedNotes.removeValue(forKey: itemId)
            contentKeys.removeValue(forKey: itemId)
        }
    }

    /// Share id -> the notebook that share's NOTE claims. Lets declining a
    /// notebook take the notes that came inside it.
    private(set) var noteShareNotebooks: [String: String] = [:]

    /// The inbox share ids of the notes that came inside `notebookId`.
    func noteShareIds(inNotebook notebookId: String) -> [String] {
        noteShareNotebooks.filter { $0.value == notebookId }.map(\.key)
    }

    /// Server-shaped row for a share that `/sync/pull` never delivers.
    /// Mirrors android materializeSharedNotes(): owned by the sharer,
    /// and NO wrapped_content_key — decryption goes through the
    /// inbox-held content key, never the recipient's vault. Version
    /// defaults to 1 (the inbox payload carries none); reconcile()
    /// adopts the real version from the pulled copy when there is one,
    /// so an edit sends the right expected_version and skips the 409.
    nonisolated static func synthesizeItem(from share: InboxShareResponse) -> Item {
        Item(
            id: share.itemId,
            userId: share.ownerId,
            // Notebook shares are skipped before this point, so anything
            // synthesized here is a note.
            itemType: ItemType.note.rawValue,
            encryptedContent: share.encryptedContent,
            contentNonce: share.contentNonce,
            version: 1,
            createdAt: share.createdAt,
            updatedAt: share.updatedAt,
            deleted: false,
            deletedAt: nil,
            circleId: nil,
            contentSize: share.encryptedContent.count,
            notebookId: nil,
            wrappedContentKey: nil,
            wrappedContentKeyNonce: nil,
            contentKeyGeneration: share.contentKeyGeneration
        )
    }

    /// Copy of `item` with a different version (Item fields are `let`).
    private static func withVersion(_ item: Item, _ version: Int64) -> Item {
        Item(
            id: item.id, userId: item.userId, itemType: item.itemType,
            encryptedContent: item.encryptedContent, contentNonce: item.contentNonce,
            version: version, createdAt: item.createdAt, updatedAt: item.updatedAt,
            deleted: item.deleted, deletedAt: item.deletedAt, circleId: item.circleId,
            contentSize: item.contentSize, notebookId: item.notebookId,
            wrappedContentKey: item.wrappedContentKey, wrappedContentKeyNonce: item.wrappedContentKeyNonce,
            contentKeyGeneration: item.contentKeyGeneration
        )
    }

    /// Rows to append to the notes list: shares the pull didn't already
    /// deliver, skipping ones that never decrypted — unless a prior
    /// decode exists, in which case last-known-good content wins (same
    /// fallback the pull path applies).
    static func materializedRows(
        shared: [SharedNote],
        pulledIds: Set<String>,
        priorNotes: [String: DecodedNote]
    ) -> [DecryptedItem] {
        shared.compactMap { row in
            guard !pulledIds.contains(row.id) else { return nil }
            if let note = row.note {
                return DecryptedItem(item: row.item, note: note, decryptError: nil)
            }
            if let prior = priorNotes[row.id] {
                return DecryptedItem(item: row.item, note: prior, decryptError: nil)
            }
            // Never decrypted: skip the row entirely (android skips
            // undecryptable shares rather than rendering a stub).
            return nil
        }
    }

    /// Reconcile a displayed item list against the current inbox. The
    /// inbox is AUTHORITATIVE for shared rows: every live share is sourced
    /// from it (re-materialized below), and any other appearance of a
    /// shared id in `displayed` is dropped first.
    ///
    /// Two displayed copies of a share can exist and both must yield to
    /// the inbox:
    ///  - `/sync/pull` delivers the share carrying the OWNER's
    ///    wrapped_content_key, which the recipient can't unwrap — rendering
    ///    it directly would show "[decrypt failed]". Only the inbox carries
    ///    a content key sealed to us.
    ///  - a previously-materialized inbox row, which we simply refresh.
    ///
    /// Also drops shares that LEFT the inbox (un-share / owner-delete
    /// propagation) and adds ones that joined — all without a full reload,
    /// so a refresh anywhere (a push, a sync) propagates here too.
    /// Owned rows are untouched. `materializedShareIds` is the set
    /// previously treated as shares, so one that left the inbox is told
    /// apart from an owned row. Returns the new rows + share-id set.
    static func reconcile(
        displayed: [DecryptedItem],
        materializedShareIds: Set<String>,
        shared: [SharedNote],
        priorNotes: [String: DecodedNote]
    ) -> (rows: [DecryptedItem], materializedShareIds: Set<String>) {
        let liveShareIds = Set(shared.map(\.id))
        // The inbox payload has no version, but the pulled copy of a live
        // share does — capture it before dropping that copy so the
        // materialized row can adopt it (an edit then sends the right
        // expected_version and skips the 409→refetch round-trip).
        var pulledVersions: [String: Int64] = [:]
        for row in displayed where liveShareIds.contains(row.id) {
            pulledVersions[row.id] = row.item.version
        }
        let kept = displayed.filter { row in
            // Live share → re-sourced from the inbox below (the pulled copy
            // carries the owner's unusable wrap).
            if liveShareIds.contains(row.id) { return false }
            // Previously a share, now gone from the inbox → un-shared/deleted.
            if materializedShareIds.contains(row.id) { return false }
            return true
        }
        let presentIds = Set(kept.map(\.id))
        let additions = materializedRows(
            shared: shared,
            pulledIds: presentIds,
            priorNotes: priorNotes
        ).map { row -> DecryptedItem in
            guard let v = pulledVersions[row.id], v != row.item.version else { return row }
            return DecryptedItem(item: withVersion(row.item, v), note: row.note, decryptError: row.decryptError)
        }
        return (kept + additions, liveShareIds)
    }
}

extension InboxShareResponse {
    /// This share with its item and owner ids in their one form: every
    /// check, map and write the inbox makes keys them that way.
    func withIds(item: String, owner: String) -> InboxShareResponse {
        InboxShareResponse(
            shareId: shareId, itemId: item, ownerId: owner, permission: permission,
            wrappedKey: wrappedKey, sharerPublicKey: sharerPublicKey, ownerEmail: ownerEmail,
            wrapSignature: wrapSignature, encryptedContent: encryptedContent, contentNonce: contentNonce,
            updatedAt: updatedAt, createdAt: createdAt, contentKeyGeneration: contentKeyGeneration,
            itemType: itemType
        )
    }
}
