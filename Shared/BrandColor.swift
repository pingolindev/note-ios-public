// Auto-generated from the design tokens — do not edit manually.
// App: note
//
// Defined here rather than only in the asset catalog because
// ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME is set on the APP target
// only, and the app's Assets.xcassets is not in the widget or share-extension
// sources — so those targets cannot resolve Color.accentColor to anything of
// ours. That is why widgets reach for a semantic .blue and the home screen
// stops looking like the app. Put this file in a group all targets compile.
import SwiftUI
import UIKit

extension Color {

    /// Fill for a control carrying a **white** label. FIXED, not adaptive.
    ///
    /// #5d49d6 under white is 6.20:1, clear of the
    /// 4.5:1 body-text minimum — and it must be ONE value precisely because the
    /// label is white in both appearances. The adaptive value below would put
    /// white on #a08aff at 2.77:1, which fails badly.
    static let brandAccentFill = Color(uiColor: UIColor(
        red: 0.364706, green: 0.286274, blue: 0.839216, alpha: 1))

    /// Tint for a glyph or label drawn **on the background**, so it adapts.
    /// Never use this as a fill under white text — see above.
    static let brandAccent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.627451, green: 0.541176, blue: 1.000000, alpha: 1)
            : UIColor(red: 0.364706, green: 0.286274, blue: 0.839216, alpha: 1)
    })

    /// Semantic INK — the fills are too light to be text.
    static let brandSuccessText = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.203922, green: 0.827451, blue: 0.600000, alpha: 1)
            : UIColor(red: 0.039216, green: 0.431373, blue: 0.317647, alpha: 1)
    })

    static let brandErrorText = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.972549, green: 0.443137, blue: 0.443137, alpha: 1)
            : UIColor(red: 0.717647, green: 0.109804, blue: 0.109804, alpha: 1)
    })
}
