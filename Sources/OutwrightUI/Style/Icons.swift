// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightModel
import SwiftUI

/// SF Symbols for the app's things, in one place.
enum Icons {
    static func folder(_ kind: FolderKind) -> String {
        switch kind {
        case .inbox: "tray"
        case .sent: "paperplane"
        case .drafts: "pencil.line"
        case .trash: "trash"
        case .junk: "xmark.bin"
        case .archive: "archivebox"
        case .other: "folder"
        }
    }

    static let compose = "square.and.pencil"
    static let drafts = "pencil.line"
    static let search = "magnifyingglass"
    static let bell = "bell"
    static let filter = "line.3.horizontal.decrease"
    static let attachment = "paperclip"
    static let meeting = "calendar"
    static let flag = "flag.fill"
    static let delete = "trash"
    static let archive = "archivebox"
    static let junk = "nosign"
    static let unread = "envelope.badge"
    static let more = "ellipsis"
    static let reply = "arrowshape.turn.up.left"
    static let replyAll = "arrowshape.turn.up.left.2"
    static let forward = "arrowshape.turn.up.right"
    static let back = "chevron.left"
    static let fullWidth = "arrow.up.left.and.arrow.down.right"
    static let showList = "arrow.down.right.and.arrow.up.left"
    static let folded = "chevron.right"
    static let unfolded = "chevron.down"
    static let mail = "envelope"
    static let calendar = "calendar"
    static let contacts = "person.2"
    static let help = "questionmark.circle"
    static let settings = "gearshape"
    static let add = "plus"
    static let edit = "pencil"
    static let details = "info.circle"
    static let allAccounts = "tray.2"
    static let phone = "phone"
    static let message = "message"
    static let person = "person"
    static let close = "xmark"
    static let newEvent = "calendar.badge.plus"
    static let time = "clock"
    static let place = "mappin.and.ellipse"
    static let link = "link"
    static let organizer = "person.crop.circle"
    static let attendees = "person.2"
    static let reminder = "bell"
    static let repeats = "repeat"
    static let notes = "text.alignleft"

    static func calendarMode(_ mode: CalendarMode) -> String {
        switch mode {
        case .agenda: "list.bullet"
        case .day: "rectangle"
        case .threeDay: "rectangle.split.3x1"
        case .month: "calendar"
        }
    }

    static func weekMode(_ mode: WeekMode) -> String {
        switch mode {
        case .workWeek: "rectangle.split.3x1"
        case .week: "calendar.day.timeline.left"
        }
    }

    static func response(_ response: Attendee.Response) -> String {
        switch response {
        case .accepted: "checkmark.circle.fill"
        case .declined: "xmark.circle.fill"
        case .tentative: "questionmark.circle.fill"
        case .delegated: "arrow.right.circle.fill"
        case .needsAction: "circle.dashed"
        }
    }
}

/// The name a folder is shown with: system folders by their kind, in the interface's language.
enum FolderNames {
    static func name(_ folder: Folder) -> String {
        switch folder.kind {
        case .inbox: L10n.string("Inbox")
        case .sent: L10n.string("Sent")
        case .drafts: L10n.string("Drafts")
        case .trash: L10n.string("Deleted")
        case .junk: L10n.string("Junk")
        case .archive: L10n.string("Archive")
        case .other: folder.name
        }
    }
}
