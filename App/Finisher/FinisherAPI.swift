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

/// Sends one request. The live one is an ephemeral session: every request
/// carries the session token, so nothing about it may be kept on disk.
protocol FinisherTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionFinisherTransport: FinisherTransport {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        // System trust minus the leaked emSign keys, as every other session.
        return TrustBlocklist.session(configuration: configuration)
    }()

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// The note API as the finisher uses it: the owner's bearer token, the
/// `{success, data}` envelope, and a timeout that never runs past the pass's
/// deadline. A request that could not be made, or that was not answered,
/// reads as no answer (nil) and concludes nothing.
struct FinisherAPI {
    let base: String
    let token: String
    let transport: FinisherTransport
    let deadline: Date
    let now: () -> Date
    var userAgent: String?

    /// The server's cap on one key lookup.
    static let lookupBatch = 100

    var remaining: TimeInterval { deadline.timeIntervalSince(now()) }

    /// What the finisher reads of an item (`GET /api/v1/items/{id}`).
    struct ItemKey: Equatable {
        let userId: String?
        let itemType: Int?
        let deleted: Bool
        let wrappedContentKey: String?
        let wrappedContentKeyNonce: String?
        /// Absent or null: the base generation, 1.
        let contentKeyGeneration: Int64?
    }

    /// `GET /api/v1/shares/unfinished`; a row that is not one is skipped.
    func unfinished() async -> [InvitationFinisher.UnfinishedShare]? {
        guard let (data, status) = await send(request("/api/v1/shares/unfinished", method: "GET", body: nil)),
              status == 200, let rows = Self.payload(data) as? [Any]
        else { return nil }
        return rows.compactMap { ($0 as? [String: Any]).flatMap(InvitationFinisher.UnfinishedShare.init(json:)) }
    }

    /// `GET /api/v1/items/{id}`. `id` is an id in its one form.
    func item(_ id: String) async -> ItemKey? {
        guard let (data, status) = await send(request("/api/v1/items/\(id)", method: "GET", body: nil)),
              status == 200, let item = Self.payload(data) as? [String: Any]
        else { return nil }
        let generation: Int64?
        switch item["content_key_generation"] {
        case nil, is NSNull: generation = nil
        case let value:
            // A generation that is not an integer is no answer: never signed under a guess.
            guard let g = StrictJSON.int64(value) else { return nil }
            generation = g
        }
        return ItemKey(
            userId: item["user_id"] as? String,
            itemType: StrictJSON.int(item["item_type"]),
            deleted: StrictJSON.bool(item["deleted"]) ?? false,
            wrappedContentKey: item["wrapped_content_key"] as? String,
            wrappedContentKeyNonce: item["wrapped_content_key_nonce"] as? String,
            contentKeyGeneration: generation)
    }

    /// `POST /api/v1/users/public-keys`, lower-cased and deduplicated, at most
    /// `lookupBatch` addresses a call: the keys by lower-cased address, for
    /// every address with an account and a full key set. nil when any call
    /// failed: no answer is never "no account".
    func lookup(_ emails: [String]) async -> [String: InvitationFinisher.DirectoryKeys]? {
        var unique: [String] = []
        for email in emails {
            let value = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !value.isEmpty, !unique.contains(value) { unique.append(value) }
        }
        var out: [String: InvitationFinisher.DirectoryKeys] = [:]
        var start = 0
        while start < unique.count {
            let batch = Array(unique[start..<min(start + Self.lookupBatch, unique.count)])
            guard let (data, status) = await send(request("/api/v1/users/public-keys", method: "POST",
                                                          body: ["emails": batch])),
                  status == 200,
                  let users = (Self.payload(data) as? [String: Any])?["users"] as? [Any]
            else { return nil }
            for case let user as [String: Any] in users {
                guard let email = user["email"] as? String,
                      let id = Self.nonEmpty(user["user_id"]),
                      let sharing = Self.nonEmpty(user["sharing_public_key"]),
                      let signing = Self.nonEmpty(user["signing_public_key"])
                else { continue }
                out[email.lowercased()] = InvitationFinisher.DirectoryKeys(userId: id, sharingPub: sharing,
                                                                           signingPub: signing)
            }
            start += Self.lookupBatch
        }
        return out
    }

    /// `POST /api/v1/items/{id}/share`: the status and the server's
    /// `error_code`, or nil when there was no answer.
    func finish(itemId: String, body: [String: Any]) async -> (status: Int, errorCode: String?)? {
        guard let (data, status) = await send(request("/api/v1/items/\(itemId)/share", method: "POST", body: body))
        else { return nil }
        let code = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error_code"] as? String
        return (status, code)
    }

    // MARK: - Plumbing

    /// The request, or nil when there is no time left for one.
    func request(_ path: String, method: String, body: [String: Any]?) -> URLRequest? {
        let left = remaining
        guard left > 1, let url = URL(string: base + path) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = min(8, left - 0.5)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let userAgent { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        if let body {
            guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
            request.httpBody = data
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func send(_ request: URLRequest?) async -> (Data, Int)? {
        guard let request, let (data, response) = try? await transport.send(request) else { return nil }
        return (data, response.statusCode)
    }

    /// The `data` of the server's envelope, else the bare value.
    static func payload(_ data: Data) -> Any? {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        if let envelope = object as? [String: Any], let inner = envelope["data"] { return inner }
        return object
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let s = value as? String, !s.isEmpty else { return nil }
        return s
    }
}

/// The claims of an access token a background run needs, read without
/// verifying it: the server verifies every request; this only decides whether
/// one is worth making, and for whom.
struct TokenClaims {
    let subject: String
    let expiresAt: Date

    init?(_ token: String) {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sub = json["sub"] as? String, !sub.isEmpty,
              let exp = (json["exp"] as? NSNumber)?.doubleValue else { return nil }
        subject = sub
        expiresAt = Date(timeIntervalSince1970: exp)
    }
}
