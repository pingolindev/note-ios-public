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

import XCTest
@testable import Note

/// A typo catcher, kept identical to track-ios. The cases that matter are the ones it must NOT reject —
/// an over-strict rule locks a real user out of their own account, which is
/// far worse than the round trip it saves.
final class EmailFormatTests: XCTestCase {

    func testRealAddressesArePlausible() {
        let good = [
            "test-user1@example.test",
            "test-user1+tag2@example.test",              // sub-addressing
            "a@b.co",
            "first.last@example.co.uk",
            "user_name@example-host.com",
            "UPPER@EXAMPLE.COM",
            "  spaced@example.com  ",                    // trimmed, not rejected
            "quoted!#$%&'*+/=?^`{|}~@example.com",       // legal RFC 5322 local-part characters
        ]
        for value in good {
            XCTAssertTrue(EmailFormat.isPlausible(value), "\(value) must be accepted")
        }
    }

    func testOnlyTheImpossibleIsRejected() {
        let bad = [
            "",
            "   ",
            "notanemail",                 // no "@"
            "@example.com",               // nothing before the @
            "user@",                      // nothing after it
            "user@@example.com",          // two @
            "user name@example.com",      // whitespace inside
            "user@localhost",             // no dot in the domain
            "user@.com",                  // domain starts with the dot
            "user@example.",              // domain ends with it
            "user@example..com",          // empty label
        ]
        for value in bad {
            XCTAssertFalse(EmailFormat.isPlausible(value), "\(value) must be rejected")
        }
    }
}
