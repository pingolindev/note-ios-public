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
@testable import Note

/// Push routing against the note dispatcher's REAL payloads: `type` is
/// always "tickle" and the event is in `kind`; APNs carries them as
/// top-level keys beside "aps". Reading `type` first would send every
/// one of them to the reminder check.
@MainActor
final class PushRoutingTests: XCTestCase {

    private let shareId = "3f2c8f4e-9a51-4b8e-8d2a-6c1e0b7d5a90"

    /// The payload shape the dispatcher sends:
    /// `{"type": "tickle", "kind": <kind>, "refId": <id>}`
    private func dispatched(_ kind: String, refId: String? = nil) -> [AnyHashable: Any] {
        ["aps": ["content-available": 1], "type": "tickle", "kind": kind, "refId": refId ?? shareId]
    }

    func testEachKindTheDispatcherSendsIsRoutedByItsKind() {
        XCTAssertEqual(PushNotificationManager.event(from: dispatched("share")), .share(refId: shareId))
        XCTAssertEqual(PushNotificationManager.event(from: dispatched("notebook_share")), .notebookShare(refId: shareId))
        XCTAssertEqual(PushNotificationManager.event(from: dispatched("sync")), .sync)
        XCTAssertEqual(PushNotificationManager.event(from: dispatched("reminder")), .reminder)
    }

    func testTypeOnlyCoversASenderWithoutAKind() {
        XCTAssertEqual(PushNotificationManager.event(from: ["type": "share", "refId": shareId]), .share(refId: shareId))
        XCTAssertEqual(PushNotificationManager.event(from: ["type": "tickle"]), .reminder)
        XCTAssertEqual(PushNotificationManager.event(from: dispatched("a-kind-from-the-future")), .ignored)
        XCTAssertEqual(PushNotificationManager.event(from: [:]), .ignored)
    }

    func testOnlyAnIdShapedRefIdIsTaken() {
        XCTAssertEqual(PushNotificationManager.event(from: dispatched("share", refId: "../settings")), .share(refId: nil))
        XCTAssertEqual(PushNotificationManager.event(from: ["kind": "share", "ref_id": shareId]), .share(refId: shareId))
    }

    func testQuickWorkIsWaitedFor() async {
        var ran = false
        await PushNotificationManager.run({ ran = true }, waitingAtMost: 5)
        XCTAssertTrue(ran)
    }

    /// A background push must be answered within about 30 seconds, so a long
    /// sync is waited for only so long; it is not cancelled.
    func testTheWaitIsBoundedAndTheWorkCarriesOn() async throws {
        var finished = false
        var cancelled = false
        let start = Date()
        await PushNotificationManager.run({
            do {
                try await Task.sleep(for: .seconds(1.5))
                finished = true
            } catch {
                cancelled = true
            }
        }, waitingAtMost: 0.2)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1, "the caller moved on at the bound")
        XCTAssertFalse(finished)

        for _ in 0..<150 where !finished && !cancelled {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(cancelled, "the work was not cancelled at the bound")
        XCTAssertTrue(finished, "the work carried on past the bound")
    }
}
