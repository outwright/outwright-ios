// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI

/// Which layout a window gets, by the room it has, never by the device.
enum WideLayout: Equatable, Sendable {
    /// Compact width: one column, the tab bar and the drawer (a phone held upright, a narrow iPad window).
    case column
    /// Regular width, compact height: list and reading pane, the drawer and the tab capsule (a wide
    /// phone on its side).
    case panes
    /// Regular width and height: the tab rail, a sidebar, the list and the reading pane (an iPad).
    case sidebar

    static func of(width: UserInterfaceSizeClass?, height: UserInterfaceSizeClass?) -> WideLayout {
        guard width == .regular else { return .column }
        return height == .regular ? .sidebar : .panes
    }

    /// More than one column.
    var isWide: Bool { self != .column }
}

/// Which columns of the split view show: the sidebar by the window's width unless the owner chose,
/// and the reading pane alone while expanded.
struct SidebarState: Equatable {
    /// From this width the sidebar stands beside the list; below it, it comes over the list on demand.
    static let pinnedMinimumWidth: CGFloat = 1100

    /// The owner showed (true) or hid (false) the sidebar by hand; nil follows the width.
    var choice: Bool?
    /// The reading pane has the whole width (the expand button).
    var isExpanded = false

    /// `expands`: the tab is Mail's, whose expand button gives the message the width; Contacts keeps
    /// its list whatever Mail does.
    func visibility(_ layout: WideLayout, width: CGFloat, expands: Bool = true) -> NavigationSplitViewVisibility {
        if expands, isExpanded { return .detailOnly }
        guard layout == .sidebar else { return .doubleColumn }
        return showsSidebar(width) ? .all : .doubleColumn
    }

    /// The same for a tab of two columns (the sidebar and the calendar), where `.doubleColumn` would
    /// mean both: the sidebar shows where three columns would show it, and a message's expansion in
    /// Mail is no concern of it.
    func twoColumnVisibility(_ layout: WideLayout, width: CGFloat) -> NavigationSplitViewVisibility {
        guard layout == .sidebar else { return .detailOnly }
        return showsSidebar(width) ? .all : .detailOnly
    }

    /// The split view's own controls (a swipe, a tap beside a sidebar over the list) set the columns.
    /// What the width would show anyway is no choice: a sidebar dismissed in portrait comes back in
    /// landscape.
    mutating func apply(
        _ visibility: NavigationSplitViewVisibility, layout: WideLayout, width: CGFloat, expands: Bool = true
    ) {
        guard layout == .sidebar else { return }
        switch visibility {
        case .detailOnly:
            if expands { isExpanded = true } else { chose(sidebar: false, width: width) }
        case .doubleColumn:
            if expands { isExpanded = false }
            chose(sidebar: false, width: width)
        default:
            if expands { isExpanded = false }
            chose(sidebar: true, width: width)
        }
    }

    /// The two-column split view's own controls set the sidebar.
    mutating func applyTwoColumn(_ visibility: NavigationSplitViewVisibility, width: CGFloat) {
        chose(sidebar: visibility != .detailOnly, width: width)
    }

    private func showsSidebar(_ width: CGFloat) -> Bool { choice ?? Self.pinned(width) }

    private static func pinned(_ width: CGFloat) -> Bool { width >= pinnedMinimumWidth }

    private mutating func chose(sidebar shown: Bool, width: CGFloat) {
        choice = shown == Self.pinned(width) ? nil : shown
    }

    /// The avatar in a tab's header: the sidebar comes when it is hidden (and with it the list, after
    /// the expand button), and goes when it shows. `twoColumns`: the tab is the calendar's.
    mutating func toggle(_ layout: WideLayout, width: CGFloat, twoColumns: Bool = false) {
        if twoColumns {
            choice = twoColumnVisibility(layout, width: width) != .all
            return
        }
        let shown = visibility(layout, width: width) == .all
        isExpanded = false
        choice = !shown
    }

    /// A folder was chosen in the sidebar: a sidebar over the list closes, a pinned one stays.
    mutating func folderChosen(width: CGFloat) {
        if width < Self.pinnedMinimumWidth { choice = nil }
    }

    /// The window changed size class: the hand choice and the expansion belong to the old one.
    mutating func layoutChanged() {
        choice = nil
        isExpanded = false
    }
}
