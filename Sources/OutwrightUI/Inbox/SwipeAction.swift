// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI

/// What a swipe on a mail row does: one of the six, chosen per edge in Settings.
public enum SwipeAction: String, CaseIterable, Sendable {
    case delete, archive, flag, read, move, none

    /// What a swipe from the left edge does until the owner chooses (Flag), and from the right (Delete).
    public static let leadingDefault = SwipeAction.flag
    public static let trailingDefault = SwipeAction.delete

    /// The name in Settings' pickers.
    var title: LocalizedStringKey {
        switch self {
        case .delete: "Delete"
        case .archive: "Archive"
        case .flag: "Flag"
        case .read: "Mark as read"
        case .move: "Move"
        case .none: "None"
        }
    }

    /// What the swipe does, to finish Help's "Swipe left on a message to …".
    var helpPhrase: String {
        switch self {
        case .delete: L10n.string("delete it")
        case .archive: L10n.string("archive it")
        case .flag: L10n.string("flag or unflag it")
        case .read: L10n.string("mark it read or unread")
        case .move: L10n.string("move it to another folder")
        case .none: ""
        }
    }

    /// The symbol it is shown with.
    var icon: String {
        switch self {
        case .delete: Icons.delete
        case .archive: Icons.archive
        case .flag: Icons.flagOutline
        case .read: Icons.markRead
        case .move: Icons.move
        case .none: Icons.close
        }
    }
}

/// The edge of a row a swipe starts from.
public enum SwipeEdge: Sendable {
    case leading, trailing
}
