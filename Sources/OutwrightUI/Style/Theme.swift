// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The app's colours. Light and dark are given together; nothing else picks a colour.
public enum Theme {
    /// The header of the mail list and of search: neutral, so mail stays the focus.
    public static let header = adaptive(light: 0xF7F3EF, dark: 0x1C1B1A)
    /// Text and icons on the header.
    public static let headerText = adaptive(light: 0x2A2420, dark: 0xF3EEEA)
    /// The pill of the header's segmented control and the search field.
    public static let headerTrack = adaptive(light: 0xEBE4DE, dark: 0x2F2C2A)
    /// Terracotta, as the app icon: unread dot, links, chosen folder, the chosen side of a pill.
    public static let accent = adaptive(light: 0xB5472A, dark: 0xF08A65)
    /// Text and icons on the accent.
    public static let onAccent = adaptive(light: 0xFFFFFF, dark: 0x1C1B1A)
    /// The badge behind a chosen folder's unread count.
    public static let accentSoft = adaptive(light: 0xF8E4DB, dark: 0x40261D)
    public static let flag = Color(hex: 0xE8B400)
    public static let delete = Color(hex: 0xD13438)
    /// The swipes' own colours: Archive, Move and Mark as read.
    public static let archive = Color(hex: 0x2E7D4F)
    public static let move = Color(hex: 0x6B5BB8)
    public static let read = Color(hex: 0x2F6DB5)
    public static let secondaryText = Color.secondary
    /// Something that needs the owner's attention but is not a failure: a key not yet published, a conflict.
    public static let warning = adaptive(light: 0xB95C00, dark: 0xF2A04A)
    /// Something that went well: a verified key.
    public static let success = adaptive(light: 0x1E7D3A, dark: 0x5CC27C)
    /// Text and marks on a calendar or avatar swatch, which is the same mid-tone in light and dark.
    public static let onSwatch = Color(hex: 0xFFFFFF)
    /// The dimming behind a modal layer.
    public static let scrim = Color(hex: 0x000000).opacity(0.35)
    /// The corner radius of every card, banner and field.
    public static let cardRadius: CGFloat = 14
    /// The row whose message is open beside the list.
    public static let selectedRow = adaptive(light: 0xEFE9E4, dark: 0x2A2826)
    public static let separator = adaptive(light: 0xE8E2DD, dark: 0x2E2C2A)
    public static let background = adaptive(light: 0xFDFBF9, dark: 0x161514)
    public static let drawerBackground = adaptive(light: 0xF6F2EE, dark: 0x1E1C1B)
    /// A row of a grouped list (Settings), as the system draws it.
    public static var groupedRow: Color {
        #if canImport(UIKit)
        Color(uiColor: .secondarySystemGroupedBackground)
        #elseif canImport(AppKit)
        Color(nsColor: .controlBackgroundColor)
        #endif
    }

    /// Eight avatar colours, readable with white initials in light and dark.
    public static let avatarColors: [Color] = [
        Color(hex: 0x4CAF6A), Color(hex: 0xD9659E), Color(hex: 0xE2B93B), Color(hex: 0x4A8FD8),
        Color(hex: 0x8C6BC8), Color(hex: 0xE07B39), Color(hex: 0x2BA3A3), Color(hex: 0x8A8F98)
    ]

    public static func avatarColor(_ index: Int) -> Color {
        let count = avatarColors.count
        return avatarColors[((index % count) + count) % count]
    }

    public static func adaptive(light: UInt32, dark: UInt32) -> Color {
        #if canImport(UIKit)
        Color(uiColor: UIColor { traits in
            UIColor(Color(hex: traits.userInterfaceStyle == .dark ? dark : light))
        })
        #elseif canImport(AppKit)
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(Color(hex: isDark ? dark : light))
        })
        #else
        Color(hex: light)
        #endif
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }
}

/// How many colours an account can be given (`Account.placed(after:colors:)`).
public enum AccountColors {
    public static var count: Int { Theme.avatarColors.count }
}
