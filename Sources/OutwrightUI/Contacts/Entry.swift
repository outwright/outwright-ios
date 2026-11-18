// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// What a field takes, for the keyboard.
enum Entry {
    case phone, email

    /// What a row of this kind is, shown where it has no label.
    var name: String {
        switch self {
        case .phone: L10n.string("Phone")
        case .email: L10n.string("Email")
        }
    }
}
