// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI

/// Initials on a colour derived from the address, the same on every launch and device.
struct Avatar: View {
    var name: String?
    var email: String
    var size: CGFloat = 40
    /// An account's own colour, when the avatar stands for an account.
    var colorIndex: Int?

    var body: some View {
        Circle()
            .fill(Theme.avatarColor(colorIndex ?? Self.colorIndex(for: email)))
            .frame(width: size, height: size)
            .overlay {
                Text(Self.initials(name: name, email: email))
                    .font(.system(size: size * 0.38, weight: .regular))
                    .foregroundStyle(Theme.onSwatch)
            }
            .accessibilityHidden(true)
    }

    /// FNV-1a over the lower-case address: stable, unlike `hashValue`.
    static func colorIndex(for email: String) -> Int {
        var hash: UInt32 = 2_166_136_261
        for byte in email.lowercased().utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return Int(hash % UInt32(Theme.avatarColors.count))
    }

    /// Up to two letters: first and last word of the name, else the address's first letter.
    static func initials(name: String?, email: String) -> String {
        let words = (name ?? "")
            .split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "(" || $0 == ")" })
            .filter { $0.first?.isLetter == true }
        if let first = words.first?.first {
            if words.count > 1, let last = words.last?.first {
                return String([first, last]).uppercased()
            }
            return String(first).uppercased()
        }
        return email.first.map { String($0).uppercased() } ?? "?"
    }
}
