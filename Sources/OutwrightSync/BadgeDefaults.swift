// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// Whether the app icon counts only Focused mail, kept in the app group's shared defaults so the
/// notification extension counts as the app does (Focused Inbox is a setting of the app's own).
public enum BadgeDefaults {
    static let focusedOnlyKey = "badge.focusedOnly"

    public static var focusedOnly: Bool {
        DoNotDisturbDefaults.shared.object(forKey: focusedOnlyKey) as? Bool ?? true
    }

    static func setFocusedOnly(_ value: Bool) {
        DoNotDisturbDefaults.shared.set(value, forKey: focusedOnlyKey)
    }
}
