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

/// Code entry for a sign-in that stopped at the two-factor challenge.
///
/// Without it, anyone who turned two-factor on could not sign in to Note on
/// an iPhone at all — while the Terms actively tell people to turn it on.
struct TwoFactorView: View {
    @StateObject private var authManager = AuthManager.shared
    @State private var code = ""
    /// Someone without their authenticator types one of the account's backup
    /// codes instead: 12 letters and digits.
    @State private var usingBackupCode = false
    @State private var backupCode = ""
    @State private var errorMessage: String?
    @State private var showingError = false
    @FocusState private var isCodeFocused: Bool
    @FocusState private var isBackupCodeFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(Color.brandAccent)

                VStack(spacing: 8) {
                    Text("Two-Factor Authentication")
                        .font(.title2)
                        .fontWeight(.semibold)

                    Text(usingBackupCode ? "Enter one of your backup codes"
                                         : "Enter the 6-digit code from your authenticator app")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }

                if usingBackupCode {
                    backupCodeField
                } else {
                    authenticatorCodeField
                }

                Button(action: usingBackupCode ? verifyBackupCode : verify) {
                    if authManager.isLoading {
                        ProgressView().tint(.white)
                    } else {
                        Text("Verify")
                    }
                }
                // Matches Sign In on the screen this sheet comes from: the
                // stock prominent style fails contrast on both the enabled
                // fill and the disabled one, and this button spends most of
                // its life disabled (it needs six digits). See
                // A11yColors.swift. There is no .controlSize because a
                // custom ButtonStyle does not consult it.
                .buttonStyle(A11yProminentButtonStyle())
                .disabled((usingBackupCode ? Self.codeToSend(backupCode).isEmpty : code.count != 6)
                          || authManager.isLoading)
                .accessibilityIdentifier("two-factor-verify")

                Spacer()

                VStack(spacing: 8) {
                    Text("Having trouble?")
                        .foregroundStyle(.secondary)

                    Button(usingBackupCode ? "Use your authenticator app" : "Use a backup code") {
                        usingBackupCode.toggle()
                        code = ""
                        backupCode = ""
                        if usingBackupCode {
                            isBackupCodeFocused = true
                        } else {
                            isCodeFocused = true
                        }
                    }
                    .font(.footnote)
                    .tint(Color.a11yLink)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("two-factor-use-backup-code")
                }
            }
            .padding()
            .onAppear { isCodeFocused = true }
            .interactiveDismissDisabled()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // Abandon the challenge rather than logging out: no session
                    // exists yet, so there is nothing to log out of. This drops
                    // the exchange token and the stashed password and returns to
                    // the password screen.
                    Button("Cancel") { authManager.cancelTwoFactorChallenge() }
                }
            }
            .alert("Verification Failed", isPresented: $showingError) {
                Button("OK", role: .cancel) {
                    code = ""
                    backupCode = ""
                    if !authManager.twoFactorAttemptOpen {
                        // Too many wrong codes, an ended attempt, or an accepted
                        // code whose sign-in then failed: there is nothing left to
                        // answer here. Back to the password.
                        authManager.cancelTwoFactorChallenge()
                    } else if usingBackupCode {
                        isBackupCodeFocused = true
                    } else {
                        isCodeFocused = true
                    }
                }
            } message: {
                Text(errorMessage ?? "Invalid code")
            }
        }
    }

    /// The 6-digit authenticator code: a number pad, sent by itself at 6.
    private var authenticatorCodeField: some View {
        TextField("000000", text: $code)
            // A text style, not a fixed point size: .system(size:) does
            // not scale with Dynamic Type, and this is TEXT rather than
            // a decorative symbol — on the one screen whose only input
            // it is. No accessibility-audit case reaches this sheet, so
            // nothing else would catch a fixed size here. .largeTitle
            // is 34pt at the default size.
            .font(.system(.largeTitle, design: .monospaced).weight(.bold))
            .multilineTextAlignment(.center)
            .keyboardType(.numberPad)
            .textContentType(.oneTimeCode)
            .focused($isCodeFocused)
            .accessibilityIdentifier("two-factor-code")
            .onChange(of: code) { _, newValue in
                let digits = newValue.filter(\.isNumber)
                if digits != newValue { code = digits; return }
                if digits.count > 6 { code = String(digits.prefix(6)); return }
                if digits.count == 6 { verify() }
            }
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(12)
            .padding(.horizontal, 40)
    }

    /// A backup code: letters and digits, often written in groups. Sent only
    /// when the person says so (Verify, or return), never by itself at some
    /// length, and whole (`codeToSend`).
    private var backupCodeField: some View {
        TextField("Backup code", text: $backupCode)
            .font(.system(.title, design: .monospaced).weight(.bold))
            .multilineTextAlignment(.center)
            .keyboardType(.asciiCapable)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($isBackupCodeFocused)
            .submitLabel(.go)
            .onSubmit(verifyBackupCode)
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(12)
            .padding(.horizontal, 40)
            .accessibilityIdentifier("two-factor-backup-code")
    }

    private func verify() {
        guard code.count == 6 else { return }
        submit(code)
    }

    private func verifyBackupCode() {
        let sent = Self.codeToSend(backupCode)
        guard !sent.isEmpty else { return }
        submit(sent)
    }

    /// Either kind goes to the same /auth/login/2fa, as its `code`. A refusal is
    /// said in this app's words, and the sheet stays or goes by what it was.
    private func submit(_ sent: String) {
        guard !authManager.isLoading else { return }
        Task {
            do {
                try await authManager.verify2FA(code: sent)
            } catch {
                errorMessage = LoginView.friendlyMessage(for: error)
                showingError = true
            }
        }
    }

    /// The code as auth takes it, as the portal sends it: without the spaces
    /// and dashes it was typed or pasted with. Nothing is cut, and the case is
    /// left alone (auth compares a backup code in upper case).
    nonisolated static func codeToSend(_ typed: String) -> String {
        typed.filter { !$0.isWhitespace && $0 != "-" }
    }
}
