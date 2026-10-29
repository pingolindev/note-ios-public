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

import SwiftUI
import UIKit

/// Native settings for Note.
///
/// This screen holds ONLY what the web Settings panel cannot do. A setting kept
/// in both places drifts (a native Appearance writing `@AppStorage("theme")`
/// while the page writes `localStorage['pingolin_note_settings']` would move the
/// page only when the page's own theme was set to System), so everything else
/// lives on the page:
///
///   Plan     the page shows it, and purchase does not run through here —
///            `pingolin-upgrade` sets `showPremium` on the shell, a separate
///            sheet, so StoreKit is reached whether or not this screen exists.
///   Account  email, display name and the recovery-email link are all on the
///            page (its Settings panel reads them off the same `/auth/me`),
///            and sign-out hands off to the native flow through
///            `__pingolinShellSignOut`, which runs the same confirm + teardown.
///   Appearance  see above.
///   Editor   the page owns editor mode and its pins.
///   Data     the page seals exports with a passphrase too.
///
/// The Android app splits it the same way: its native screen holds Security,
/// Notifications, Diagnostics and About, and the page renders those as rows with
/// live values. See `WebAppDeviceState`. Its native settings layout also carries
/// Logout and Delete Account (hidden when a section is focused), so both account
/// actions are natively reachable there, and an absent section opens the screen
/// normally.
struct SettingsView: View {
    /// Which group to show, or nil for the whole screen.
    ///
    /// The page deep-links one group at a time (`pingolin-settings://open?section=…`)
    /// so the crossing reads as part of the panel rather than a second
    /// Settings app. Android achieves the same by hiding every other group and
    /// its heading (`applySectionFocus`); rendering only the one asked for is
    /// the same idea with less to go wrong. nil is the failure view's entry
    /// point, where the person needs everything.
    let focus: String?

    init(focus: String? = nil) { self.focus = focus }

    private func shows(_ section: String) -> Bool { focus == nil || focus == section }

    /// The sheet's own title says which group this is, so the group heading
    /// inside it would say it twice — Android hides the heading for exactly
    /// this reason.
    private var title: String {
        switch focus {
        case WebAppDeviceState.sectionSecurity: return "Security"
        case WebAppDeviceState.sectionNotifications: return "Notifications"
        case WebAppDeviceState.sectionDiagnostics: return "Diagnostics"
        case WebAppDeviceState.sectionAbout: return "About"
        case WebAppDeviceState.sectionAccount: return "Account"
        default: return "Settings"
        }
    }

    /// A Form section whose header is OMITTED when focused, rather than set to
    /// an empty string.
    ///
    /// `Section("")` would take the *titled* overload and build a header view
    /// holding empty text — a header that exists, with no name, which
    /// VoiceOver announces as an unlabelled element. The Android app collapses
    /// the equivalent view outright (`visibility = View.GONE`); the headerless
    /// overload is the same idea said in SwiftUI. The header is hidden at all
    /// because the sheet's own title already names the group.
    @ViewBuilder
    private func group<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if focus == nil {
            Section(title) { content() }
        } else {
            Section { content() }
        }
    }

    @EnvironmentObject private var authManager: AuthManager
    @ObservedObject private var appLock = AppLockManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var appLockToggle: Bool = AppConfiguration.shared.appLockEnabled
    @State private var autoLockTimeout: AutoLockTimeout = AppConfiguration.shared.autoLockTimeout
    @State private var hideInAppSwitcher: Bool = AppConfiguration.shared.hideInAppSwitcher
    @State private var integrity: JailbreakDetector.Result = JailbreakDetector.Result(isJailbroken: false, reasons: [])
    @State private var showIntegrityDetails = false
    @State private var pushMode: PushDeliveryMode = AppConfiguration.shared.pushDeliveryMode
    @State private var notificationDetail: NotificationDetailLevel = AppConfiguration.shared.notificationDetail
    @State private var showingDeleteAccountConfirm = false
    /// Read in `onAppear` like `integrity`, rather than inline: it is a UIKit
    /// snapshot, not something SwiftUI observes. Defaults to `.available` so
    /// the screen never accuses iOS of blocking a refresh it has not yet been
    /// asked about.
    @State private var backgroundRefresh: UIBackgroundRefreshStatus = .available
    #if DEBUG
    @State private var environment: AppEnvironment = AppConfiguration.shared.environment
    #endif

    private let config = AppConfiguration.shared

    var body: some View {
        NavigationStack {
            Form {
                // Security and Notifications are SEPARATE sections, matching
                // Android's section ids: one "Security" heading carrying
                // push delivery and notification detail could not be
                // deep-linked into meaningfully by the page, and would put
                // "Push delivery" under a heading that does not describe it.
                if shows(WebAppDeviceState.sectionSecurity) {
                    group("Security") {
                        Toggle(isOn: $appLockToggle) {
                            Label("Require \(appLock.biometryLabel)", systemImage: "lock.fill")
                        }
                        .accessibilityIdentifier("app-lock-toggle")
                        .onChange(of: appLockToggle) { _, newValue in
                            Task {
                                await appLock.setEnabled(newValue)
                                // If the user cancelled the LA prompt the
                                // config flag won't actually flip; re-sync
                                // the toggle to whatever ended up persisting.
                                appLockToggle = config.appLockEnabled
                            }
                        }
                        if let lastError = appLock.lastError {
                            Text(lastError).font(.caption).foregroundStyle(Color.a11yError)
                        }
                        // Only meaningful while app lock is on, so it is
                        // disabled rather than hidden — a control that vanishes
                        // is a control nobody knows exists.
                        Picker("Auto-lock", selection: $autoLockTimeout) {
                            ForEach(AutoLockTimeout.allCases, id: \.self) { option in
                                Text(option.displayName).tag(option)
                            }
                        }
                        .disabled(!appLockToggle)
                        .accessibilityIdentifier("auto-lock-picker")
                        .onChange(of: autoLockTimeout) { _, newValue in
                            AppConfiguration.shared.autoLockTimeout = newValue
                        }
                        Toggle(isOn: $hideInAppSwitcher) {
                            Label("Hide in app switcher", systemImage: "rectangle.on.rectangle")
                        }
                        .accessibilityIdentifier("hide-in-app-switcher-toggle")
                        .onChange(of: hideInAppSwitcher) { _, newValue in
                            AppConfiguration.shared.hideInAppSwitcher = newValue
                        }
                        // Says what iOS can and cannot do, rather than letting
                        // the label imply note-android's "Block screenshots".
                        // Apple provides no API to prevent a screenshot, so
                        // claiming to block one would be a lie.
                        Text("Covers your notes while Note is not the app in front, so they do not appear in the multitasking switcher. iOS cannot prevent screenshots.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button {
                            if integrity.isJailbroken { showIntegrityDetails = true }
                        } label: {
                            HStack {
                                Image(systemName: integrity.isJailbroken ? "exclamationmark.shield.fill" : "checkmark.shield.fill")
                                    .foregroundStyle(integrity.isJailbroken ? Color.a11yError : Color.a11ySuccess)
                                VStack(alignment: .leading) {
                                    Text(integrity.isJailbroken ? "Device integrity: compromised" : "Device integrity: OK")
                                    if integrity.isJailbroken, let first = integrity.reasons.first {
                                        Text(first)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if integrity.isJailbroken {
                                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("integrity-status")
                    }
                }

                if shows(WebAppDeviceState.sectionNotifications) {
                    group("Notifications") {
                        Picker("Push delivery", selection: $pushMode) {
                            ForEach(PushDeliveryMode.allCases, id: \.self) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .accessibilityIdentifier("push-delivery-picker")
                        .onChange(of: pushMode) { _, newMode in
                            Task {
                                await PushNotificationManager.shared.switchMode(to: newMode)
                            }
                        }
                        if pushMode == .polling {
                            // Say what is true on THIS device rather than what
                            // is true in principle. Polling schedules a
                            // BGAppRefreshTask, and iOS runs none if the user
                            // has Background App Refresh off — common on Low
                            // Power Mode and on battery-conscious setups. Copy that
                            // promised "every 15 min – 1 h" unconditionally would be
                            // wrong then, and the person who chose Polling chose it
                            // for privacy, so being wrong about delivery is exactly
                            // the wrong place to be vague.
                            if backgroundRefresh == .available {
                                Text("Polling skips Apple Push Notifications. New shares + reminders appear when iOS schedules a background refresh (typically every 15 min – 1 h) or when you next open Note.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Background App Refresh is off, so nothing will arrive until you open Note. Polling skips Apple Push Notifications and relies on that refresh.")
                                    .font(.caption)
                                    .foregroundStyle(Color.a11yError)
                                    .accessibilityIdentifier("polling-background-refresh-off")
                                if let settings = URL(string: UIApplication.openSettingsURLString) {
                                    Link("Open iOS Settings", destination: settings)
                                        .font(.caption)
                                        .frame(minHeight: 44)
                                        .contentShape(Rectangle())
                                }
                            }
                        }
                        Picker("Notification detail", selection: $notificationDetail) {
                            ForEach(NotificationDetailLevel.allCases, id: \.self) { level in
                                Text(level.displayName).tag(level)
                            }
                        }
                        .accessibilityIdentifier("notification-detail-picker")
                        .onChange(of: notificationDetail) { _, newLevel in
                            AppConfiguration.shared.notificationDetail = newLevel
                        }
                        if notificationDetail != .full {
                            Text("Limits how much decrypted note content appears in reminders, the pinned-note notification, and widgets.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // DEBUG ONLY, section and all, the API rows included: an
                // installed build ignores the persisted environment override,
                // so in Release these rows would misreport (with
                // `app_environment` set to local the sheet would still say
                // Development and show the development hosts). A value that is
                // wrong is worse than one that is absent.
                #if DEBUG
                if shows(WebAppDeviceState.sectionDiagnostics) {
                Section("Environment") {
                    // Switching to a non-production environment re-points the
                    // API base URLs. Shipping this control in Release would let
                    // anyone repoint a signed build at other hosts, so it must
                    // never appear there.
                    Picker("Environment", selection: $environment) {
                        ForEach(AppEnvironment.allCases, id: \.self) { env in
                            Text(env.rawValue.capitalized).tag(env)
                        }
                    }
                    .accessibilityIdentifier("environment-picker")
                    .onChange(of: environment) { _, newValue in
                        config.environment = newValue
                    }
                    LabeledContent("Auth API", value: shortURL(config.authBaseURL))
                    LabeledContent("Notes API", value: shortURL(config.apiBaseURL))
                    Text("Switching environments takes effect on the next request. Sign out + sign in again for a clean session.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                }
                #endif

                // About answers "what am I running"; Diagnostics answers "what
                // is wrong". Different questions, so different sections -- and
                // the sheet can title each correctly instead of calling one of
                // them by the other's name. Matches note-android's split.
                if shows(WebAppDeviceState.sectionAbout) {
                group("About") {
                    LabeledContent("Version", value: "\(config.appVersion) (\(config.buildNumber))")
                    NavigationLink(destination: OpenSourceLicensesView()) {
                        Label("Open Source Licenses", systemImage: "doc.plaintext")
                    }
                }
                }

                if shows(WebAppDeviceState.sectionDiagnostics) {
                group("Diagnostics") {
                    // The one diagnostic iOS has in Release. Without it this
                    // section would be empty outside DEBUG -- a row on the
                    // panel opening a blank sheet, a dead end.
                    LabeledContent("Device ID", value: authManager.deviceId ?? "—")
                }
                }

                // Last section, matching track-ios: the destructive account
                // action sits at the bottom, away from everything reversible.
                //
                // It has its own section, so a focused sheet is titled Account
                // and can say what account actions ARE, and it never ends with
                // Delete Account sitting under, say, "Push delivery". It is
                // not folded into Diagnostics: that would force one group to
                // describe two different things, and the page would render it
                // under "These are set on this device" — which is wrong about
                // a button that deletes the account on every device.
                //
                // It cannot be gated on `focus == nil`. The page always sends
                // a section and the no-section fallback only renders when
                // there are no rows at all, so `focus == nil` happens in
                // exactly one place: the offline retry view. Delete Account —
                // and with it the warning that an App Store subscription must
                // be cancelled by the customer, which appears nowhere else in
                // the product — would only be reachable by a user with no
                // network.
                if shows(WebAppDeviceState.sectionAccount) {
                Section {
                    Button(role: .destructive) {
                        showingDeleteAccountConfirm = true
                    } label: {
                        Label("Delete Account", systemImage: "trash")
                    }
                    .accessibilityIdentifier("settings-delete-account")
                } footer: {
                    // The iOS spelling of Android's per-section subtitle.
                    // Everything else on this screen is device-local;
                    // this is not, and saying so before the tap is cheaper
                    // than saying it after.
                    Text("These apply to your whole account, on every device.")
                }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(focus == nil ? .large : .inline)
            // A visible way out: without it the only dismissal is a
            // swipe-down, with no affordance saying so — fine for a gesture
            // user, awkward for Switch Control and Voice Control. The two
            // sheets nested inside this one (Device integrity, Delete Account)
            // both have one too.
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("settings-done")
                }
            }
            .sheet(isPresented: $showingDeleteAccountConfirm) {
                NavigationStack { DeleteAccountSheet() }
            }
            .onAppear {
                integrity = JailbreakDetector.check()
                backgroundRefresh = UIApplication.shared.backgroundRefreshStatus
            }
            .sheet(isPresented: $showIntegrityDetails) {
                NavigationStack {
                    List {
                        Section {
                            HStack(spacing: 12) {
                                Image(systemName: "exclamationmark.shield.fill")
                                    .font(.title)
                                    .foregroundStyle(Color.a11yError)
                                Text("This device shows signs of having been jailbroken. The list below shows what was detected. Detection is informational today; future releases may restrict sign-in on compromised devices.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Section("Reasons") {
                            ForEach(integrity.reasons, id: \.self) { reason in
                                Text(reason).font(.footnote)
                            }
                        }
                    }
                    .navigationTitle("Device integrity")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showIntegrityDetails = false }
                        }
                    }
                }
            }
        }
        // A focused sheet is two Picker rows and a caption — roughly 150pt of
        // content, which at .large would sit stranded at the top of a
        // ~785pt sheet on a 390x844 phone with the title out of one-handed
        // reach on a 430x932. note-android presents the same content as a
        // BottomSheetDialogFragment (DeviceSettingsSheet) so that the notes
        // stay behind it and it is dismissed, not navigated away from. A
        // detented sheet is the iOS spelling of that, where a full-height one
        // says "a whole other screen". The full screen keeps .large: it really
        // is one.
        .presentationDetents(focus == nil ? [.large] : [.medium, .large])
        .presentationDragIndicator(.visible)
    }

    #if DEBUG
    /// Only the Environment section uses this, and that section is DEBUG-only.
    private func shortURL(_ url: String) -> String {
        url.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
    }
    #endif
}


/// Confirm-and-delete for the account. Mirrors track-ios's sheet of the same
/// name, because it is the same account and the same endpoint.
struct DeleteAccountSheet: View {
    @StateObject private var authManager = AuthManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var password: String = ""
    @State private var confirmText: String = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    /// Non-nil raises the credit question below: the account still holds
    /// bought credit, and nothing has been deleted at that point.
    @State private var creditWarning: String?

    /// Under "You still have credit", in place of the server's sentence (which
    /// named the amount): the same facts and the same two ways on (the Track
    /// iOS app's words).
    nonisolated static let unspentCreditText = "Deleting your account destroys the credit on it, and it can't be returned "
        + "afterwards because the record goes with the account. Write to help@support.pingolin.com to have it "
        + "refunded first, or delete anyway."

    /// The circles this account owns in Track go with it, for everyone in them:
    /// track's account deletion destroys owned circles outright, their history
    /// with them. Every delete screen says so before the button, in the same
    /// words as the portal and Android.
    nonisolated static let ownedCirclesText = "Circles you own in Pingolin Track are deleted for everyone in them, "
        + "along with all the location history they hold. To keep a circle going, transfer its ownership in "
        + "Track first."

    var body: some View {
        Form {
            Section {
                Text("Deleting your account permanently removes your notes, notebooks, attachments, shares and reminders. This cannot be undone.")
                    .font(.subheadline)
                Text(Self.ownedCirclesText)
                    .font(.subheadline)
            }

            // The account is the auth-service account, not a per-app one, and
            // deleting it cascades into every app that hangs off it.
            // Someone deleting from Note has no way to know their location
            // history goes with it unless we say so here, before the button.
            Section {
                Text("This is your Pingolin account, which every Pingolin app shares. Deleting it deletes your data in all of them — Pingolin Note and Pingolin Track — not just this app.")
                    .font(.subheadline)
            }

            // Billing, stated before the button rather than after it. Deleting
            // cancels what the server can cancel; an App Store subscription only
            // the customer can stop, in Apple's settings. Once the account is gone
            // there is no screen left to tell them that on — so it goes here,
            // where they can still act on it.
            Section {
                Text("Deleting your account also cancels your subscription. If you subscribed through the App Store, only you can cancel that - in Settings, tap your name, then Subscriptions. We cannot do it for you.")
                    .font(.subheadline)
            }

            Section("Password") {
                SecureField("Your account password", text: $password)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .disabled(isSubmitting)
                    .accessibilityIdentifier("delete-account-password")
            }

            Section {
                TextField("Type DELETE to confirm", text: $confirmText)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
                    .disabled(isSubmitting)
                    .accessibilityIdentifier("delete-account-confirm")
            } footer: {
                Text("Belt-and-braces guard against accidental taps.")
            }

            if let err = errorMessage {
                Section {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Color.a11yError)
                }
            }

            Section {
                Button(role: .destructive) {
                    Task { await submit() }
                } label: {
                    HStack {
                        if isSubmitting {
                            ProgressView().padding(.trailing, 4)
                        }
                        Text(isSubmitting ? "Deleting…" : "Delete My Account")
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(!canSubmit)
                .accessibilityIdentifier("delete-account-submit")
            }
        }
        .navigationTitle("Delete Account")
        // Nothing has been deleted yet. "Keep my credit" is the cancel role so
        // it is the safe default, and the destructive one is not what a stray
        // tap finds.
        .alert(
            "You still have credit",
            isPresented: Binding(
                get: { creditWarning != nil },
                set: { if !$0 { creditWarning = nil } }
            )
        ) {
            Button("Keep my credit", role: .cancel) { creditWarning = nil }
            Button("Delete anyway", role: .destructive) {
                creditWarning = nil
                Task { await submit(forfeitCredit: true) }
            }
        } message: {
            Text(creditWarning ?? "")
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") { dismiss() }
                    .disabled(isSubmitting)
            }
        }
    }

    private var canSubmit: Bool {
        guard !isSubmitting else { return false }
        return !password.isEmpty && confirmText == "DELETE"
    }

    private func submit(forfeitCredit: Bool = false) async {
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            // Any billing notice is published on AuthManager, not held here.
            // `deleteAccount` logs out, which swaps the whole view tree for
            // the sign-in screen and takes this sheet with it — an alert
            // raised on the sheet would never be seen. NoteApp shows it at the
            // root instead.
            try await authManager.deleteAccount(
                password: password,
                forfeitCreditBalance: forfeitCredit
            )
            dismiss()
        } catch let apiError as APIError
            where apiError.code == "unspent_credit_balance" {
            // This app puts the server's `error_code` in `code` (falling back to
            // http_<status>), unlike the Track iOS app, which carries a separate
            // `errorCode`.
            // The server is asking a question, not reporting a failure — nothing
            // has been deleted. The balance is money this account paid for. In
            // this app's words: the server's are never shown.
            creditWarning = Self.unspentCreditText
        } catch {
            errorMessage = error.plainText
        }
    }
}
