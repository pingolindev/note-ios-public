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
import WidgetKit

@main
struct NoteApp: App {
    @UIApplicationDelegateAdaptor(PushAppDelegate.self) private var pushAppDelegate
    @StateObject private var authManager = AuthManager.shared
    @StateObject private var pushManager = PushNotificationManager.shared
    @Environment(\.scenePhase) private var scenePhase

    /// Same key and same semantics as the Track iOS app, so the two apps behave
    /// identically and a reader can compare them. Applied here, not left as a
    /// stored string nobody reads.
    @AppStorage("theme") private var themeRaw: String = "system"

    /// nil means "follow the system", which is what SwiftUI wants for that case.
    private var preferredScheme: ColorScheme? {
        switch themeRaw {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(authManager)
                .preferredColorScheme(preferredScheme)
                // Sign Up and Forgot password open inside the app, never in the
                // Safari app (App Review, Guideline 4; see InAppSafari).
                .opensWebLinksInApp()
                .task {
                    // Before any WebView exists: WebKit's data directories out of
                    // backups (the store itself is kept — it may hold edits that
                    // have not synced), and the auth cookies and cached sign-in
                    // replies that earlier versions stored removed. See
                    // WebShellDataStore / APIService.
                    WebShellDataStore.prepareAtLaunch()
                    APIService.purgeStoredAuthCookies()
                    APIService.purgeCachedResponses()
                    // Start the connectivity monitor once (self-gates on
                    // auth) so a reconnect drains the offline outbox.
                    ConnectivityMonitor.shared.start()
                    // Start listening for App Store transactions that do NOT come
                    // back from a purchase call: renewals, Ask-to-Buy approvals,
                    // refunds, and purchases made on another device. Apple wants
                    // this running before launch finishes, or a transaction
                    // delivered at launch is missed.
                    StoreKitManager.shared.startObservingTransactions()
                    await authManager.checkExistingSession()
                    // A check still waiting for the first unlock when this
                    // window went away has no answer yet: nothing here runs
                    // on it, and the next check carries on.
                    guard !authManager.isCheckingSession else { return }
                    // Tell the widgets whether anybody is signed in. It is not
                    // inferred from the snapshot being non-empty, which would
                    // make the "no notes yet" state unreachable — see
                    // SharedAppGroup.isSignedIn.
                    SharedAppGroup.isSignedIn = authManager.isAuthenticated
                    WidgetCenter.shared.reloadAllTimelines()
                    if authManager.isAuthenticated {
                        await pushManager.requestAuthorization()
                        QuotaManager.shared.refresh()
                        // Only now, because reporting needs a session. Re-reports
                        // whatever the App Store still considers current, which
                        // is what makes a reinstall work — and is the retry path
                        // for a transaction we failed to report and deliberately
                        // left unfinished.
                        await StoreKitManager.shared.restore()
                        // Drain any queued offline work + pull at launch.
                        Task { await SyncService.shared.sync() }
                    }
                }
                .onChange(of: authManager.isAuthenticated) { _, isAuthed in
                    SharedAppGroup.isSignedIn = isAuthed
                    WidgetCenter.shared.reloadAllTimelines()
                    if isAuthed {
                        Task { await pushManager.requestAuthorization() }
                        QuotaManager.shared.refresh()
                        // A fresh sign-in on a device that already holds a
                        // purchase: report it now rather than waiting for the
                        // next launch.
                        Task { await StoreKitManager.shared.restore() }
                        // A fresh login drains queued offline work + pulls.
                        Task { await SyncService.shared.sync() }
                    } else {
                        Task { await pushManager.unregister() }
                        // Drop cached tier so a stale "paid" badge can't
                        // survive into the next user's session.
                        QuotaManager.shared.clear()
                    }
                }
                // Raised at the ROOT, not on the delete sheet: deleting logs
                // out, which swaps this whole tree for the sign-in screen and
                // would take any sheet-level alert with it. The account no
                // longer exists, so there is no second chance to say that
                // Apple is still charging them.
                .alert(
                    "Account deleted",
                    isPresented: Binding(
                        get: { authManager.postDeletionNotice != nil },
                        set: { if !$0 { authManager.postDeletionNotice = nil } }
                    )
                ) {
                    Button("OK", role: .cancel) { authManager.postDeletionNotice = nil }
                } message: {
                    Text(authManager.postDeletionNotice ?? "")
                }
                .onChange(of: scenePhase) { _, phase in
                    // Refresh tier + usage on every foreground so the cached
                    // plan tracks the current one without waiting for a 402.
                    // Mirrors android MainActivity.onCreate.
                    if phase == .active, authManager.isAuthenticated {
                        QuotaManager.shared.refresh()
                        // Foregrounding drains the offline outbox + pulls. First,
                        // with notes still locked, re-check the earlier identities
                        // (at most once per window), so this sync can open what a
                        // restore elsewhere made readable.
                        Task {
                            await IdentityRecheck.shared.foreground()
                            await SyncService.shared.sync()
                        }
                    }
                }
        }
    }
}
