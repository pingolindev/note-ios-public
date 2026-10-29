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

import UIKit
import Social
import UniformTypeIdentifiers
import SwiftUI

/// Receives text or URLs shared from other apps and hands them off to
/// the main Note app via the App Group. The extension itself doesn't
/// touch the keychain or hit the network — the main app picks the
/// draft up on next launch and saves it through the regular encrypted
/// note pipeline.
///
/// Mirrors the spirit of the Android app's QuickCapture flow: a small,
/// platform-native entry point for "stash this somewhere I'll deal
/// with later," without dragging the full crypto stack into a
/// short-lived extension process.
///
/// `ShareDraft` is what the prompt is editing, so the UI can appear
/// before extraction finishes and fill in afterwards. Deliberately
/// not `@MainActor`-annotated. Everything that touches it is already
/// main-isolated — `viewDidLoad` and a `Task` that inherits the
/// UIViewController's actor — so the annotation would add an
/// isolation boundary the SwiftUI view would then have to cross for
/// no benefit.
final class ShareDraft: ObservableObject {
    @Published var title = ""
    @Published var noteBody = ""
    /// True until `extractInputs` has finished. The fields are disabled and a
    /// spinner shows, rather than the whole sheet being absent.
    @Published var loading = true
}

@objc(ShareViewController)
final class ShareViewController: UIViewController {
    private let draft = ShareDraft()
    private var hosting: UIHostingController<SharePromptView>?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        // Present first, extract second. `extractInputs` awaits every
        // provider, for however long the source app takes to hand
        // over its item; presenting only after it would leave a bare
        // systemBackground rectangle on screen meanwhile — no title,
        // no spinner, no Cancel, and so nothing to cancel.
        presentPromptUI()
        Task {
            await extractInputs()
            draft.loading = false
        }
    }

    private func extractInputs() async {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else { return }
        var text = ""
        var url: URL?
        var suppliedTitle = ""
        for item in items {
            // The sharing app's own title for what it is sharing — a page
            // title from Safari, a subject from Mail. This is the direct iOS
            // counterpart of the EXTRA_SUBJECT that note-android reads.
            if suppliedTitle.isEmpty, let attributed = item.attributedTitle?.string {
                suppliedTitle = attributed.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard let providers = item.attachments else { continue }
            for provider in providers {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let loaded = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) {
                    if let u = loaded as? URL {
                        url = url ?? u
                    } else if let s = loaded as? String, let u = URL(string: s) {
                        url = url ?? u
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                          let loaded = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier),
                          let s = loaded as? String {
                    if text.isEmpty { text = s }
                }
            }
            if text.isEmpty, let raw = item.attributedContentText?.string {
                text = raw
            }
        }

        draft.noteBody = text.isEmpty ? (url?.absoluteString ?? "") : text
        draft.title = Self.title(supplied: suppliedTitle, url: url, body: text)
    }

    /// Best available title, in order of how much it is actually worth.
    ///
    /// Not a raw 60-character slice of the body: newlines included,
    /// sharing a couple of paragraphs would prefill a single-line field
    /// with a mid-word fragment that repeats the opening of the body
    /// immediately below it. That has to be cleared by hand, and a share
    /// extension's whole value is being quicker than opening the app.
    ///
    /// An empty result is fine: `canSave` already allows a body-only save.
    static func title(supplied: String, url: URL?, body: String) -> String {
        if !supplied.isEmpty { return String(supplied.prefix(60)) }
        if body.isEmpty, let url { return url.host ?? "Link" }

        // First line only, and only if it reads like a heading rather than the
        // start of a paragraph.
        let firstLine = body
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        if firstLine.isEmpty { return "" }
        if firstLine.count <= 60 { return firstLine }

        // Too long: cut at the last word boundary inside 60 rather than
        // mid-word. If there is no space to cut at, leave it empty rather than
        // inventing a fragment.
        let capped = firstLine.prefix(60)
        guard let lastSpace = capped.lastIndex(of: " ") else { return "" }
        let trimmed = capped[..<lastSpace].trimmingCharacters(in: .whitespaces)
        return trimmed.count >= 12 ? trimmed : ""
    }

    private func presentPromptUI() {
        let view = SharePromptView(
            draft: draft,
            onSave: { [weak self] title, body in
                let draft = PendingShareDraft(title: title, body: body)
                SharedAppGroup.setPendingDraft(draft)
                self?.complete()
            },
            onCancel: { [weak self] in self?.cancel() }
        )
        let host = UIHostingController(rootView: view)
        addChild(host)
        host.view.frame = self.view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        self.view.addSubview(host.view)
        host.didMove(toParent: self)
        self.hosting = host
    }

    private func complete() {
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func cancel() {
        let err = NSError(domain: "NoteShareExt", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: "User cancelled"])
        extensionContext?.cancelRequest(withError: err)
    }
}

struct SharePromptView: View {
    @ObservedObject var draft: ShareDraft
    let onSave: (String, String) -> Void
    let onCancel: () -> Void

    var canSave: Bool {
        guard !draft.loading else { return false }
        return !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !draft.noteBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("Title", text: $draft.title)
                        .disabled(draft.loading)
                        .accessibilityIdentifier("share-ext-title")
                }
                Section("Body") {
                    TextEditor(text: $draft.noteBody)
                        .frame(minHeight: 140)
                        .disabled(draft.loading)
                        .accessibilityIdentifier("share-ext-body")
                }
                if draft.loading {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Reading what you shared…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityIdentifier("share-ext-loading")
                    }
                }
                Section {
                    Text("This will appear in Note as a draft. Open the app to save it to the encrypted vault.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Save to Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // Available from the first frame, so a slow or stuck
                    // provider can be abandoned instead of sat through.
                    Button("Cancel") { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(draft.title, draft.noteBody) }
                        .disabled(!canSave)
                        .accessibilityIdentifier("share-ext-save")
                }
            }
        }
    }
}
