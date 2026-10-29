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

import XCTest
import Security
@testable import Note

/// A Keychain read that fails is not "nothing stored".
///
/// Before the first unlock after a restart every read fails with
/// `errSecInteractionNotAllowed`, and iOS can start the app then. The launch
/// waits for the unlock instead of showing the sign-in screen, and the local
/// cache's key is never replaced by a new one because the stored one
/// couldn't be read: the cache holds the edits not yet pushed.
final class KeychainUnreadableTests: XCTestCase {

    private let locked = errSecInteractionNotAllowed

    // MARK: - What a read found

    func testAReadSaysFoundNotFoundOrUnreadable() {
        XCTAssertEqual(KeychainService.interpret(status: errSecSuccess, data: Data("token".utf8)), .found("token"))
        XCTAssertEqual(KeychainService.interpret(status: errSecItemNotFound, data: nil), .notFound)
        XCTAssertEqual(KeychainService.interpret(status: locked, data: nil), .unreadable(locked))
        XCTAssertEqual(KeychainService.interpret(status: errSecAuthFailed, data: nil), .unreadable(errSecAuthFailed))
        // Success with nothing returned is not "nothing stored".
        XCTAssertEqual(KeychainService.interpret(status: errSecSuccess, data: nil), .unreadable(errSecDecode))
    }

    func testAValueThatIsNotUTF8IsStillFound() {
        guard case .found = KeychainService.interpret(status: errSecSuccess, data: Data([0xFF, 0xFE, 0x41])) else {
            return XCTFail("a stored value that isn't UTF-8 is there; it must not read as absent")
        }
    }

    // MARK: - The local cache's key

    private let validKey = Data((1...32).map { UInt8($0) })

    private func databaseKey(stored: KeychainService.Read) throws -> (key: Data, minted: Int, saved: [String]) {
        var minted = 0
        var saved: [String] = []
        let key = try KeychainService.databaseKey(
            stored: stored,
            mint: { minted += 1; return Data(repeating: 7, count: 32) },
            save: { saved.append($0) }
        )
        return (key, minted, saved)
    }

    func testAKeyThatCannotBeReadIsNeverReplaced() {
        for status in [locked, errSecAuthFailed, errSecDecode] {
            var minted = 0
            var saved = 0
            XCTAssertThrowsError(try KeychainService.databaseKey(
                stored: .unreadable(status),
                mint: { minted += 1; return Data(repeating: 7, count: 32) },
                save: { _ in saved += 1 }
            ), "status \(status)") { error in
                guard case KeychainService.KeychainError.readFailed(let s) = error else {
                    return XCTFail("expected readFailed, got \(error)")
                }
                XCTAssertEqual(s, status)
            }
            XCTAssertEqual(minted, 0, "status \(status): a new key would orphan the cache and its unsent edits")
            XCTAssertEqual(saved, 0, "status \(status)")
        }
    }

    func testAKeyIsMintedOnlyWhenNoneIsStored() throws {
        let fresh = try databaseKey(stored: .notFound)
        XCTAssertEqual(fresh.minted, 1)
        XCTAssertEqual(fresh.saved, [Data(repeating: 7, count: 32).base64EncodedString()])
        XCTAssertEqual(fresh.key, Data(repeating: 7, count: 32))

        let kept = try databaseKey(stored: .found(validKey.base64EncodedString()))
        XCTAssertEqual(kept.key, validKey)
        XCTAssertEqual(kept.minted, 0)
        XCTAssertEqual(kept.saved, [])
    }

    func testAStoredValueThatIsNotAKeyIsReplaced() throws {
        for value in ["not base64", Data(repeating: 1, count: 16).base64EncodedString()] {
            let replaced = try databaseKey(stored: .found(value))
            XCTAssertEqual(replaced.minted, 1, value)
            XCTAssertEqual(replaced.saved.count, 1, value)
        }
    }

    // MARK: - The launch

    func testOnlyTheLockKeepsTheLaunchWaiting() {
        for cancelled in [false, true] {
            XCTAssertEqual(AuthManager.launchStep(for: .found("t"), waitCancelled: cancelled), .restore)
            XCTAssertEqual(AuthManager.launchStep(for: .notFound, waitCancelled: cancelled), .signedOut)
            // Not the lock: the sign-in screen.
            XCTAssertEqual(AuthManager.launchStep(for: .unreadable(errSecAuthFailed), waitCancelled: cancelled), .signedOut)
            XCTAssertEqual(AuthManager.launchStep(for: .unreadable(errSecDecode), waitCancelled: cancelled), .signedOut)
        }
        // The lock's status keeps waiting only when the wait was cancelled; left
        // after the tries on an unlocked device, it goes to the sign-in screen.
        XCTAssertEqual(AuthManager.launchStep(for: .unreadable(locked), waitCancelled: true), .keepWaiting)
        XCTAssertEqual(AuthManager.launchStep(for: .unreadable(locked), waitCancelled: false), .signedOut)
    }

    @MainActor
    func testTheLaunchWaitsOutTheLockAndReadsAgain() async {
        var reads: [KeychainService.Read] = [.unreadable(locked), .unreadable(locked), .found("t")]
        var readCount = 0
        var waits = 0
        let token = await AuthManager.storedAccessToken(
            read: { readCount += 1; return reads.removeFirst() },
            waitUntilReadable: { waits += 1; return true }
        )
        XCTAssertEqual(token, .found("t"))
        XCTAssertEqual(readCount, 3)
        XCTAssertEqual(waits, 2)
    }

    @MainActor
    func testAnythingButTheLockIsAnsweredAtOnce() async {
        for first in [KeychainService.Read.notFound, .unreadable(errSecAuthFailed), .found("t")] {
            var waits = 0
            let token = await AuthManager.storedAccessToken(read: { first }, waitUntilReadable: { waits += 1; return true })
            XCTAssertEqual(token, first)
            XCTAssertEqual(waits, 0, "\(first)")
        }
    }

    @MainActor
    func testACancelledWaitLeavesTheLaunchWaiting() async {
        let task = Task { @MainActor () -> (KeychainService.Read, Int) in
            var readCount = 0
            let token = await AuthManager.storedAccessToken(
                read: { readCount += 1; return .unreadable(ProtectedData.lockedStatus) },
                waitUntilReadable: { withUnsafeCurrentTask { $0?.cancel() }; return true }
            )
            return (token, readCount)
        }
        let (token, readCount) = await task.value
        XCTAssertEqual(token, .unreadable(locked))
        XCTAssertEqual(AuthManager.launchStep(for: token, waitCancelled: true), .keepWaiting,
                       "a cancelled wait must not read as signed out")
        XCTAssertEqual(readCount, 2, "one read after the wait, then it stops")
    }

    /// On a device that is already unlocked the wait returns false after a
    /// pause, and a read that keeps answering the lock's status stops being
    /// waited on (it isn't the first unlock's).
    @MainActor
    func testALockedAnswerOnAnUnlockedDeviceStopsWaiting() async {
        var reads = 0
        var waits = 0
        let token = await AuthManager.storedAccessToken(
            read: { reads += 1; return .unreadable(ProtectedData.lockedStatus) },
            waitUntilReadable: { waits += 1; return false },
            unlockedTries: 10
        )
        XCTAssertEqual(token, .unreadable(locked))
        XCTAssertEqual(waits, 11)
        XCTAssertEqual(reads, 11, "ten reads again, then it stops")
        XCTAssertEqual(AuthManager.launchStep(for: token, waitCancelled: false), .signedOut,
                       "the sign-in screen, as for any other status; nothing is deleted")
    }

    /// A device that stays locked is waited on for as long as it takes: only
    /// reads on an unlocked device count toward the cap.
    @MainActor
    func testADeviceThatStaysLockedIsWaitedOnPastTheCap() async {
        var reads: [KeychainService.Read] = Array(repeating: .unreadable(locked), count: 15) + [.found("t")]
        var waits = 0
        let token = await AuthManager.storedAccessToken(
            read: { reads.removeFirst() },
            waitUntilReadable: { waits += 1; return true },
            unlockedTries: 10
        )
        XCTAssertEqual(token, .found("t"))
        XCTAssertEqual(waits, 15)
    }

    @MainActor
    func testAnAnswerOnceTheDeviceIsUnlockedIsTakenBeforeTheCap() async {
        var reads: [KeychainService.Read] = [.unreadable(locked), .unreadable(locked), .found("t")]
        let token = await AuthManager.storedAccessToken(
            read: { reads.removeFirst() },
            waitUntilReadable: { false },
            unlockedTries: 10
        )
        XCTAssertEqual(token, .found("t"))
    }

    /// The simulator never locks: its data is always available. The wait
    /// pauses about a second there instead of returning at once, so a caller
    /// that reads again doesn't spin on the main actor.
    @MainActor
    func testTheWaitPausesOnADeviceThatIsAlreadyUnlocked() async {
        let start = Date()
        let waited = await ProtectedData.waitUntilAvailable()
        XCTAssertFalse(waited)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.9)
    }

    /// The launch decides from the read above, never from `getString`, which
    /// folds "can't read" into nil.
    func testTheLaunchCheckDecidesFromTheRead() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("App/Managers/AuthManager.swift"), encoding: .utf8)
        guard let start = source.range(of: "func checkExistingSession() async {"),
              let end = source.range(of: "func login(email: String, password: String)", range: start.upperBound..<source.endIndex)
        else { return XCTFail("checkExistingSession not found") }
        let body = String(source[start.upperBound..<end.lowerBound])
        XCTAssertTrue(body.contains("Self.launchStep(for: token, waitCancelled: Task.isCancelled)"))
        XCTAssertFalse(body.contains("getString(for: .accessToken)"))
        // A cancelled wait keeps the splash; every other exit clears it.
        XCTAssertTrue(body.contains("defer { if !stillWaiting { isCheckingSession = false } }"))
        XCTAssertTrue(body.contains("case .keepWaiting:\n            stillWaiting = true\n            return"))
        XCTAssertTrue(body.contains("case .signedOut:\n            isAuthenticated = false\n            return"),
                      "signed out deletes nothing")
        let app = try String(contentsOf: root.appendingPathComponent("App/NoteApp.swift"), encoding: .utf8)
        XCTAssertTrue(app.contains("guard !authManager.isCheckingSession else { return }"),
                      "the widgets are told nothing while the launch still waits")
    }
}
