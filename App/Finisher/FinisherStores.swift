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

/// What the app hands its notification extension through the app group, and
/// the stores the two share there. Compiled into both (project.yml), so the
/// two cannot drift apart. Nothing here is secret: ids, public keys, times,
/// addresses of the API. The keys stay in the Keychain, which the extension
/// reads through the app's keychain group.
enum FinisherBridgeKeys {
    /// The app group (`SharedAppGroup.identifier`).
    static let suite = "group.com.pingolin.note"
    static let apiBaseURL = "finisher.api_base_url"
    /// Where the extension refreshes the session, and asks for earlier identities.
    static let authBaseURL = "finisher.auth_base_url"
    /// The signed-in account, in its one form; gone at sign-out.
    static let accountUserId = "finisher.account_user_id"
    /// The app's notification detail level (`NotificationDetailLevel`).
    static let notificationDetail = "finisher.notification_detail"
}

/// The app's half: mirrored whenever the signed-in state is published, so the
/// extension finishes nothing for an account that is not signed in here, and
/// is pointed wherever the app is pointed.
enum FinisherBridge {
    struct Mirrored: Equatable {
        var account: String?
        var apiBase: String?
        var authBase: String?
        var detail: String?
    }

    static var sharedDefaults: UserDefaults? { UserDefaults(suiteName: FinisherBridgeKeys.suite) }

    /// The account's fields, then its id: a process stopped in between never
    /// pairs one account's id with another's fields. Another account's id goes
    /// first. No account (signed out): the id goes.
    static func publish(account: String?, apiBase: String, authBase: String, detail: String,
                        defaults: UserDefaults? = sharedDefaults) {
        guard let defaults else { return }
        guard let account = CanonicalId.of(account) else {
            defaults.removeObject(forKey: FinisherBridgeKeys.accountUserId)
            return
        }
        if defaults.string(forKey: FinisherBridgeKeys.accountUserId) != account {
            defaults.removeObject(forKey: FinisherBridgeKeys.accountUserId)
        }
        defaults.set(apiBase, forKey: FinisherBridgeKeys.apiBaseURL)
        defaults.set(authBase, forKey: FinisherBridgeKeys.authBaseURL)
        defaults.set(detail, forKey: FinisherBridgeKeys.notificationDetail)
        defaults.set(account, forKey: FinisherBridgeKeys.accountUserId)
    }

    static func publishDetail(_ detail: String, defaults: UserDefaults? = sharedDefaults) {
        defaults?.set(detail, forKey: FinisherBridgeKeys.notificationDetail)
    }

    static func read(_ defaults: UserDefaults?) -> Mirrored {
        Mirrored(
            account: defaults?.string(forKey: FinisherBridgeKeys.accountUserId),
            apiBase: defaults?.string(forKey: FinisherBridgeKeys.apiBaseURL),
            authBase: defaults?.string(forKey: FinisherBridgeKeys.authBaseURL),
            detail: defaults?.string(forKey: FinisherBridgeKeys.notificationDetail))
    }
}

/// One file per store and account in the app group, named by the account in
/// its one form. Protected until the first unlock (as the Keychain items they
/// go with) and kept out of backups. Written whole and atomically, so a reader
/// in the other process sees the old file or the new one, never half of one.
struct FinisherFiles {
    let directory: URL

    enum Kind: String, CaseIterable {
        /// The page's pins, as the app last kept them (`KeptPinsMirror`).
        case keptPins = "kept-pins"
        /// Keys this phone sealed a finished invitation to (`SealStore`).
        case seals = "shell-seals"
        /// When each share was last tried (`TriedStore`).
        case tried = "finish-tried"
    }

    enum Read: Equatable {
        case absent
        case data(Data)
        /// There, and not readable now (before the first unlock, for one).
        case unreadable
    }

    static func appGroup() -> FinisherFiles? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: FinisherBridgeKeys.suite)
            .map { FinisherFiles(directory: $0.appendingPathComponent("FinishInvitations", isDirectory: true)) }
    }

    func url(_ kind: Kind, _ account: String) -> URL? {
        guard let id = CanonicalId.of(account) else { return nil }
        return directory.appendingPathComponent("\(kind.rawValue).\(id).json", isDirectory: false)
    }

    func read(_ kind: Kind, _ account: String) -> Read {
        guard let url = url(kind, account) else { return .unreadable }
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        guard let data = try? Data(contentsOf: url) else { return .unreadable }
        return .data(data)
    }

    @discardableResult
    func write(_ kind: Kind, _ account: String, _ data: Data) -> Bool {
        guard let url = url(kind, account) else { return false }
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            return false
        }
        var written = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? written.setResourceValues(values)
        return true
    }

    /// True when the file is not there afterwards.
    @discardableResult
    func remove(_ kind: Kind, _ account: String) -> Bool {
        guard let url = url(kind, account) else { return false }
        try? FileManager.default.removeItem(at: url)
        return !FileManager.default.fileExists(atPath: url.path)
    }

    /// Erasure: every store of this account; nobody else's.
    func forget(_ account: String) {
        for kind in Kind.allCases { remove(kind, account) }
    }
}

/// The copy of the page's pins blob the extension reads, as
/// `{"v":1,"pins":<blob or null>}`. Never written by the finisher. Only a keep
/// that landed after the page's latest adopt makes one: the bridge drops it
/// when the page adopts (answered or not: a page whose adopt got no answer in
/// time sends no keeps that session, and would leave an older copy behind its
/// own pins) and when a keep fails (`WebKeyBridge`, `KeptWebTrustStore`).
enum KeptPinsMirror {
    enum Read: Equatable {
        /// The page's blob as it was kept. nil: the keep carried no pins blob,
        /// which only a page from before 2026-11-12 sends (a current one sends
        /// "{}" for an account that pinned nobody): no record, like `absent`.
        case kept(String?)
        /// No keep has reached the app for this account.
        case absent
        case unreadable
    }

    static func write(_ pins: String?, for account: String, in files: FinisherFiles) -> Bool {
        let object: [String: Any] = ["v": 1, "pins": pins ?? NSNull()]
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return false }
        return files.write(.keptPins, account, data)
    }

    static func read(_ account: String, in files: FinisherFiles) -> Read {
        switch files.read(.keptPins, account) {
        case .absent: return .absent
        case .unreadable: return .unreadable
        case .data(let data):
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  StrictJSON.int(object["v"]) == 1
            else { return .unreadable }
            switch object["pins"] {
            case is NSNull: return .kept(nil)
            case let blob as String: return .kept(blob)
            default: return .unreadable
            }
        }
    }

    /// The copy's pins (a key or a conflict) by person, in their one form;
    /// none when there is no copy that reads.
    static func pins(_ account: String, in files: FinisherFiles) -> [String: InvitationFinisher.KeptPin] {
        guard case .kept(let blob?) = read(account, in: files),
              let pins = InvitationFinisher.parsePins(blob) else { return [:] }
        return pins
    }
}

/// A key this phone sealed a finished invitation to: the person, their keys
/// as the directory gave them, and when (ms). The page folds it into its pins.
struct ShellSeal: Equatable {
    let userId: String
    let sharingPublicKey: String
    let signingPublicKey: String
    let sealedAt: Int64

    var json: [String: Any] {
        ["user_id": userId, "sharing_public_key": sharingPublicKey, "signing_public_key": signingPublicKey,
         "sealed_at": NSNumber(value: sealedAt)]
    }

    init(userId: String, sharingPublicKey: String, signingPublicKey: String, sealedAt: Int64) {
        self.userId = userId
        self.sharingPublicKey = sharingPublicKey
        self.signingPublicKey = signingPublicKey
        self.sealedAt = sealedAt
    }

    init?(json: [String: Any]) {
        guard let userId = json["user_id"] as? String,
              let sharing = json["sharing_public_key"] as? String,
              let signing = json["signing_public_key"] as? String,
              let at = StrictJSON.int64(json["sealed_at"])
        else { return nil }
        self.init(userId: userId, sharingPublicKey: sharing, signingPublicKey: signing, sealedAt: at)
    }
}

enum SealRead: Equatable {
    case seals([ShellSeal])
    case none
    case unreadable
}

enum SealRecord: Equatable {
    case recorded
    /// A seal for this person with these keys is there already.
    case alreadyThere
    /// A seal for this person with OTHER keys is there: nothing is sealed.
    case otherKeys
    case failed
    /// The account was no longer the one signed in here once the lock was
    /// held: nothing was written.
    case accountChanged
}

protocol SealBook {
    func read(_ account: String) -> SealRead
    func record(_ seal: ShellSeal, for account: String, stillSignedIn: () -> Bool) async -> SealRecord
}

/// The account's seals, in the app group: the extension (or the app's own pass)
/// records them, and the app hands them to the page (the bridge's `takeSeals`)
/// and lets go of what the page folded (`clearSeals`). Every change is made
/// holding `AppGroupLock.seals()`, which both processes take. Same lifetime as
/// the kept trust: kept across a sign-out, gone when the account is erased.
struct SealStore: SealBook {
    let files: FinisherFiles
    /// nil only where there is no app group (a test's scratch folder).
    let lock: AppGroupLock?
    var wait: TimeInterval = 2

    static func appGroup() -> SealStore? {
        FinisherFiles.appGroup().map { SealStore(files: $0, lock: AppGroupLock.seals()) }
    }

    func read(_ account: String) -> SealRead {
        switch files.read(.seals, account) {
        case .absent: return .none
        case .unreadable: return .unreadable
        case .data(let data):
            guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return .unreadable }
            var seals: [ShellSeal] = []
            for entry in list {
                guard let seal = (entry as? [String: Any]).flatMap(ShellSeal.init(json:)) else { return .unreadable }
                seals.append(seal)
            }
            return seals.isEmpty ? .none : .seals(seals)
        }
    }

    /// Record `seal`, checking again under the lock: a seal for the person with
    /// other keys means nothing is sealed to them.
    func record(_ seal: ShellSeal, for account: String,
                stillSignedIn: () -> Bool = { true }) async -> SealRecord {
        guard let held = await hold() else { return .failed }
        defer { held?.release() }
        // Asked again once the lock is held, which can take seconds: a
        // sign-out and an erasure meanwhile removed this account's seals, and
        // nothing may write them back.
        guard stillSignedIn() else { return .accountChanged }
        var seals: [ShellSeal]
        switch read(account) {
        case .unreadable: return .failed
        case .none: seals = []
        case .seals(let all): seals = all
        }
        let theirs = seals.filter { CanonicalId.same($0.userId, seal.userId) }
        if !theirs.isEmpty {
            return theirs.allSatisfy { $0.sharingPublicKey.lowercased() == seal.sharingPublicKey.lowercased() }
                ? .alreadyThere : .otherKeys
        }
        seals.append(seal)
        return write(seals, account) ? .recorded : .failed
    }

    /// The page folded the seals up to `upTo` (ms) into its pins. A seal goes
    /// only when the app's copy of those pins shows it folded: the person
    /// pinned at the seal's sharing AND signing keys, or a conflict (what
    /// folding a seal with either key different makes: the page's `foldPins`).
    /// Any other stays, whatever its time: one the copy does not hold yet (the
    /// keep carrying the fold has not landed), or holds at another key (the
    /// page could not fold it, and the conflict it should have made is not
    /// there), so the finisher never loses what it sealed to.
    func clear(_ account: String, upTo: Double, pins: [String: InvitationFinisher.KeptPin]) async -> Bool {
        guard let held = await hold() else { return false }
        defer { held?.release() }
        switch read(account) {
        case .none: return true
        case .unreadable: return false
        case .seals(let all):
            let left = all.filter { seal in
                guard Double(seal.sealedAt) <= upTo, let person = CanonicalId.of(seal.userId),
                      let pin = pins[person] else { return true }
                let folded = pin.conflict
                    || (pin.sharingPubkeyHex.lowercased() == seal.sharingPublicKey.lowercased()
                        && pin.signingPubkeyHex.lowercased() == seal.signingPublicKey.lowercased())
                return !folded
            }
            if left == all { return true }
            return left.isEmpty ? files.remove(.seals, account) : write(left, account)
        }
    }

    private func write(_ seals: [ShellSeal], _ account: String) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: seals.map(\.json)) else { return false }
        return files.write(.seals, account, data)
    }

    /// The lock, held (`.some(nil)` with no lock to take); nil when it could not be had.
    private func hold() async -> AppGroupLock.Held?? {
        guard let lock else { return .some(nil) }
        guard let held = await lock.acquire(timeout: wait) else { return nil }
        return .some(held)
    }
}

protocol TriedBook {
    func load(_ account: String) -> [String: Int64]
    func save(_ account: String, _ tried: [String: Int64])
}

/// When each share was last tried, kept between passes: by share id, in ms.
/// Read and written only by a pass, which holds `AppGroupLock.finish()`.
/// One that can't be read starts empty: the shares are tried a little sooner.
struct TriedStore: TriedBook {
    let files: FinisherFiles

    static func appGroup() -> TriedStore? { FinisherFiles.appGroup().map(TriedStore.init(files:)) }

    func load(_ account: String) -> [String: Int64] {
        guard case .data(let data) = files.read(.tried, account),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return [:] }
        var tried: [String: Int64] = [:]
        for (id, value) in object {
            if let ms = StrictJSON.int64(value) { tried[id] = ms }
        }
        return tried
    }

    func save(_ account: String, _ tried: [String: Int64]) {
        if tried.isEmpty {
            files.remove(.tried, account)
            return
        }
        let object = tried.mapValues { NSNumber(value: $0) }
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        files.write(.tried, account, data)
    }
}

/// A lock two processes can share: a POSIX `flock` on a file in the app group
/// the app and its notification extension both hold. The kernel drops it if
/// its holder dies, so a killed process never leaves it held (as the Track
/// iOS app's). Three locks use it:
///
/// * `refresh()` — ONE session refresh at a time across the app and the
///   extension. Refresh tokens rotate: if both processes refreshed from the
///   SAME stored token, the loser would hold a retired pair, and presenting it
///   later revokes the session. So every refresh, in either process, holds this
///   lock and first reads the stored pair AGAIN (`SessionRefresh`).
/// * `finish()` — one finishing pass at a time, here or in the extension.
/// * `seals()` — the seal store's read-change-writes.
final class AppGroupLock {
    /// How long the APP waits for the refresh lock: longer than an extension
    /// run's whole budget.
    static let appWait: TimeInterval = 25
    /// How long the EXTENSION waits: its banner must not wait on the app.
    static let extensionWait: TimeInterval = 3

    static let refreshFile = "session-refresh.lock"
    static let finishFile = "finish-invitations.lock"
    static let sealsFile = "shell-seals.lock"

    let url: URL

    init(url: URL) {
        self.url = url
    }

    static func inAppGroup(_ file: String, suiteName: String = FinisherBridgeKeys.suite) -> AppGroupLock? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: suiteName)
            .map { AppGroupLock(url: $0.appendingPathComponent(file)) }
    }

    static func refresh() -> AppGroupLock? { inAppGroup(refreshFile) }
    static func finish() -> AppGroupLock? { inAppGroup(finishFile) }
    static func seals() -> AppGroupLock? { inAppGroup(sealsFile) }

    /// The lock, held until `release()`.
    final class Held {
        private let fd: Int32
        private var released = false
        private let lock = NSLock()

        fileprivate init(fd: Int32) {
            self.fd = fd
        }

        func release() {
            lock.lock()
            defer { lock.unlock() }
            guard !released else { return }
            released = true
            flock(fd, LOCK_UN)
            close(fd)
        }

        deinit {
            release()
        }
    }

    /// Waits up to `timeout` for the lock without blocking a thread; nil if it
    /// could not be had.
    func acquire(timeout: TimeInterval) async -> Held? {
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK, Date() < deadline else {
                close(fd)
                return nil
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return Held(fd: fd)
    }

    /// The same, for a synchronous caller (an erasure on the main actor):
    /// every other holder keeps it for milliseconds, so this blocks for
    /// milliseconds; nil after `timeout`.
    func acquireBlocking(timeout: TimeInterval) -> Held? {
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK, Date() < deadline else {
                close(fd)
                return nil
            }
            usleep(5_000)
        }
        return Held(fd: fd)
    }
}

/// The refresh rule both processes follow, holding `AppGroupLock.refresh()`.
enum SessionRefresh {
    /// Whether the stored refresh token changed since the caller read `before`:
    /// another process refreshed, and its pair is the one to use.
    static func anotherProcessRefreshed(before: String?, now: String?) -> Bool {
        guard let now, !now.isEmpty, now != "none" else { return false }
        return now != before
    }
}
