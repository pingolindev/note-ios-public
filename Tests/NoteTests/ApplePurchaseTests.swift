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

/// The wire contract and the fail-closed posture around App Store purchases.
///
/// Nothing here drives StoreKit: `Product.purchase` needs a StoreKit test
/// session and configured App Store Connect products, and a test that mocked
/// it would assert against our own mock.
///
/// What is worth pinning without a store is the part deciding whether we sell
/// at all, and the part deciding who a purchase belongs to. Both are pure,
/// both are easy to get wrong in a way nothing crashes on, and both cost the
/// customer money when wrong.
final class ApplePurchaseTests: XCTestCase {

    private func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    // MARK: - Eligibility decoding

    func testEligibilityDecodesTheBlockedCase() throws {
        let json = """
        {"can_purchase": false,
         "reason": "You already subscribe to Pingolin Note on the web.",
         "existing_provider": "paddle"}
        """.data(using: .utf8)!
        let e = try decoder().decode(ApplePurchaseEligibility.self, from: json)

        XCTAssertFalse(e.canPurchase)
        XCTAssertEqual(e.existingProvider, "paddle")
        XCTAssertEqual(e.reason, "You already subscribe to Pingolin Note on the web.")
    }

    /// The permitted case carries no reason and no provider. Declaring either
    /// non-optional would fail the decode for every eligible user — i.e. block
    /// purchasing for exactly the people allowed to buy.
    func testEligibilityDecodesThePermittedCase() throws {
        let json = #"{"can_purchase": true, "reason": null, "existing_provider": null}"#
            .data(using: .utf8)!
        let e = try decoder().decode(ApplePurchaseEligibility.self, from: json)
        XCTAssertTrue(e.canPurchase)
        XCTAssertNil(e.reason)
        XCTAssertNil(e.existingProvider)
    }

    /// Absent keys, not merely null ones.
    func testEligibilityToleratesAbsentOptionalKeys() throws {
        let json = #"{"can_purchase": true}"#.data(using: .utf8)!
        XCTAssertTrue(try decoder().decode(ApplePurchaseEligibility.self, from: json).canPurchase)
    }

    // MARK: - The link request

    /// `appAccountToken` is the only thing in Apple's payload naming an account.
    /// The server refuses a transaction without one, so `purchase()` refuses
    /// before reaching StoreKit when the id will not parse — charging someone for
    /// an unattributable purchase is worse than not selling.
    func testUserIDMustParseAsUUIDForTheAccountToken() {
        XCTAssertNotNil(UUID(uuidString: "3f8c2b1a-9d4e-4c7b-8a15-2e6f0b9d7c31"))
        XCTAssertNil(UUID(uuidString: ""))
        XCTAssertNil(UUID(uuidString: "not-a-uuid"))
        XCTAssertNil(UUID(uuidString: "3f8c2b1a9d4e4c7b8a152e6f0b9d7c31"))
    }

    func testLinkRequestEncodesToSnakeCase() throws {
        struct Body: Encodable { let signedTransaction: String }
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(Body(signedTransaction: "header.payload.sig"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["signed_transaction"] as? String, "header.payload.sig")
        XCTAssertNil(object["signedTransaction"], "camelCase would not deserialise server-side")
    }

    // MARK: - Product configuration

    /// The SKUs must be Note's, not Track's. Both apps are served by the same
    /// auth service, and a Track identifier here would resolve to a Track
    /// subscription, granting the wrong product.
    func testProductIdentifiersAreNotes() {
        XCTAssertEqual(StoreKitManager.ProductID.all.count, 2)
        for id in StoreKitManager.ProductID.all {
            XCTAssertTrue(id.hasPrefix("com.pingolin.note."), "\(id) is not a Note identifier")
        }
        XCTAssertFalse(
            StoreKitManager.ProductID.all.contains { $0.contains("track") },
            "a Track SKU here would grant the wrong product")
    }

    /// The slug sent to the eligibility endpoint is auth's PRODUCT slug, which is
    /// `note` — deliberately not the tier string `QuotaDto` reports for a paid
    /// user, which is `paid`. Sending the tier would 404 the lookup and put the
    /// sheet into its fail-closed path, so nobody could buy and the reason would
    /// be a one-word mix-up.
    func testEligibilityUsesTheProductSlugNotTheTierString() {
        XCTAssertEqual(StoreKitManager.productSlug, "note")
        XCTAssertNotEqual(StoreKitManager.productSlug, "paid")
    }
}

// MARK: - Subscription terms

/// The paywall must state the price PER PERIOD and link to terms and privacy
/// before the customer buys — Schedule 2 of the Developer Program License
/// Agreement, which guideline 3.1.2(c) points at. A missing period or a dead
/// link is one of the most routine subscription rejections there is.
extension ApplePurchaseTests {

    func testPeriodLabelReadsNaturallyNextToAPrice() {
        XCTAssertEqual(StoreKitManager.periodLabel(unit: .month, value: 1), "month")
        XCTAssertEqual(StoreKitManager.periodLabel(unit: .year, value: 1), "year")
        XCTAssertEqual(StoreKitManager.periodLabel(unit: .week, value: 1), "week")
        XCTAssertEqual(StoreKitManager.periodLabel(unit: .day, value: 1), "day")
    }

    /// Apple allows multi-unit periods (a 3-month subscription is one product,
    /// not three). "$9.00 / 3 month" would read as a typo on a paywall.
    func testMultiUnitPeriodsPluralise() {
        XCTAssertEqual(StoreKitManager.periodLabel(unit: .month, value: 3), "3 months")
        XCTAssertEqual(StoreKitManager.periodLabel(unit: .day, value: 14), "14 days")
        XCTAssertEqual(StoreKitManager.periodLabel(unit: .year, value: 2), "2 years")
    }

    /// The links have to be real URLs and have to be the pages we
    /// actually serve. A 404 here is a dead link on a paywall, which
    /// fails App Review as surely as no link at all.
    func testLegalLinksPointAtTheServedPages() {
        XCTAssertEqual(StoreKitManager.Legal.terms.absoluteString, "https://pingolin.com/terms")
        XCTAssertEqual(StoreKitManager.Legal.privacy.absoluteString, "https://pingolin.com/privacy")
        // https, not http: an insecure link on a purchase screen is its own
        // rejection reason.
        XCTAssertEqual(StoreKitManager.Legal.terms.scheme, "https")
        XCTAssertEqual(StoreKitManager.Legal.privacy.scheme, "https")
    }

    // MARK: - Restore Purchases

    /// The result the Restore Purchases button shows, decided without StoreKit.
    func testRestoreOutcomeReportsWhatWasFound() {
        XCTAssertEqual(StoreKitManager.restoreOutcome(found: 1, error: nil), .restored)
        XCTAssertEqual(StoreKitManager.restoreOutcome(found: 2, error: nil), .restored)
        XCTAssertEqual(StoreKitManager.restoreOutcome(found: 0, error: nil), .nothingToRestore)
    }

    /// A refusal outranks the count: a subscription the server will not accept
    /// (another account's purchase, a family-shared one) is not a restore. What
    /// the user reads is this app's line for its code (`refusalText`).
    func testRestoreRefusalOutranksTheCount() {
        let refusal = "This purchase belongs to a different account"
        XCTAssertEqual(StoreKitManager.restoreOutcome(found: 1, error: refusal), .failed(refusal))
        XCTAssertEqual(StoreKitManager.RestoreOutcome.failed(refusal).message, refusal)
    }

    func testRestoreMessages() {
        XCTAssertNil(StoreKitManager.RestoreOutcome.cancelled.message,
                     "dismissing the App Store sign-in is not an error and must say nothing")
        XCTAssertEqual(StoreKitManager.RestoreOutcome.restored.message,
                       "Your App Store subscription has been restored.")
        XCTAssertEqual(StoreKitManager.RestoreOutcome.nothingToRestore.message,
                       "No active App Store subscription was found for this Apple ID.")
    }
}
