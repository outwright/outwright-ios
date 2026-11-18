// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightStore
import SwiftUI

/// Filter: all mail, unread, flagged or with attachments; and Mark all read for the folder in view.
struct FilterMenu: View {
    @Binding var filter: InboxFilter
    var markAllRead: () -> Void = {}

    var body: some View {
        Menu {
            Picker(selection: $filter) {
                ModuleLabel("All", systemImage: Icons.mail).tag(InboxFilter.all)
                ModuleLabel("Unread", systemImage: Icons.unread).tag(InboxFilter.unread)
                ModuleLabel("Flagged", systemImage: Icons.flagOutline).tag(InboxFilter.flagged)
                ModuleLabel("Has attachments", systemImage: Icons.attachment).tag(InboxFilter.attachments)
            } label: {
                Text(ui: "Filter")
            }
            Divider()
            Button(action: markAllRead) {
                ModuleLabel("Mark all as read", systemImage: Icons.markRead)
            }
            .accessibilityIdentifier("inbox.markAllRead")
        } label: {
            // An active filter names itself, so a list it narrows is never mistaken for missing mail.
            HStack(spacing: 6) {
                Image(systemName: filter == .all ? Icons.filter : Icons.filterActive)
                Text(ui: Self.title(filter))
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(filter == .all ? Theme.headerText : Theme.accent)
            .padding(.horizontal, filter == .all ? 0 : 10)
            .padding(.vertical, filter == .all ? 0 : 4)
            .background(filter == .all ? Color.clear : Theme.accentSoft, in: Capsule())
        }
    }

    static func title(_ filter: InboxFilter) -> LocalizedStringKey {
        switch filter {
        case .all: "Filter"
        case .unread: "Unread"
        case .flagged: "Flagged"
        case .attachments: "Has attachments"
        }
    }
}
