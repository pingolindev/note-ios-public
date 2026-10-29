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

import WidgetKit
import SwiftUI

/// One-tap "new note" button. No data, no decryption, no network —
/// just deep-links into the host app's create-note sheet via the
/// `noteapp://create` URL scheme. Mirrors android's
/// QuickCaptureWidgetProvider.
struct QuickCaptureWidget: Widget {
    let kind: String = "QuickCaptureWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: QuickCaptureProvider()) { _ in
            QuickCaptureView()
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Quick Capture")
        .description("Tap to add a new note instantly.")
        .supportedFamilies([.systemSmall])
    }
}

struct QuickCaptureEntry: TimelineEntry {
    let date: Date
}

struct QuickCaptureProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuickCaptureEntry {
        QuickCaptureEntry(date: Date())
    }
    func getSnapshot(in context: Context, completion: @escaping (QuickCaptureEntry) -> Void) {
        completion(QuickCaptureEntry(date: Date()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<QuickCaptureEntry>) -> Void) {
        // Static — no reason to refresh. iOS will re-request on its
        // own schedule when the widget surfaces.
        completion(Timeline(entries: [QuickCaptureEntry(date: Date())], policy: .never))
    }
}

struct QuickCaptureView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(Color.brandAccent)
            Text("New Note")
                .font(.headline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // widgetURL, not Link. WidgetKit gives systemSmall exactly ONE tap
        // target and it is set with widgetURL; Link is supported only in
        // systemMedium and systemLarge. This widget ships in systemSmall
        // ONLY (see supportedFamilies above), so a Link would be inert and a
        // tap would just launch the app to wherever it happened to be — while
        // the widget's own description promises "Tap to add a new note
        // instantly." This is the whole function of the widget.
        .widgetURL(URL(string: "noteapp://create"))
    }
}
