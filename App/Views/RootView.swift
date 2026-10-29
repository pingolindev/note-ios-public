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

struct RootView: View {
    @EnvironmentObject private var authManager: AuthManager
    @ObservedObject private var appLock = AppLockManager.shared
    /// Watched for `pageReady`, so the splash can hold until the web app has
    /// actually painted rather than being dismissed on the auth result.
    @ObservedObject private var shell = WebShellModel.shared
    @Environment(\.scenePhase) private var scenePhase

    /// Neutral "app opening" cover. The app icon rather than a bare spinner, so
    /// the wait reads as the app opening rather than as something having gone
    /// wrong.
    private var sessionSplash: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "note.text")
                    .font(.system(size: 44))
                    .foregroundStyle(Color.accentColor)
                ProgressView()
            }
        }
        .accessibilityIdentifier("session-splash")
    }

    var body: some View {
        ZStack {
            // AUTHENTICATED IS CHECKED FIRST, before `isCheckingSession`.
            //
            // checkExistingSession() sets isAuthenticated as soon as it finds
            // a stored token, so a returning user reaches this branch on the
            // FIRST frame and the web boot starts immediately instead of
            // behind the getMe() round trip. The splash below is still shown
            // — as an overlay, until the page actually paints — so the wait
            // does useful work without showing.
            if authManager.isAuthenticated {
                // The single-store shell: the web app carries notes, inbox
                // and sharing; native keeps login, app lock, settings,
                // widgets and the share extension. Mirrors note-android's
                // MainActivity -> WebAppActivity routing.
                WebShellView()
            } else if authManager.isCheckingSession {
                // No stored token: this is the instant before the guard in
                // checkExistingSession returns, so it is a blink rather than a
                // wait. It still must not be the LOGIN SCREEN — a sign-in form
                // says "you are signed out", which for somebody who is about to
                // land in their notes is both wrong and alarming.
                sessionSplash
            } else {
                LoginView()
            }

            // The splash, over the shell, until the web app paints.
            //
            // Dismissed on the AUTH RESULT, the splash would leave the user
            // watching a BLANK WKWebView for the whole web boot. Tied to the
            // page, it is one continuous "app opening" state through to real
            // content. `.zIndex` below LockScreenView so app lock still wins.
            //
            // `loadFailed` MUST be part of the condition. `pageReady` is only
            // ever set from didFinish, so a navigation that fails instead of
            // finishing leaves it false forever — and this cover would then sit
            // on top of the retry view the shell renders for exactly that case
            // (WebShellView's `if model.loadFailed`), with no way out.
            if authManager.isAuthenticated && !shell.pageReady && !shell.loadFailed {
                sessionSplash
                    .transition(.opacity)
                    .zIndex(0.5)
            }
            if authManager.isAuthenticated && appLock.isLocked {
                LockScreenView()
                    .transition(.opacity)
                    .zIndex(1)
            }
            // Cover note content whenever the app is not frontmost, so it does
            // not end up in the multitasking switcher's snapshot.
            //
            // Independent of app lock ON PURPOSE. `AppLockManager.lock()`
            // returns early unless app lock is enabled, so with it off — the
            // default — every note on screen would go straight into the
            // switcher. note-android covers this with its own "Block
            // screenshots" switch, likewise separate from the PIN.
            //
            // `.inactive` is the phase the snapshot is taken in, so it has to
            // be part of the condition; waiting for `.background` is too late.
            if authManager.isAuthenticated
                && AppConfiguration.shared.hideInAppSwitcher
                && scenePhase != .active {
                ZStack {
                    Color(.systemBackground).ignoresSafeArea()
                    Image(systemName: "lock.doc")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                }
                .zIndex(2)
                .accessibilityIdentifier("app-switcher-cover")
            }
        }
        // Only the opening->content step is animated. A fade on
        // `isAuthenticated` would also fade every sign-out, and a sign-out
        // should feel immediate.
        .animation(.easeInOut(duration: 0.2), value: authManager.isCheckingSession)
        .animation(.easeInOut(duration: 0.2), value: shell.pageReady)
        .animation(.easeInOut(duration: 0.2), value: shell.loadFailed)
        .onChange(of: scenePhase) { _, phase in
            // Mirrors android's SessionManager.shouldRequireAppLockAuth: note
            // when we left, and decide on the way back. Locking on the way OUT
            // would ignore the auto-lock timeout entirely — every switch away
            // would mean a prompt on return, whatever the setting said.
            switch phase {
            case .background, .inactive:
                appLock.noteBackgrounded()
            case .active:
                appLock.lockIfTimedOut()
            @unknown default:
                appLock.lock()
            }
        }
        .onChange(of: authManager.isAuthenticated) { _, authed in
            // EVERY sign-out path must destroy the shell — the WebView's
            // storage holds decrypted note content and the sessionStorage
            // key handoff, and native Settings' logout button never passes
            // through the shell's own confirm flow. An expiry keeps that
            // storage for the same account, after the page's last keep of its
            // trust; every other end wipes it.
            if !authed {
                let keepData = authManager.sessionEnd.keepsWebsiteData
                Task { @MainActor in await WebShellModel.shared.endSession(keepData: keepData) }
            }
        }
        .onOpenURL { url in
            handleDeepLink(url)
        }
        .onReceive(NotificationCenter.default.publisher(for: .pushOpenInbox)) { _ in
            // The shares inbox lives inside the web app's home view.
            WebShellModel.shared.navigate(to: "/")
        }
        .onReceive(NotificationCenter.default.publisher(for: .pushOpenNote)) { event in
            if let refId = event.object as? String {
                WebShellModel.shared.navigate(to: "/note/\(refId)")
            }
        }
    }

    /// noteapp://create — the web composer route.
    /// noteapp://item/{id} — the web note route. Paths come
    /// from the web editor's router: `/new` and `/note/:id`.
    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "noteapp" else { return }
        switch url.host {
        case "create":
            WebShellModel.shared.navigate(to: "/new")
        case "item":
            // noteapp://item/{id} — pluck the id off the path.
            if let id = url.pathComponents.dropFirst().first {
                WebShellModel.shared.navigate(to: "/note/\(id)")
            }
        default:
            break
        }
    }
}

/// Biometric / passcode gate shown over the authenticated shell.
/// Also doubles as the privacy screen on app-switcher because it
/// blanks the underlying content via the .zIndex overlay.
struct LockScreenView: View {
    @ObservedObject private var appLock = AppLockManager.shared

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(Color.brandAccent)
                Text("Note is locked")
                    .font(.title2)
                    .fontWeight(.semibold)
                Button {
                    Task { await appLock.unlock() }
                } label: {
                    Label("Unlock", systemImage: "lock.open.fill")
                }
                // A11yProminentButtonStyle rather than .borderedProminent: the
                // stock style fills with the app accent and renders DISABLED
                // as gray-on-gray at ~1.8:1, which .tint cannot reach
                // (see A11yColors.swift). The 220 cap sits outside the
                // style, which applies maxWidth: .infinity to the label
                // itself; there is no .controlSize because a custom
                // ButtonStyle does not consult it — the style's own
                // padding(.vertical, 14) is what sizes it.
                .buttonStyle(A11yProminentButtonStyle())
                .frame(maxWidth: 220)
                .accessibilityIdentifier("lock-screen-unlock")
                if let err = appLock.lastError {
                    Text(err)
                        .font(.footnote)
                        .foregroundStyle(Color.a11yError)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            }
        }
        .onAppear {
            Task { await appLock.unlock() }
        }
    }
}

#Preview {
    RootView().environmentObject(AuthManager.shared)
}
