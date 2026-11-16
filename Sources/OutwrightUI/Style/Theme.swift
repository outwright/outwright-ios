// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The app's colours. Light and dark are given together; nothing else picks a colour.
enum Theme {
    /// The header of the mail list and of search: neutral, so mail stays the focus.
    static let header = adaptive(light: 0xF7F3EF, dark: 0x1C1B1A)
    /// Text and icons on the header.
    static let headerText = adaptive(light: 0x2A2420, dark: 0xF3EEEA)
    /// The pill of the header's segmented control and the search field.
    static let headerTrack = adaptive(light: 0xEBE4DE, dark: 0x2F2C2A)
    /// Terracotta, as the app icon: unread dot, links, chosen folder, the chosen side of a pill.
    static let accent = adaptive(light: 0xB5472A, dark: 0xF08A65)
    /// Text and icons on the accent.
    static let onAccent = adaptive(light: 0xFFFFFF, dark: 0x1C1B1A)
    /// The badge behind a chosen folder's unread count.
    static let accentSoft = adaptive(light: 0xF8E4DB, dark: 0x40261D)
    static let flag = Color(hex: 0xE8B400)
    static let delete = Color(hex: 0xD13438)
    static let secondaryText = Color.secondary
    /// The row whose message is open beside the list.
    static let selectedRow = adaptive(light: 0xEFE9E4, dark: 0x2A2826)
    static let separator = adaptive(light: 0xE8E2DD, dark: 0x2E2C2A)
    static let background = adaptive(light: 0xFDFBF9, dark: 0x161514)
    static let drawerBackground = adaptive(light: 0xF6F2EE, dark: 0x1E1C1B)

    /// Eight avatar colours, readable with white initials in light and dark.
    static let avatarColors: [Color] = [
        Color(hex: 0x4CAF6A), Color(hex: 0xD9659E), Color(hex: 0xE2B93B), Color(hex: 0x4A8FD8),
        Color(hex: 0x8C6BC8), Color(hex: 0xE07B39), Color(hex: 0x2BA3A3), Color(hex: 0x8A8F98)
    ]

    static func avatarColor(_ index: Int) -> Color {
        let count = avatarColors.count
        return avatarColors[((index % count) + count) % count]
    }

    static func adaptive(light: UInt32, dark: UInt32) -> Color {
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
