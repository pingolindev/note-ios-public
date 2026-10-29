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
import PingolinNoteSDK

extension Error {
    /// What a person reads about this failure: never text that is not this
    /// app's (as the Track iOS app's `Error.plainText`). An `APIError` is its
    /// plain line, by code: the server's `error` text can carry technical
    /// wording, or whatever a hacked server wants shown. The SDK's errors
    /// describe themselves as `MobileError.KeyNotFound(message: …)`: wording
    /// about keys, and a network one can carry the server's words. Everything
    /// else is this app's own words, or the system's.
    var plainText: String {
        if let api = self as? APIError { return api.plainLine }
        if let sdk = self as? MobileError {
            if case .NetworkError = sdk { return APIError.unreachableText }
            return APIError.failedText
        }
        return localizedDescription
    }
}
