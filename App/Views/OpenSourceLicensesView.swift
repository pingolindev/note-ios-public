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
import UIKit

/// Settings → About → Open Source Licenses.
///
/// Two obligations meet on this screen. The app is GPL software, so it says so
/// and says where the source of every release is published. And most of the
/// components it links require their copyright notices to ship with the binary
/// rather than sit on a website: Swift-Sodium and libsodium, GRDB and SQLCipher, and
/// the Rust crates inside the SDK framework. So both inventories are bundled and
/// shown from the bundle, offline.
struct OpenSourceLicensesView: View {
    static let sourceCode = URL(string: "https://github.com/pingolindev/note-ios-public")!
    /// The editor this app loads is published separately, under the GPL too.
    static let editorSourceCode = URL(string: "https://github.com/pingolindev/note-web-public")!

    /// The bundled inventories, in the order shown. A unit test fails the build
    /// that forgets one, instead of a user meeting an empty page.
    static let inventories: [(title: String, resource: String)] = [
        ("This App's Components", "THIRD_PARTY_LICENSES"),
        ("SDK Components", "THIRD_PARTY_LICENSES-mobile-sdk"),
    ]

    static func bundledText(_ resource: String, in bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: resource, withExtension: "md") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    var body: some View {
        List {
            Section {
                Text("Pingolin Note is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.")
                Link(destination: Self.sourceCode) {
                    Label("Source Code", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Link(destination: Self.editorSourceCode) {
                    Label("Editor Source Code",
                          systemImage: "chevron.left.forwardslash.chevron.right")
                }
            }
            Section("Third-Party Components") {
                ForEach(Self.inventories, id: \.resource) { inventory in
                    NavigationLink(inventory.title) {
                        LicenseTextView(text: Self.bundledText(inventory.resource)
                                        ?? "This document is missing from the app bundle.")
                            .navigationTitle(inventory.title)
                            .navigationBarTitleDisplayMode(.inline)
                    }
                }
            }
        }
        .navigationTitle("Open Source Licenses")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A long read-only document. A UITextView rather than a SwiftUI Text: the SDK's
/// inventory is about 300 KB, which a Text would lay out in one pass on the main
/// thread as the screen is pushed.
struct LicenseTextView: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.font = .preferredFont(forTextStyle: .footnote)
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        view.text = text
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
    }
}
