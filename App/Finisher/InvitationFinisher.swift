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

/// A note shared ON ITS OWN with an address that had no account, finished by
/// this phone once the address has one (owner, 2026-11-12).
///
/// The server keeps such a share as an invitation with no key, and hands it to
/// the account that signs up with the address (the row is then CLAIMED). Only
/// the owner can seal the note's content key for that account. The page does
/// it while it runs (the web editor's lib/finishSingleInvitations.ts); this is
/// the same work for when it doesn't: from the notification extension when
/// the server's `finish_shares` alert arrives, even for an app that was swiped
/// away, and from the app after a silent `sync` push.
///
/// The rows, the caps and the retry rule are the page's, ported exactly
/// (`due`, `run`). What this adds:
///  - The standing lists of the notebooks are not read here, so every note in a
///    notebook (by the server's `notebook_id`, or the app's own copy of the
///    note) is left to the page: that invitation is the notebook's.
///  - The tried-at of each share is kept on disk (`TriedStore`): neither an
///    extension nor a woken app has a page's memory.
///  - Whom to trust is the page's decision, read from the copy of its pins the
///    app keeps (`KeptPinsMirror`). No copy, or one that does not read: nothing
///    is finished. A first contact is recorded as a SEAL before anything is
///    sealed to it (`SealStore`), and the page folds it into its pins
///    (`takeSeals`). The pins themselves are never written here.
///  - The wrap and its generation come from one fresh read of the item; the
///    wrap is signed exactly as the page signs it, and one that cannot be
///    signed is not sent. Every request is a FINISH stating its generation:
///    the server fills only the keyless row that is there, so a share the
///    owner removed meanwhile stays removed.
enum InvitationFinisher {
    /// How many shares one pass seals at most (the page's FINISH_PER_PASS): the
    /// server takes a set number of shares a minute from an owner.
    static let perPass = 10
    /// Each share is tried at most once in this long (the page's FINISH_RETRY_MS).
    static let retryMs: Int64 = 10 * 60_000
    /// `items.item_type` of a note.
    static let noteType = 1
    /// No share is started with less than this left before the deadline.
    static let startMargin: TimeInterval = 2

    // MARK: - The rows

    /// One share of the owner's that an invitation left without a key
    /// (`GET /api/v1/shares/unfinished`, note-backend `UnfinishedShare`).
    struct UnfinishedShare: Equatable {
        var shareId: String
        var itemId: String
        var itemType: Int
        var notebookId: String?
        var recipientEmail: String
        var permission: String
        /// Made in the note's own Share panel (migration 042 `invite_single`).
        /// nil: the server did not say, and it is not finished here.
        var single: Bool?
        /// An account has signed up with the address and asked for its shares.
        var claimed: Bool
        /// Ran out before anybody claimed it.
        var expired: Bool

        init(shareId: String, itemId: String, itemType: Int = InvitationFinisher.noteType, notebookId: String? = nil,
             recipientEmail: String, permission: String = "view", single: Bool? = true,
             claimed: Bool = true, expired: Bool = false) {
            self.shareId = shareId
            self.itemId = itemId
            self.itemType = itemType
            self.notebookId = notebookId
            self.recipientEmail = recipientEmail
            self.permission = permission
            self.single = single
            self.claimed = claimed
            self.expired = expired
        }

        /// One row of the server's answer; nil for one that is not a row.
        init?(json: [String: Any]) {
            guard let shareId = json["share_id"] as? String,
                  let itemId = json["item_id"] as? String,
                  let itemType = StrictJSON.int(json["item_type"]),
                  let email = json["recipient_email"] as? String,
                  let permission = json["permission"] as? String,
                  let claimed = StrictJSON.bool(json["claimed"]),
                  let expired = StrictJSON.bool(json["expired"])
            else { return nil }
            self.init(shareId: shareId, itemId: itemId, itemType: itemType,
                      notebookId: json["notebook_id"] as? String, recipientEmail: email, permission: permission,
                      single: StrictJSON.bool(json["single"]), claimed: claimed, expired: expired)
        }
    }

    /// A person's CURRENT keys as the account directory publishes them (hex).
    struct DirectoryKeys: Equatable {
        let userId: String
        let sharingPub: String
        let signingPub: String
    }

    /// What finishing one share came to. The page's five, and the two answers
    /// of the server's it folds into `failed`, apart for the log.
    enum Outcome: String, Equatable, Hashable {
        case done
        case notHere = "not-here"
        case keyChanged = "key-changed"
        case cannotSign = "cannot-sign"
        case upgrade
        /// 409 `share_not_unfinished`: removed, finished elsewhere, or the
        /// address belongs to another account now.
        case gone
        /// 409 `share_generation_stale`: the note was re-keyed meanwhile; the
        /// next pass reads it again.
        case stale
        case failed
        /// The account signed in here is no longer the pass's (signed out, or
        /// another account): nothing was recorded or sent, and the pass stops.
        case accountChanged = "account-changed"
    }

    /// The steps of one pass (the page's `SingleFinishSteps`).
    struct Steps {
        /// The server's list; nil when it could not be read.
        var unfinished: () async -> [UnfinishedShare]?
        /// Whether the notebook's standing list has this address.
        var inStanding: (_ notebookId: String, _ email: String) -> Bool
        /// The notebook this device has the note in, if it has the note and it is in one.
        var localNotebookOf: (_ itemId: String) -> String?
        /// The directory's keys by lower-cased address; nil when it could not be asked.
        var lookup: (_ emails: [String]) async -> [String: DirectoryKeys]?
        /// Seal the note for `keys` and send it as a FINISH.
        var finish: (_ share: UnfinishedShare, _ keys: DirectoryKeys) async -> Outcome
        /// Milliseconds since 1970.
        var now: () -> Int64
        /// Whether there is time to start one more share.
        var mayStart: () -> Bool = { true }
        /// Whether the pass's account is still the one signed in here.
        var signedIn: () -> Bool = { true }
    }

    /// When each share was last tried, by share id.
    final class Tried {
        private(set) var at: [String: Int64]

        init(_ at: [String: Int64] = [:]) {
            self.at = at
        }

        func get(_ shareId: String) -> Int64? { at[shareId] }
        func set(_ shareId: String, _ ms: Int64) { at[shareId] = ms }
        func remove(_ shareId: String) { at[shareId] = nil }
        func has(_ shareId: String) -> Bool { at[shareId] != nil }

        /// What still holds a share back at `now`; older entries say nothing.
        func pruned(now: Int64) -> [String: Int64] {
            at.filter { now - $0.value < InvitationFinisher.retryMs }
        }
    }

    /// What a pass did.
    struct Report: Equatable {
        /// The shares finished, in the order they went.
        var finished: [UnfinishedShare] = []
        /// How every share sealed this pass came out.
        var outcomes: [Outcome: Int] = [:]
        /// Shares whose address the directory has no account for.
        var noAccount = 0
        /// Why the pass did nothing or stopped early; nil when it ran to its end.
        var stopped: String?
        /// The account signed in here changed during the pass: nothing more was
        /// recorded, its tried-at was not saved, and nobody may be named for it.
        var accountChanged = false

        var finishedIds: [String] { finished.map(\.shareId) }

        static let accountChangedReason = "the account signed in here changed"
    }

    /// The shares this pass may finish, in the server's order (the page's `dueToFinish`).
    static func due(_ rows: [UnfinishedShare], steps: Steps, tried: Tried, now: Int64) -> [UnfinishedShare] {
        Array(rows
            .filter { $0.claimed && !$0.expired && $0.itemType == noteType }
            // Only a share made on its own. A notebook's share wrote a row per
            // note, and a removal from the notebook deletes them one at a time:
            // rows a removal has not reached yet look like this too.
            .filter { $0.single == true }
            // Nor one in a notebook whose standing list has the address, by the
            // server's word or this device's: that invitation is the notebook's.
            .filter { row in
                ![row.notebookId, steps.localNotebookOf(row.itemId)].contains { notebook in
                    guard let notebook, !notebook.isEmpty else { return false }
                    return steps.inStanding(notebook, row.recipientEmail)
                }
            }
            .filter { row in
                guard let last = tried.get(row.shareId) else { return true }
                return now - last >= retryMs
            }
            .prefix(perPass))
    }

    /// Finish the owner's single-note shares whose people have an account now
    /// (the page's `finishSingleInvitations`).
    static func run(_ steps: Steps, tried: Tried) async -> Report {
        var report = Report()
        guard let rows = await steps.unfinished() else {
            report.stopped = "the list of unfinished shares could not be read"
            return report
        }
        let dueRows = due(rows, steps: steps, tried: tried, now: steps.now())
        guard !dueRows.isEmpty else { return report }
        var emails: [String] = []
        for row in dueRows {
            let email = row.recipientEmail.lowercased()
            if !emails.contains(email) { emails.append(email) }
        }
        // No answer is not "no account": nothing is concluded, and it is asked again.
        guard let directory = await steps.lookup(emails) else {
            report.stopped = "the directory did not answer"
            return report
        }
        for row in dueRows {
            guard steps.signedIn() else {
                report.stopped = Report.accountChangedReason
                report.accountChanged = true
                break
            }
            guard steps.mayStart() else {
                report.stopped = "out of time"
                break
            }
            tried.set(row.shareId, steps.now())
            guard let keys = directory[row.recipientEmail.lowercased()] else {
                report.noAccount += 1
                continue
            }
            let outcome = await steps.finish(row, keys)
            report.outcomes[outcome, default: 0] += 1
            if outcome == .done {
                report.finished.append(row)
                tried.remove(row.shareId)
            } else if outcome == .upgrade {
                // The owner's plan no longer includes sharing: every other one
                // would be refused the same way.
                report.stopped = "the plan does not include sharing"
                break
            } else if outcome == .accountChanged {
                report.stopped = Report.accountChangedReason
                report.accountChanged = true
                break
            }
        }
        return report
    }

    // MARK: - Trust

    /// One of the page's pins (`StoredPin`, the web editor's lib/pinMerge.ts).
    struct KeptPin: Equatable {
        let sharingPubkeyHex: String
        let signingPubkeyHex: String
        /// Two records with different keys were found for this contact: it
        /// matches no key until the owner approves one.
        let conflict: Bool
    }

    /// The keys a conflict holds (the page's CONFLICT_KEY_HEX).
    static let conflictKeyHex = String(repeating: "0", count: 64)

    /// The page's pins blob (the JSON of `pingolin_note_pinned_keys.<account>`):
    /// contact id in its one form → pin. nil when it is not that blob: not a
    /// JSON object, a key that is not an account id, or a record that is not a
    /// pin. Spellings of one id fold as the page folds them: other keys make a
    /// conflict.
    static func parsePins(_ blob: String) -> [String: KeptPin]? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(blob.utf8))) as? [String: Any] else {
            return nil
        }
        var pins: [String: KeptPin] = [:]
        for (rawId, value) in object {
            guard let id = pageAccountId(rawId),
                  let record = value as? [String: Any],
                  let sharing = record["sharingPubkeyHex"] as? String,
                  let signing = record["signingPubkeyHex"] as? String
            else { return nil }
            let pin = KeptPin(sharingPubkeyHex: sharing.lowercased(), signingPubkeyHex: signing.lowercased(),
                              conflict: isConflict(record["conflict"]))
            if let held = pins[id] {
                let same = !held.conflict && !pin.conflict
                    && held.sharingPubkeyHex == pin.sharingPubkeyHex && held.signingPubkeyHex == pin.signingPubkeyHex
                pins[id] = same ? held : KeptPin(sharingPubkeyHex: conflictKeyHex, signingPubkeyHex: conflictKeyHex,
                                                 conflict: true)
            } else {
                pins[id] = pin
            }
        }
        return pins
    }

    /// The page marks a conflict `conflict: true`. Anything there but `false`
    /// or null is read as one: it can only ever stop a seal.
    private static func isConflict(_ value: Any?) -> Bool {
        switch value {
        case nil, is NSNull: return false
        case let n as NSNumber where CFGetTypeID(n) == CFBooleanGetTypeID(): return n.boolValue
        default: return true
        }
    }

    /// An account id as the page reads one (`canonicalAccountId`): 36
    /// hyphenated or 32 bare hex characters, in any case; nil for anything else.
    static func pageAccountId(_ raw: String) -> String? {
        let count = raw.utf8.count
        guard count == 32 || count == 36 else { return nil }
        return CanonicalId.of(raw)
    }

    /// Whom this phone may seal a share's key to (the contract's "Trust").
    enum Trust: Equatable {
        /// A kept pin of the page's holds this sharing key.
        case pinned
        /// No pin, but a seal this phone recorded holds this sharing key.
        case sealed
        /// Neither: a first contact. A seal is recorded before anything is sealed.
        case firstContact
        /// Not sealed to; the page asks the owner to confirm it's them.
        case refused(String)
    }

    /// The trust rows, in their order. `seals` is read only when there is no pin.
    static func trust(userId: String, sharing: String, signing: String,
                      pins: [String: KeptPin], seals: () -> SealRead) -> Trust {
        // Not an account id: nothing to look a pin up under, never a first contact.
        guard let id = pageAccountId(userId) else { return .refused("not an account id") }
        if let pin = pins[id] {
            if pin.conflict { return .refused("the kept pin is a conflict") }
            return pin.sharingPubkeyHex == sharing.lowercased() ? .pinned : .refused("the key differs from the kept pin")
        }
        switch seals() {
        case .unreadable:
            return .refused("the seals kept here could not be read")
        case .seals(let all):
            let theirs = all.filter { CanonicalId.same($0.userId, id) }
            if !theirs.isEmpty {
                return theirs.allSatisfy { $0.sharingPublicKey.lowercased() == sharing.lowercased() }
                    ? .sealed : .refused("the key differs from the one sealed to before")
            }
        case .none:
            break
        }
        guard isHex(sharing, length: 64), isHex(signing, length: 64) else {
            return .refused("the directory's keys are not keys")
        }
        return .firstContact
    }

    static func isHex(_ value: String, length: Int) -> Bool {
        value.utf8.count == length && value.utf8.allSatisfy {
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
                || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0)
                || (UInt8(ascii: "A")...UInt8(ascii: "F")).contains($0)
        }
    }

    // MARK: - Finishing one share

    /// The owner's key material for a pass, read by the caller.
    struct Material {
        /// This account, in its one form.
        let me: String
        /// The owner's X25519 sharing public key, 64 lower-case hex
        /// (`sharer_public_key`, the page's `getSharingPublicKeyHex`).
        let sharerPublicKeyHex: String
        /// The Ed25519 signing seed (32 bytes, or the 64-byte seed and public
        /// key some accounts hold); nil when this device holds none, and then
        /// nothing is sent.
        let signingSeed: Data?
        /// The account's vault key.
        let vaultKey: Data
        /// Vault keys of identities recovered from before a password reset,
        /// newest first: asked for only when the current one opens nothing.
        var previousVaultKeys: () async -> [Data] = { [] }
    }

    /// This account's material from the app's Keychain items (`KeychainService`),
    /// or nil when they can't be read (before the first unlock, signed out).
    /// The sharing public key is the one the app derived at sign-in, as the
    /// page is given it; an account from before it was kept derives it from
    /// the private key, as `WebAppKeyHandoff` does.
    static func material(me: String, keychain: (KeychainService.Key) -> KeychainService.Read,
                         previousVaultKeys: @escaping () async -> [Data]) -> Material? {
        guard case .found(let vaultB64) = keychain(.vaultKey),
              let vault = Data(base64Encoded: vaultB64), vault.count == 32,
              let sharer = sharerPublicKeyHex(keychain)
        else { return nil }
        var seed: Data?
        if case .found(let seedB64) = keychain(.signingPrivateKey) { seed = Data(base64Encoded: seedB64) }
        return Material(me: me, sharerPublicKeyHex: sharer, signingSeed: seed, vaultKey: vault,
                        previousVaultKeys: previousVaultKeys)
    }

    static func sharerPublicKeyHex(_ keychain: (KeychainService.Key) -> KeychainService.Read) -> String? {
        if case .found(let b64) = keychain(.sharingPublicKey), let pub = Data(base64Encoded: b64), pub.count == 32 {
            return pub.map { String(format: "%02x", $0) }.joined()
        }
        if case .found(let b64) = keychain(.sharingPrivateKey), let priv = Data(base64Encoded: b64), priv.count == 32,
           let derived = deriveSharingPublicKey(privateKey: priv), isHex(derived, length: 64) {
            return derived.lowercased()
        }
        return nil
    }

    /// The note's content key: the current vault key first, then the earlier
    /// ones (the page's `unwrapContentKeyWithVault`).
    static func contentKey(wrapped: String, nonce: String, material: Material) async -> Data? {
        if let key = unwrapWithVault(wrappedKeyB64: wrapped, nonceB64: nonce, vaultKey: material.vaultKey),
           key.count == 32 {
            return key
        }
        for previous in await material.previousVaultKeys() {
            if let key = unwrapWithVault(wrappedKeyB64: wrapped, nonceB64: nonce, vaultKey: previous), key.count == 32 {
                return key
            }
        }
        return nil
    }

    /// The request body of a FINISH (`POST /api/v1/items/{id}/share`).
    static func finishBody(row: UnfinishedShare, wrappedKey: String, signature: String,
                           sharerPublicKeyHex: String, generation: Int64) -> [String: Any] {
        [
            // Exactly as the server listed it: it finds the row by it.
            "email": row.recipientEmail,
            "permission": row.permission == "edit" ? "edit" : "view",
            "wrapped_key": wrappedKey,
            "wrap_signature": signature,
            "sharer_public_key": sharerPublicKeyHex,
            // Never a plain share: that is an upsert, and would bring back a
            // share the owner removed.
            "finish": true,
            "content_key_generation": NSNumber(value: generation),
        ]
    }

    /// The server's answer to a FINISH.
    static func outcome(status: Int?, errorCode: String?) -> Outcome {
        guard let status else { return .failed }
        switch status {
        case 200..<300: return .done
        case 402: return .upgrade
        case 409 where errorCode == "share_not_unfinished": return .gone
        case 409 where errorCode == "share_generation_stale": return .stale
        default: return .failed
        }
    }

    /// Seal the note for `keys` and send it as a FINISH (the page's
    /// `shareNoteWithRecipientResult(…, { finish: true })`), reading the wrap
    /// and the generation from the server first.
    static func finish(_ row: UnfinishedShare, keys: DirectoryKeys, material: Material, pins: [String: KeptPin],
                       seals: SealBook, account: String, api: FinisherAPI, now: () -> Int64,
                       stillSignedIn: () -> Bool = { true }) async -> Outcome {
        guard let itemId = CanonicalId.of(row.itemId) else { return .notHere }
        let verdict = trust(userId: keys.userId, sharing: keys.sharingPub, signing: keys.signingPub,
                            pins: pins, seals: { seals.read(account) })
        if case .refused = verdict { return .keyChanged }
        guard let recipient = pageAccountId(keys.userId) else { return .keyChanged }
        // A wrap that cannot be signed is a dead letter: never sent.
        guard let seed = material.signingSeed, seed.count == 32 || seed.count == 64 else { return .cannotSign }

        guard let item = await api.item(itemId) else { return .failed }
        guard !item.deleted, item.itemType == noteType, CanonicalId.same(item.userId, material.me),
              let wrapped = item.wrappedContentKey, let nonce = item.wrappedContentKeyNonce
        else { return .notHere }
        let generation = item.contentKeyGeneration ?? 1
        guard generation >= 0, generation <= Int64(UInt32.max) else { return .failed }
        guard var key = await contentKey(wrapped: wrapped, nonce: nonce, material: material) else {
            return .notHere
        }
        defer { key.resetBytes(in: 0..<key.count) }

        if verdict == .firstContact {
            // Nothing is recorded for an account that is no longer signed in here.
            guard stillSignedIn() else { return .accountChanged }
            // Recorded FIRST: the page learns whom this phone trusted before
            // anything is sealed to them.
            let seal = ShellSeal(userId: recipient, sharingPublicKey: keys.sharingPub.lowercased(),
                                 signingPublicKey: keys.signingPub.lowercased(), sealedAt: now())
            switch await seals.record(seal, for: account, stillSignedIn: stillSignedIn) {
            case .recorded, .alreadyThere: break
            case .otherKeys: return .keyChanged
            case .failed: return .failed
            case .accountChanged: return .accountChanged
            }
        }
        guard let sealed = try? sealForRecipient(contentKey: key, recipientPublicKey: keys.sharingPub) else {
            return .failed
        }
        let params = NoteShareWrapParams(senderUserId: material.me, recipientUserId: recipient, itemId: itemId,
                                         contentKeyVersion: UInt32(generation), wrappedKeyB64: sealed)
        guard let signature = try? signNoteShareWrap(secretSeed: seed, params: params),
              isHex(signature, length: 128)
        else { return .cannotSign }
        // Nor sent for one.
        guard stillSignedIn() else { return .accountChanged }
        let answer = await api.finish(itemId: itemId, body: finishBody(
            row: row, wrappedKey: sealed, signature: signature.lowercased(),
            sharerPublicKeyHex: material.sharerPublicKeyHex, generation: generation))
        return outcome(status: answer?.status, errorCode: answer?.errorCode)
    }

    // MARK: - One pass

    /// Who a pass runs for, and with what.
    struct Session {
        /// This account, in its one form.
        let account: String
        let apiBase: String
        let token: String
        let material: Material
        var userAgent: String?
        /// Whether `account` is still the one signed in here: asked before a
        /// seal is recorded, before each finish is sent, between shares, and
        /// before the tried-at is saved. No: nothing more is recorded or sent.
        var stillSignedIn: () -> Bool = { true }
    }

    /// The stores a pass reads and writes, all this account's.
    struct Stores {
        var keptPins: (_ account: String) -> KeptPinsMirror.Read
        var seals: SealBook
        var tried: TriedBook
    }

    /// One pass: the page's kept pins, then the server's list, then at most
    /// `perPass` shares, none started with less than `startMargin` left.
    /// Every note in a notebook is left to the page, which reads the standing
    /// lists this does not. The caller holds the pass lock.
    static func pass(_ session: Session, stores: Stores, localNotebookOf: @escaping (String) -> String?,
                     transport: FinisherTransport, deadline: Date, now: @escaping () -> Date) async -> Report {
        var report = Report()
        let pins: [String: KeptPin]
        switch stores.keptPins(session.account) {
        case .absent:
            report.stopped = "the app keeps no copy of the page's pins for this account"
            return report
        case .unreadable:
            report.stopped = "the copy of the page's pins could not be read"
            return report
        case .kept(nil):
            // A keep with no pins blob comes only from a page older than its
            // "{}" for an account that pinned nobody: no record, as above.
            report.stopped = "the page kept no record of its pins"
            return report
        case .kept(let blob?):
            guard let parsed = parsePins(blob) else {
                report.stopped = "the copy of the page's pins does not parse"
                return report
            }
            pins = parsed
        }
        let api = FinisherAPI(base: session.apiBase, token: session.token, transport: transport,
                              deadline: deadline, now: now, userAgent: session.userAgent)
        let nowMs: () -> Int64 = { Int64((now().timeIntervalSince1970 * 1000).rounded(.down)) }
        let tried = Tried(stores.tried.load(session.account))
        let steps = Steps(
            unfinished: { await api.unfinished() },
            // The standing lists are the page's: any notebook's note is left to it.
            inStanding: { _, _ in true },
            localNotebookOf: localNotebookOf,
            lookup: { await api.lookup($0) },
            finish: { row, keys in
                await finish(row, keys: keys, material: session.material, pins: pins, seals: stores.seals,
                             account: session.account, api: api, now: nowMs, stillSignedIn: session.stillSignedIn)
            },
            now: nowMs,
            mayStart: { api.remaining > startMargin },
            signedIn: session.stillSignedIn
        )
        report = await run(steps, tried: tried)
        // Nothing is saved for an account that is no longer signed in here.
        guard session.stillSignedIn() else {
            report.stopped = Report.accountChangedReason
            report.accountChanged = true
            return report
        }
        stores.tried.save(session.account, tried.pruned(now: nowMs()))
        return report
    }

    /// The counts of a report, for the log: no address, no id, no key.
    static func summary(_ report: Report) -> String {
        let outcomes = report.outcomes.sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key.rawValue)=\($0.value)" }.joined(separator: " ")
        return "finished \(report.finished.count)"
            + (outcomes.isEmpty ? "" : ", \(outcomes)")
            + (report.noAccount > 0 ? ", no account \(report.noAccount)" : "")
            + (report.stopped.map { ", stopped: \($0)" } ?? "")
    }
}

/// JSON values read strictly: a boolean is only a boolean, an integer only an integer.
enum StrictJSON {
    static func bool(_ value: Any?) -> Bool? {
        guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }

    static func int(_ value: Any?) -> Int? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        guard d.isFinite, d == d.rounded(), abs(d) < 9_007_199_254_740_992 else { return nil }
        return n.intValue
    }

    static func int64(_ value: Any?) -> Int64? {
        int(value).map { Int64($0) }
    }
}
