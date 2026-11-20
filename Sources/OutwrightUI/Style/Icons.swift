// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import OutwrightModel
import SwiftUI

/// SF Symbols for the app's things, in one place.
public enum Icons {
    public static func folder(_ kind: FolderKind) -> String {
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

    public static let compose = "square.and.pencil"
    /// The setup file: backing it up, moving it to another device, restoring it, copying its passphrase.
    public static let backUp = "arrow.up.doc"
    public static let moveDevice = "iphone.and.arrow.forward"
    public static let restore = "arrow.down.doc"
    /// Moving the setup without a file: the code the receiving device shows, sending it as a file instead,
    /// and the code hidden while the app is not in front.
    public static let bringSetup = "qrcode"
    public static let sendAsFile = backUp
    public static let codeHidden = "eye.slash"
    public static let copy = "doc.on.doc"
    public static let share = "square.and.arrow.up"
    public static let drafts = "pencil.line"
    public static let search = "magnifyingglass"
    public static let bell = "bell"
    public static let filter = "line.3.horizontal.decrease"
    public static let attachment = "paperclip"
    public static let meeting = "calendar"
    public static let flag = "flag.fill"
    public static let delete = "trash"
    public static let archive = "archivebox"
    public static let junk = "nosign"
    public static let unread = "envelope.badge"
    public static let more = "ellipsis"
    public static let reply = "arrowshape.turn.up.left"
    public static let replyAll = "arrowshape.turn.up.left.2"
    public static let forward = "arrowshape.turn.up.right"
    public static let back = "chevron.left"
    public static let fullWidth = "arrow.up.left.and.arrow.down.right"
    public static let showList = "arrow.down.right.and.arrow.up.left"
    public static let folded = "chevron.right"
    public static let unfolded = "chevron.down"
    public static let mail = "envelope"
    public static let personAdd = "person.badge.plus"
    public static let doNotDisturb = "bell.slash"
    public static let warning = "exclamationmark.triangle"
    public static let warningFilled = "exclamationmark.triangle.fill"
    public static let confirm = "checkmark"
    /// A step that went through (the account was added).
    public static let succeeded = "checkmark.circle.fill"
    public static let checkboxOn = "checkmark.square.fill"
    public static let checkboxOff = "square"
    public static let send = "paperplane"
    public static let format = "textformat"
    public static let bold = "bold"
    public static let italic = "italic"
    public static let underline = "underline"
    public static let bulletList = "list.bullet"
    public static let numberedList = "list.number"
    public static let mailFilled = "envelope.fill"
    public static let flagOutline = "flag"
    public static let unflag = "flag.slash"
    public static let move = "folder"
    public static let undo = "arrow.uturn.backward"
    public static let markRead = "envelope.open"
    public static let selectAll = "checklist"
    public static let rowSelected = "checkmark.circle.fill"
    public static let rowUnselected = "circle"
    public static let moveToOther = "arrow.right.square"
    public static let moveToFocused = "arrow.left.square"
    public static let focused = "tray"
    public static let recent = "clock.arrow.circlepath"
    public static let filterActive = "line.3.horizontal.decrease.circle.fill"
    public static let clear = "xmark.circle.fill"
    public static let remove = "minus.circle.fill"
    public static let locked = "lock.fill"
    public static let unlocked = "lock.open"
    public static let signed = "signature"
    public static let picture = "photo"
    public static let camera = "camera"
    public static let picturesBlocked = "photo.badge.exclamationmark"
    public static let timeZone = "globe"
    public static let document = "doc"
    public static let personCard = "person.text.rectangle"
    public static let eventCancelled = "calendar.badge.minus"
    public static let unsure = "questionmark"
    public static let noAnswer = "circle"
    public static let published = "checkmark.circle"
    public static let verified = "checkmark.seal"
    public static let calendar = "calendar"
    public static let contacts = "person.2"
    public static let help = "questionmark.circle"
    public static let settings = "gearshape"
    public static let add = "plus"
    public static let newFolder = "folder.badge.plus"
    public static let edit = "pencil"
    public static let details = "info.circle"
    public static let lightBackground = "sun.max"
    public static let darkBackground = "moon"
    public static let allAccounts = "tray.2"
    public static let phone = "phone"
    public static let message = "message"
    public static let person = "person"
    public static let close = "xmark"
    public static let newEvent = "calendar.badge.plus"
    public static let time = "clock"
    public static let place = "mappin.and.ellipse"
    public static let link = "link"
    public static let organizer = "person.crop.circle"
    public static let attendees = "person.2"
    public static let reminder = "bell"
    public static let repeats = "repeat"
    public static let notes = "text.alignleft"
    /// Show as: how the event shows the owner's time.
    public static let showAs = "circle.lefthalf.filled"
    /// A private event.
    public static let privateEvent = "lock"
    /// Join a meeting.
    public static let join = "video.fill"
    /// Email attendees.
    public static let emailPeople = "envelope"
    /// A calendar's colour.
    public static let color = "paintpalette"
    /// One colour to choose.
    public static let colorDot = "circle.fill"

    public static func calendarMode(_ mode: CalendarMode) -> String {
        switch mode {
        case .agenda: "list.bullet"
        case .day: "rectangle"
        case .threeDay: "rectangle.split.3x1"
        case .month: "calendar"
        case .week: weekMode(.week)
        case .workWeek: weekMode(.workWeek)
        }
    }

    public static let previousMonth = "chevron.left"
    public static let nextMonth = "chevron.right"

    /// The month above the calendar's days is closed, or open.
    public static func miniMonth(open: Bool) -> String { open ? "chevron.up" : "chevron.down" }

    public static func weekMode(_ mode: WeekMode) -> String {
        switch mode {
        case .workWeek: "rectangle.split.3x1"
        case .week: "calendar.day.timeline.left"
        }
    }

    public static func response(_ response: Attendee.Response) -> String {
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
    public static func name(_ folder: Folder) -> String {
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
