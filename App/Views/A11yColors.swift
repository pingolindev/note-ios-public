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

/// WCAG-AA color tints for the login screen (mirrored between note-ios and
/// track-ios — keep the two copies identical).
///
/// Why these exist: `performAccessibilityAudit()` fails the STOCK palette.
/// The system accent puts a white label on #007AFF — 4.02:1, under the 4.5:1
/// minimum for body-size text — and `.secondary` text lands at ~3.4:1 on the
/// light background ("nearly passed"). Ratios below were computed against the
/// WCAG relative-luminance formula; every value keeps a margin over 4.5:1.
extension Color {
    /// Button accent carrying a WHITE label: the BRAND purple. #5D49D6 is
    /// 6.20:1 vs white in both appearances, so a blue (#0A5DC2, 6.25:1) is not
    /// needed for accessibility and the app can look like itself. One fixed
    /// value: the label is white on the accent either way. See
    /// `Color.brandAccentFill`.
    ///
    /// NOTE: this file is otherwise byte-identical with the Track iOS app's
    /// copy and the header above says to keep the two identical. This value
    /// DIVERGES deliberately — Note's brand purple is not Track's; what the
    /// two files share is the *technique*, not the hex.
    static let a11yAccent = Color.brandAccentFill

    /// Link/tinted-text color ON the screen background, so it adapts:
    /// #0A5DC2 on white = 6.25:1; #5CA8FF on black = 8.5:1.
    static let a11yLink = Color(uiColor: UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 0x5C / 255, green: 0xA8 / 255, blue: 0xFF / 255, alpha: 1)
            : UIColor(red: 0x0A / 255, green: 0x5D / 255, blue: 0xC2 / 255, alpha: 1)
    })

    /// Replacement for `.secondary` where the audit measures it: reads the
    /// same, passes — #6E6E73 on white = 5.07:1; #98989D on black = 7.31:1.
    static let a11ySecondaryText = Color(uiColor: UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 0x98 / 255, green: 0x98 / 255, blue: 0x9D / 255, alpha: 1)
            : UIColor(red: 0x6E / 255, green: 0x6E / 255, blue: 0x73 / 255, alpha: 1)
    })
}

extension Color {
    /// Error text. The stock `.red` (systemRed #FF3B30) is **3.55:1** on
    /// white, under the 4.5:1 that 12-13pt text needs — too faint for the
    /// text that matters most: every error message in the app, a failed
    /// biometric enrol, a rejected sign-in, a failed purchase.
    ///
    /// The value comes from the theme generator (`Shared/BrandColor.swift`),
    /// not from here: #B71C1C on white is **6.57:1** and
    /// #F87171 on black **7.59:1**. This alias exists only so the call
    /// sites keep reading `a11yError`, which says what it is FOR.
    static let a11yError = Color.brandErrorText

    /// The affirmative counterpart. Stock `.green` (systemGreen #34C759) is
    /// **2.22:1** on white — under even the 3:1 a meaningful graphic needs.
    ///
    /// The value comes from the generator (`Shared/BrandColor.swift`):
    /// #0A6E51 on white is **6.25:1** and #34D399 on black **10.92:1** — and
    /// 8.85:1 on the dark grouped-form cell this actually sits on. It is the
    /// same green the web already uses, so the colour is defined once.
    static let a11ySuccess = Color.brandSuccessText

    /// Disabled prominent-button fill: #6E6E73 keeps the WHITE label at
    /// 5.07:1 while still reading as "grayed out". The system's own
    /// disabled rendering (gray-on-gray) fails the contrast check, and
    /// `.tint` cannot reach it.
    static let a11yDisabledFill = Color(uiColor: UIColor(
        red: 0x6E / 255, green: 0x6E / 255, blue: 0x73 / 255, alpha: 1))
}

/// `.borderedProminent` look with contrast we control in EVERY state —
/// including disabled, which the system style renders gray-on-gray at
/// ~1.8:1 and which `performAccessibilityAudit` rightly fails.
struct A11yProminentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isEnabled ? Color.a11yAccent : Color.a11yDisabledFill)
            )
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}
