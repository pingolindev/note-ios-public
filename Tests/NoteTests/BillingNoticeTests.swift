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

/// The post-deletion billing notice is the LAST thing the account can ever
/// tell anyone — once the delete returns there is no session, no screen and
/// no email to follow up with. So what it leaves out is money the person
/// goes on paying without knowing.
///
/// It names every count the server reports, not just one. Subscriptions are
/// unique per (user, product), so somebody can hold a Note subscription
/// through the App Store and a Track one billed by Paddle; if the Paddle
/// cancellation fails, the server reports both counts. A notice naming only
/// Apple would have them cancel with Apple, think they were finished, and
/// keep being billed by the provider nobody mentioned.
final class BillingNoticeTests: XCTestCase {

    private let appleMarker = "App Store subscription is still running"
    private let supportMarker = "help@support.pingolin.com"

    func testAppStoreOnlyNamesAppleAndNotSupport() {
        let text = AuthManager.billingNotice(appStoreRemaining: 1, cancellationsFailed: 0)
        XCTAssertTrue(text.contains(appleMarker), text)
        XCTAssertFalse(text.contains(supportMarker),
                       "must not send them to support when nothing failed: \(text)")
    }

    func testFailedCancellationOnlyNamesSupportAndNotApple() {
        let text = AuthManager.billingNotice(appStoreRemaining: 0, cancellationsFailed: 1)
        XCTAssertTrue(text.contains(supportMarker), text)
        XCTAssertFalse(text.contains(appleMarker),
                       "must not blame Apple when no Apple sub is running: \(text)")
    }

    /// The case this whole file exists for.
    func testBothCountsAreReportedNotJustTheAppStoreOne() {
        let text = AuthManager.billingNotice(appStoreRemaining: 1, cancellationsFailed: 1)
        XCTAssertTrue(text.contains(appleMarker),
                      "must still name the Apple subscription: \(text)")
        XCTAssertTrue(text.contains(supportMarker),
                      "must ALSO tell them to write in: \(text)")
        XCTAssertTrue(text.contains("Separately"),
                      "must mark the second one as a DIFFERENT subscription, or it reads as a restatement of the Apple one: \(text)")
    }

    func testMoreThanOneAppStoreSubscriptionIsNotDescribedInTheSingular() {
        let text = AuthManager.billingNotice(appStoreRemaining: 2, cancellationsFailed: 0)
        XCTAssertTrue(text.contains("2 App Store subscriptions are still running"), text)
        XCTAssertTrue(text.contains("cancel them yourself"),
                      "plural must ask them to cancel them, not it: \(text)")
    }

    /// Unreachable while the server's `billing_needs_attention` is
    /// `(remaining > 0 || failed > 0)`, but if that flag ever widens the notice
    /// must not come up blank or end mid-sentence.
    func testNeitherCountStillSaysSomethingActionable() {
        let text = AuthManager.billingNotice(appStoreRemaining: 0, cancellationsFailed: 0)
        XCTAssertTrue(text.contains(supportMarker), text)
        XCTAssertTrue(text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("."),
                      "must not end mid-sentence: \(text)")
    }
}
