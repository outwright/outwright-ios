// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightModel
import SwiftUI

/// Mail on a wide screen: the list on the left and the selected conversation beside it, which can
/// widen to the whole screen.
struct MailPanes: View {
    @Bindable var app: AppModel
    @Bindable var inbox: InboxModel
    @State private var isListHidden = false

    /// The list's share of the width, and the least it gets.
    static let listShare: CGFloat = 0.36
    static let listMinimum: CGFloat = 300

    /// The list's width on a screen `width` wide.
    static func listWidth(_ width: CGFloat) -> CGFloat { max(width * listShare, listMinimum) }

    var body: some View {
        GeometryReader { geometry in
            let listWidth = Self.listWidth(geometry.size.width)
            HStack(spacing: 0) {
                if !isListHidden {
                    InboxView(app: app, model: inbox, path: .constant([]), selects: true)
                        .standsOnTabCapsule()
                        .frame(width: listWidth)
                        .transition(.move(edge: .leading))
                    Rectangle().fill(Theme.separator).frame(width: 1).ignoresSafeArea()
                }
                reading
                    .besideTabCapsule(from: isListHidden ? 0 : listWidth + 1)
                    .frame(maxWidth: .infinity)
            }
        }
        .background(Theme.background)
        .onChange(of: inbox.selected) { _, selected in if selected == nil { isListHidden = false } }
    }

    @ViewBuilder private var reading: some View {
        if let id = inbox.selected {
            MessageView(
                app: app, model: ThreadModel(store: app.store, message: id) { await app.fetchBody($0) },
                isListHidden: $isListHidden,
                onGone: { if inbox.selected == id, !inbox.shows(id) { inbox.selected = nil } }, follows: id)
                .id(conversation(id))
        } else {
            ContentUnavailableView {
                Label { Text(ui: "No message selected") } icon: { Image(systemName: Icons.mail) }
            }
        }
    }

    /// What keeps the pane the same view: the conversation, so a reply joins it instead of replacing it.
    private func conversation(_ id: MessageID) -> AnyHashable {
        guard let row = inbox.sections.lazy.flatMap(\.rows).first(where: { $0.id == id }) else { return id }
        return [AnyHashable(row.accountID), AnyHashable(row.threadID)]
    }
}
