// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightModel
import SwiftUI

/// The glass bar under a message: Reply (with Reply all and Forward behind its chevron),
/// mark unread, delete, archive, junk, more.
struct ActionBar: View {
    let app: AppModel
    let model: ThreadModel
    let more: () -> AnyView

    var body: some View {
        HStack(spacing: 0) {
            Menu {
                replyButtons
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: Icons.reply)
                    Image(systemName: "chevron.down").font(.caption.weight(.semibold))
                    Text(ui: "Reply").font(.title3)
                }
            } primaryAction: {
                if let id = model.latest?.id { app.compose(.reply(id)) }
            }
            .accessibilityLabel(Text(ui: "Reply"))
            Spacer(minLength: 12)
            button("Mark unread", Icons.unread) { model.markUnread() }
            Spacer(minLength: 12)
            button("Delete", Icons.delete) { model.delete() }
            Spacer(minLength: 12)
            button("Archive", Icons.archive) { model.archive() }
            Spacer(minLength: 12)
            if model.isInJunk {
                button("Not junk", Icons.folder(.inbox)) { model.notJunk() }
            } else {
                button("Junk", Icons.junk) { model.junk() }
            }
            Spacer(minLength: 12)
            Menu {
                more()
            } label: {
                Image(systemName: Icons.more)
            }
            .accessibilityLabel(Text(ui: "More"))
        }
        .font(.title3)
        .foregroundStyle(.primary)
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    @ViewBuilder var replyButtons: some View {
        if let id = model.latest?.id {
            Button { app.compose(.reply(id)) } label: { ModuleLabel("Reply", systemImage: Icons.reply) }
            Button { app.compose(.replyAll(id)) } label: { ModuleLabel("Reply all", systemImage: Icons.replyAll) }
            Button { app.compose(.forward(id)) } label: { ModuleLabel("Forward", systemImage: Icons.forward) }
        }
    }

    private func button(_ key: LocalizedStringKey, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
        }
        .accessibilityLabel(Text(ui: key))
    }
}
