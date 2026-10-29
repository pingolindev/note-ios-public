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

/// The per-account stores are named by the account id's one form, and what
/// an older build kept under another spelling of it joins it: pins by the
/// pin-merge rule, floors by the highest generation. Another account's are
/// never touched.
final class AccountStoreSpellingTests: XCTestCase {

    private let me = "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"
    private let other = "1a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"
    private let alice = "2a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"
    private let bob = "3a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"
    private let item = "4a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"
    private let signA = String(repeating: "a", count: 64)
    private let shareA = String(repeating: "b", count: 64)
    private let signB = String(repeating: "c", count: 64)
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suite = "AccountStoreSpellingTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    private typealias Pin = SenderKeyPinStore.PinRecord

    private func putPins(_ key: String, _ pins: [String: Pin]) throws {
        defaults.set(try JSONEncoder().encode(pins), forKey: key)
    }

    private func pins(_ key: String) throws -> [String: Pin]? {
        try defaults.data(forKey: key).map { try JSONDecoder().decode([String: Pin].self, from: $0) }
    }

    // MARK: - Pins

    func testTheNamespaceIsTheIdsOneForm() throws {
        let store = SenderKeyPinStore(defaults: defaults)
        store.switchUser(me.uppercased())
        try store.pin(ownerId: alice, signingPubHex: signA, sharingPubHex: shareA)
        XCTAssertNotNil(try pins("note_sender_pins.\(me)")?[alice])
        XCTAssertNil(defaults.data(forKey: "note_sender_pins.\(me.uppercased())"))
    }

    func testPinsUnderAnotherSpellingOfThisAccountJoinIt() throws {
        try putPins("note_sender_pins.\(me.uppercased())", [alice: Pin(signingPubHex: signA, sharingPubHex: shareA, pinnedAt: 200)])
        try putPins("note_sender_pins.{\(me)}", [alice.uppercased(): Pin(signingPubHex: signA, sharingPubHex: nil, pinnedAt: 50)])
        try putPins("note_sender_pins.\(me)", [bob: Pin(signingPubHex: signB, sharingPubHex: nil, pinnedAt: 300)])
        try putPins("note_sender_pins.\(other)", [alice: Pin(signingPubHex: signB, sharingPubHex: nil, pinnedAt: 1)])
        let store = SenderKeyPinStore(defaults: defaults)
        store.switchUser(me)
        store.adoptOtherSpellings()

        XCTAssertEqual(try store.getPinned(alice), Pin(signingPubHex: signA, sharingPubHex: shareA, pinnedAt: 50))
        XCTAssertEqual(try store.getPinned(bob)?.signingPubHex, signB)
        XCTAssertEqual(try pins("note_sender_pins.\(me)").map { Set($0.keys) }, [alice, bob])
        XCTAssertNil(defaults.data(forKey: "note_sender_pins.\(me.uppercased())"))
        XCTAssertNil(defaults.data(forKey: "note_sender_pins.{\(me)}"))
        XCTAssertEqual(try pins("note_sender_pins.\(other)")?[alice]?.signingPubHex, signB, "another account's are untouched")
    }

    func testDifferentKeysForOneSenderAcrossSpellingsAreAConflict() throws {
        try putPins("note_sender_pins.\(me.uppercased())", [alice: Pin(signingPubHex: signB, sharingPubHex: nil, pinnedAt: 100)])
        try putPins("note_sender_pins.\(me)", [alice: Pin(signingPubHex: signA, sharingPubHex: shareA, pinnedAt: 200)])
        let store = SenderKeyPinStore(defaults: defaults)
        store.switchUser(me)
        store.adoptOtherSpellings()
        let pin = try XCTUnwrap(store.getPinned(alice))
        XCTAssertEqual(pin.signingPubHex, SenderKeyPinStore.conflictKeyHex)
        XCTAssertEqual(try store.pin(ownerId: alice, signingPubHex: signA, sharingPubHex: shareA), .changedBoth)
    }

    func testABlobThatDoesNotDecodeMovesNothing() throws {
        defaults.set(Data("{not json".utf8), forKey: "note_sender_pins.\(me.uppercased())")
        try putPins("note_sender_pins.\(me)", [bob: Pin(signingPubHex: signB, sharingPubHex: nil, pinnedAt: 300)])
        let store = SenderKeyPinStore(defaults: defaults)
        store.switchUser(me)
        store.adoptOtherSpellings()
        XCTAssertEqual(defaults.data(forKey: "note_sender_pins.\(me.uppercased())"), Data("{not json".utf8))
        XCTAssertEqual(try pins("note_sender_pins.\(me)").map { Set($0.keys) }, [bob])
    }

    // MARK: - Floors

    func testFloorsUnderAnotherSpellingJoinByTheHighestGeneration() throws {
        defaults.set([item: NSNumber(value: 5)], forKey: "note_gen_floor.\(me)")
        defaults.set([item.uppercased(): NSNumber(value: 9)], forKey: "note_gen_floor.\(me.replacingOccurrences(of: "-", with: ""))")
        defaults.set([item: NSNumber(value: 1)], forKey: "note_gen_floor.\(other)")
        let store = NoteGenFloorStore(defaults: defaults)
        store.switchUser(me)
        store.adoptOtherSpellings()
        XCTAssertEqual(try store.floor(item), 9)
        XCTAssertNil(defaults.object(forKey: "note_gen_floor.\(me.replacingOccurrences(of: "-", with: ""))"))
        XCTAssertEqual((defaults.dictionary(forKey: "note_gen_floor.\(other)") as? [String: NSNumber])?[item], 1)
    }
}
