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

struct LoginView: View {
    @EnvironmentObject private var authManager: AuthManager
    @State private var email = ""
    @State private var password = ""
    @State private var errorMessage: String?
    @State private var emailTouched = false
    private let config = AppConfiguration.shared

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 8) {
                Image("Logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 80, height: 80)
                Text("Note")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                Text("Private notes")
                    .font(.subheadline)
                    .foregroundStyle(Color.a11ySecondaryText)
            }

            Spacer()

            VStack(spacing: 16) {
                TextField("Email", text: $email)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()

                // A malformed address is answerable here, in the same words
                // the Track iOS app uses, instead of coming back from the
                // server as "Invalid credentials".
                if showEmailFormatError {
                    Text("That doesn't look like an email address. Check for a missing \"@\" or a typo in the domain.")
                        .font(.caption)
                        .foregroundStyle(Color.a11yError)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("login-email-format-error")
                }

                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.password)

                Button(action: login) {
                    if authManager.isLoading {
                        ProgressView().tint(.white)
                    } else {
                        Text("Sign In")
                    }
                }
                .buttonStyle(A11yProminentButtonStyle())
                .disabled(email.isEmpty || password.isEmpty || authManager.isLoading)
                .frame(maxWidth: .infinity)

                // Opens the account portal, which owns the whole reset flow.
                // Note deliberately implements none of it — the password is an
                // SRP credential bound to the account's email, and a second
                // implementation of anything in that neighbourhood is a second
                // place for a lockout bug to hide.
                //
                // Without this link, someone who forgot their password would
                // have to already know the portal existed and find it in a
                // browser.
                if let forgotURL = config.forgotPasswordURL {
                    Link(destination: forgotURL) {
                        HStack(spacing: 4) {
                            Text("Forgot password?")
                            Image(systemName: "arrow.up.right.square")
                        }
                    }
                    .font(.footnote)
                    .tint(Color.a11yLink)
                    // As in the Track iOS app: performAccessibilityAudit finds this
                    // link's hit area too small without it (it lays out ~16pt tall
                    // against a 44pt minimum). contentShape makes the padded area
                    // actually tappable rather than merely reserved.
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("login-forgot-password")
                }

                // No sign-up form here either, so this says where one is:
                // without it a new user could open Note, see a password
                // prompt, and have nowhere to go. Same link-out as above, to
                // the page that owns registration.
                if let registerURL = config.registerURL {
                    HStack(spacing: 4) {
                        Text("Don't have an account?")
                            .foregroundStyle(Color.a11ySecondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        Link(destination: registerURL) {
                            HStack(spacing: 4) {
                                // Same protection the lead-in text above has.
                                // Without it this is the only label in the row
                                // that can be compressed, so it takes all of it
                                // and truncates, and the accessibility audit
                                // reports the text as clipped.
                                Text("Sign Up")
                                    .fixedSize(horizontal: false, vertical: true)
                                Image(systemName: "arrow.up.right.square")
                            }
                        }
                        .tint(Color.a11yLink)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                        .accessibilityIdentifier("login-sign-up")
                    }
                    .font(.subheadline)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(Color.a11yError)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal)

            Spacer()
        }
        .padding()
        // A sign-in that stops at the two-factor challenge leaves
        // `requires2FA` set and no session; this is where the code is entered.
        // Cancelling it clears the challenge, which drops this sheet and
        // returns to the password fields.
        .sheet(isPresented: Binding(
            get: { authManager.requires2FA },
            set: { if !$0 { authManager.cancelTwoFactorChallenge() } }
        )) {
            TwoFactorView()
        }
        // A session that ended for a reason the user did not choose (keys
        // missing on this device) says so here, once.
        .onAppear {
            if let notice = authManager.signInNotice {
                errorMessage = notice
                authManager.signInNotice = nil
            }
        }
    }

    /// Only after a submit attempt: flagging a half-typed address is noise.
    private var showEmailFormatError: Bool {
        emailTouched && !email.isEmpty && !EmailFormat.isPlausible(email)
    }

    private func login() {
        errorMessage = nil
        emailTouched = true
        guard EmailFormat.isPlausible(email) else { return }
        Task {
            do {
                try await authManager.login(email: email, password: password)
            } catch {
                errorMessage = Self.friendlyMessage(for: error)
            }
        }
    }

    /// What the sign-in screens say about a failure, in this app's words: never
    /// the server's text, which can say anything (as the Track iOS app's
    /// friendlyMessage). This app's own errors keep their words; a network
    /// failure is said in the same words the Track iOS app uses.
    nonisolated static func friendlyMessage(for error: Error) -> String {
        if let auth = error as? AuthManager.AuthError, let text = auth.errorDescription {
            return text
        }
        if let limited = error as? AuthRateLimiter.AuthRateLimitError, let text = limited.errorDescription {
            return text
        }
        if let url = error as? URLError {
            switch url.code {
            case .notConnectedToInternet,
                 .networkConnectionLost,
                 .dataNotAllowed,
                 .internationalRoamingOff:
                return "You're offline. Check your connection and try again."
            case .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return "Couldn't reach the server. Try again in a moment."
            default:
                return "Network error. Check your connection and try again."
            }
        }
        if let api = error as? APIError {
            // An address never verified is AuthError.emailNotVerified by now
            // (`login`, `twoFactorRefusal`), never "incorrect".
            let status = api.status ?? 0
            if status == 401 || status == 403 {
                return "Email or password is incorrect."
            }
            if status == 429 || api.code == "rate_limited" {
                return "Too many sign-in attempts. Try again in a moment."
            }
            if status >= 500 {
                return "The sign-in service is having trouble. Try again in a moment."
            }
        }
        return "Couldn't sign in. Please try again."
    }
}

#Preview {
    LoginView().environmentObject(AuthManager.shared)
}
