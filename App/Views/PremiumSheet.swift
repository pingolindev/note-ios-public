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

import StoreKit
import SwiftUI

/// What Pingolin Note Premium unlocks, and how to buy it. Shown from the
/// editor's reminder / share-link buttons when the user is on the free tier,
/// from the Settings Plan card's info button, and from the notebook-share entry.
///
/// The app sells through the App Store, and the button below is not a nicety
/// but the condition under which honouring a web-bought subscription in this
/// app is permitted at all — guideline 3.1.3(b) allows it PROVIDED the same
/// thing is available as an in-app purchase.
///
/// Prices match the web exactly, so there is no cheaper channel and nothing
/// worth steering anyone towards.
///
/// The Android app keeps web-only purchasing (its PremiumBottomSheet), so the
/// two intentionally differ here.
struct PremiumSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = StoreKitManager.shared

    /// nil while unknown, then the server's answer. Purchase is offered only on
    /// an explicit yes — see `checkEligibility`.
    @State private var eligibility: ApplePurchaseEligibility?
    @State private var checkingEligibility = true
    @State private var purchaseError: String?
    @State private var restoring = false
    @State private var restoreMessage: String?

    private struct Feature: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let detail: String
    }

    // No "unlimited notes" row: the free plan has unlimited notes too, so it
    // doesn't distinguish the plans. Storage is the headline difference.
    private let features: [Feature] = [
        Feature(icon: "internaldrive", title: "10 GB attachment storage",
                detail: "Free plan caps at 100 MB total."),
        Feature(icon: "person.2.fill", title: "Share notes and notebooks",
                detail: "End-to-end encrypted, per recipient."),
        Feature(icon: "bell.fill", title: "Reminders",
                detail: "Push and email notifications on a schedule."),
    ]

    /// Optional emphasis for the sheet. When set, a short context line is
    /// shown above the feature list and the matching feature row is
    /// highlighted, so a 402 for a specific cap (e.g. attachment storage)
    /// lands on an explainer framed around that benefit instead of the
    /// generic three-up. `nil` (the default) shows the generic sheet used
    /// by the share / reminder / settings entry points.
    enum Focus {
        case storage

        /// Parse the shell's `?focus=` value. Unknown or absent means the
        /// generic sheet, never a failure — the page and the app ship on
        /// different cadences, so an app that does not know a newer cap's name
        /// must degrade rather than break.
        init?(_ raw: String?) {
            switch raw {
            case "storage": self = .storage
            default: return nil
            }
        }

        /// One-liner shown in the callout above the feature list ("You've
        /// reached the free limit … Premium raises it to …").
        var contextLine: String {
            switch self {
            case .storage:
                return "You've reached the 100 MB free storage limit for attachments. Premium raises it to 10 GB."
            }
        }

        /// SF Symbol of the `Feature` row to emphasize.
        var highlightIcon: String {
            switch self {
            case .storage: return "internaldrive"
            }
        }
    }

    let focus: Focus?

    init(focus: Focus? = nil) {
        self.focus = focus
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let focus {
                        Text(focus.contextLine)
                            .font(.subheadline.weight(.semibold))
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.accentColor.opacity(0.12),
                                        in: RoundedRectangle(cornerRadius: 12))
                            .accessibilityIdentifier("premium-sheet-context")
                    }

                    Text("Premium unlocks the three limits below.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    ForEach(features) { feature in
                        HStack(alignment: .top, spacing: 14) {
                            Image(systemName: feature.icon)
                                .font(.title3)
                                .foregroundStyle(.tint)
                                .frame(width: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(feature.title).font(.headline)
                                Text(feature.detail)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            if let focus, feature.icon == focus.highlightIcon {
                                Spacer()
                                Image(systemName: "arrow.up.circle.fill")
                                    .foregroundStyle(.tint)
                                    .accessibilityHidden(true)
                            }
                        }
                    }

                    Divider()

                    purchaseSection

                    restoreSection
                }
                .padding()
            }
            .navigationTitle("Pingolin Note Premium")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Got it") { dismiss() }
                        .accessibilityIdentifier("premium-sheet-dismiss")
                }
            }
            .task {
                await store.loadProducts()
                await checkEligibility()
            }
        }
    }

    @ViewBuilder
    private var purchaseSection: some View {
        if checkingEligibility {
            ProgressView()
                .frame(maxWidth: .infinity, alignment: .center)
        } else if let eligibility, !eligibility.canPurchase {
            // Already subscribed on the web. Buying here would charge them a
            // second time, and we cannot cancel the web subscription for them, so
            // this states the situation instead of offering a button.
            Label(Self.notEligibleLine(eligibility), systemImage: "info.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("premium-already-subscribed")
        } else if store.products.isEmpty {
            Text("Purchases are unavailable right now. Please try again later.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("premium-purchase-unavailable")
        } else {
            VStack(spacing: 10) {
                ForEach(store.products, id: \.id) { product in
                    Button {
                        Task { await buy(product) }
                    } label: {
                        HStack {
                            Text(product.displayName)
                            Spacer()
                            Text(product.displayPriceWithPeriod).fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    // The single most important button in the app, so its white
                    // label sits on a contrast-checked fill rather than the
                    // stock accent. See A11yColors.swift; the style also covers
                    // the disabled state this button enters while a purchase is
                    // in flight.
                    .buttonStyle(A11yProminentButtonStyle())
                    .disabled(store.purchasing)
                    .accessibilityIdentifier("premium-buy-\(product.id)")
                }
                if store.purchasing {
                    ProgressView().padding(.top, 2)
                }

                subscriptionTerms
            }
        }

        if let purchaseError {
            Text(purchaseError)
                .font(.footnote)
                .foregroundStyle(Color.a11yError)
                .accessibilityIdentifier("premium-purchase-error")
        }
    }

    /// Renewal terms and the two legal links, shown with the buy buttons.
    ///
    /// NOT decoration and not optional. Guideline 3.1.2(c) points at Schedule 2 of
    /// the Developer Program License Agreement, which requires an auto-renewable
    /// subscription to show its length and price per period, plus FUNCTIONAL links
    /// to the terms of use and privacy policy, before the customer buys. A paywall
    /// missing these is one of the most routine subscription rejections there is.
    ///
    /// The price/period half is handled by `displayPriceWithPeriod` on the button
    /// itself, so what is left here is the renewal behaviour and the links.
    private var subscriptionTerms: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Subscriptions renew automatically unless auto-renew is turned off at "
                 + "least 24 hours before the end of the current period. Manage or cancel "
                 + "in your Apple account settings.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // 44pt hit areas and .caption rather than .caption2. These are the
            // links guideline 3.1.2(c) requires to be FUNCTIONAL, and App
            // Review taps them; at 11pt they lay out about 13pt tall, well
            // under the 44pt floor. The same treatment as LoginView's links;
            // the accessibility audit covers that screen, not this one.
            HStack(spacing: 18) {
                Link("Terms of Use", destination: StoreKitManager.Legal.terms)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("premium-terms-link")
                Link("Privacy Policy", destination: StoreKitManager.Legal.privacy)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("premium-privacy-link")
            }
            .font(.caption)
        }
        .padding(.top, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Restore Purchases, in every state of the sheet but the spinner — including
    /// "you already subscribe on the web" and "purchases unavailable", because the
    /// person looking for it is exactly the one whose purchase did not show up.
    /// Guideline 3.1.1 expects a visible restore; the launch-time `restore()` is
    /// invisible, and cannot see past the device's copy of the history.
    @ViewBuilder
    private var restoreSection: some View {
        if !checkingEligibility {
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    Task { await restorePurchases() }
                } label: {
                    Group {
                        if restoring {
                            ProgressView()
                        } else {
                            Text("Restore Purchases")
                        }
                    }
                    // 44pt, the same hit-area floor as the legal links.
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .font(.footnote)
                .disabled(restoring || store.purchasing)
                .accessibilityIdentifier("premium-restore-purchases")

                if let restoreMessage {
                    Text(restoreMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("premium-restore-result")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func restorePurchases() async {
        restoring = true
        defer { restoring = false }
        restoreMessage = nil
        let outcome = await store.restorePurchases()
        restoreMessage = outcome.message
        // A restored App Store subscription changes what eligibility answers.
        if outcome == .restored {
            await checkEligibility()
        }
    }

    /// Ask the server whether this account may buy through the App Store.
    ///
    /// FAILS CLOSED. A transport error leaves the button hidden, because the
    /// question it answers is "does this person already pay for this on the web",
    /// and selling on a guess charges them twice for one entitlement. An
    /// unavailable-purchases message is a far cheaper wrong answer.
    private func checkEligibility() async {
        defer { checkingEligibility = false }
        do {
            eligibility = Self.kept(try await APIService.shared.getApplePurchaseEligibility(
                product: StoreKitManager.productSlug))
        } catch {
            print("[Note] Purchase eligibility check failed: \(error)")
            eligibility = ApplePurchaseEligibility(
                canPurchase: false,
                reason: "We could not check your subscription. Please try again in a moment.",
                existingProvider: nil)
        }
    }

    private func buy(_ product: Product) async {
        purchaseError = nil
        guard let userID = AuthManager.shared.currentUser?.id else {
            purchaseError = "Please sign in again to subscribe."
            return
        }
        switch await store.purchase(product, userID: userID) {
        case .success:
            dismiss()
        case .cancelled:
            // Dismissing the App Store sheet is not a failure.
            break
        case .pending:
            purchaseError = "Your purchase needs approval. It will activate once approved."
        case .failed(let message):
            purchaseError = message
        }
    }

    /// What the sheet keeps of the server's answer: whether this account may
    /// buy here, never the server's own `reason`, which can say anything (and
    /// says "on the web" of any other provider). The refusal is said in this
    /// app's words (`notEligibleLine`).
    nonisolated static func kept(_ answer: ApplePurchaseEligibility) -> ApplePurchaseEligibility {
        ApplePurchaseEligibility(canPurchase: answer.canPurchase, reason: nil,
                                 existingProvider: answer.existingProvider)
    }

    /// The line under the products when this account may not buy here: this
    /// app's own reason when it set one (a check that failed), else that it
    /// already has a subscription.
    nonisolated static func notEligibleLine(_ eligibility: ApplePurchaseEligibility) -> String {
        eligibility.reason ?? "You already have a subscription for this."
    }
}
