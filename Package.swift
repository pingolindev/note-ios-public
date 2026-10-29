// swift-tools-version: 5.9
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

import PackageDescription

// PingolinNoteSDK is a single Swift target wrapping BOTH UniFFI crates
// from mobile-sdk:
//
//   - pingolin_mobile  (mobile-sdk/crates/mobile-sdk)       — auth, SRP,
//        circle crypto, signing keypair, base CryptoManager.
//   - note_collab_sdk  (mobile-sdk/crates/note-collab-sdk)  — Yjs CRDT,
//        per-note content keys, sealed-box recipient wrapping, and the
//        wrap-signature primitives (signNoteShareWrap +
//        verifyNoteShareWrap + generateNoteSigningKeypair).
//
// build-ios.sh libtools the two static archives together and emits a
// single PingolinFFI.xcframework with a merged modulemap declaring
// both `pingolin_mobileFFI` and `collabFFI` C modules. SPM (and more
// specifically xcodebuild merging xcframeworks through an xcodegen-
// generated project) doesn't tolerate two binaryTargets each shipping
// their own Headers/module.modulemap — they collide on the shared
// include/module.modulemap output path. Combining sidesteps that
// entirely.
//
// Both generated Swift bindings (pingolin_mobile.swift + collab.swift)
// live inside the same Swift target so callers just `import
// PingolinNoteSDK` and have access to everything.
let package = Package(
    name: "PingolinNoteSDK",
    platforms: [
        .iOS(.v17),
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "PingolinNoteSDK",
            targets: ["PingolinNoteSDK"]),
    ],
    targets: [
        .target(
            name: "PingolinNoteSDK",
            dependencies: ["PingolinFFI"],
            path: "Sources/PingolinNoteSDK",
            // Shipped by the app as a resource (Open Source Licenses), not by
            // this package.
            exclude: ["THIRD_PARTY_LICENSES-mobile-sdk.md"]
        ),
        .binaryTarget(
            name: "PingolinFFI",
            path: "lib/PingolinFFI.xcframework"
        ),
    ]
)
