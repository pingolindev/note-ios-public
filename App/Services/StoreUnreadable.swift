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

/// A trust store this app keeps and can't read now — a blob that doesn't
/// decode, or no account bound to it. Never "empty": nothing is read as "not
/// pinned", "floor 0" or "unbound", nothing is written over it, and the inbox
/// refresh stops before it fetches anything.
struct StoreUnreadable: Error, Equatable {
    let store: String
}

/// An id that isn't a UUID where one is required: an error for the caller,
/// never another id and never "not found".
struct NotAnId: Error, Equatable {
    let raw: String
}
