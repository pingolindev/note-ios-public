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

import Foundation
#if NOTE_TESTS
@testable import Note
#endif

/// The session, refreshed from the notification extension when the app's
/// access token has run out, so a phone left alone for a while still finishes
/// a share when its owner's invitee signs up. As in the Track iOS app.
///
/// Two processes must never refresh the same refresh token: a refresh retires
/// the token it was made from, and the loser's pair would be a retired one,
/// which revokes the session when it is presented later. So the rule, which
/// the app's own refresh follows too (`APIService.performRefresh`): refresh
/// holding `AppGroupLock.refresh()`, read the stored pair AGAIN under it
/// (changed: the other process refreshed, and its pair is used), save the new
/// pair, and only then use it. A pair that could not be saved is never used.
///
/// The only Keychain writes this extension makes are here, to the app's two
/// session items, and only ever as an update of items the app created.
enum ExtensionSessionRefresh {
    /// The stored pair, and the one write: a refreshed pair.
    struct TokenStore {
        var read: () -> (access: String?, refresh: String?)
        var write: (_ access: String, _ refresh: String?) -> Bool

        static let keychain = TokenStore(
            read: { (KeychainService.shared.getString(for: .accessToken),
                     KeychainService.shared.getString(for: .refreshToken)) },
            write: { KeychainService.shared.updateRefreshedPair(access: $0, refresh: $1) })
    }

    /// An access token good for `margin` more seconds: the stored one, or a
    /// refreshed one, per the rule above. nil: nothing is finished this time
    /// (the banner still shows).
    static func token(now: Date, margin: TimeInterval, authBase: String?, lock: AppGroupLock?,
                      transport: FinisherTransport, store: TokenStore,
                      wait: TimeInterval = AppGroupLock.extensionWait) async -> String? {
        let stored = store.read()
        if let access = stored.access, let claims = TokenClaims(access), claims.expiresAt > now.addingTimeInterval(margin) {
            return access
        }
        guard let authBase, let url = URL(string: authBase + "/api/v1/auth/refresh"), let lock,
              let refresh = stored.refresh, !refresh.isEmpty, refresh != "none" else { return nil }
        guard let held = await lock.acquire(timeout: wait) else { return nil }
        defer { held.release() }
        let again = store.read()
        if SessionRefresh.anotherProcessRefreshed(before: refresh, now: again.refresh) {
            return again.access
        }
        // As the app asks: the refresh token in its header, an empty body.
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(refresh, forHTTPHeaderField: "X-Refresh-Token")
        if let access = again.access, !access.isEmpty {
            request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        }
        guard let (data, response) = try? await transport.send(request), response.statusCode == 200,
              let pair = RefreshedPair.decode(data) else { return nil }
        // Still the session this refresh was made from? A sign-out, or another
        // account's sign-in (which does not take this lock), meanwhile: its items
        // are not overwritten with this pair, and the pair is not used.
        guard store.read().refresh == refresh else { return nil }
        guard store.write(pair.accessToken, pair.refreshToken) else { return nil }
        return pair.accessToken
    }

    /// `/auth/refresh`'s answer, with or without the `{success, data}` envelope.
    struct RefreshedPair: Decodable, Equatable {
        let accessToken: String
        let refreshToken: String?

        static func decode(_ data: Data) -> RefreshedPair? {
            struct Envelope: Decodable { let data: RefreshedPair? }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let pair = (try? decoder.decode(Envelope.self, from: data))?.data
                ?? (try? decoder.decode(RefreshedPair.self, from: data))
            guard let pair, !pair.accessToken.isEmpty else { return nil }
            return pair
        }
    }
}
