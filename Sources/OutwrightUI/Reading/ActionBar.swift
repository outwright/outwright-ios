// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightModel
import SwiftUI

/// The glass bar under a message: Reply (with Reply all and Forward behind its chevron), archive,
/// delete, flag, more. Where the word Reply doesn't fit, the arrow alone stands for it.
struct ActionBar: View {
    let app: AppModel
    let model: ThreadModel
    /// Delete, which asks first where it is for good.
    let delete: () -> Void
    let more: () -> AnyView

    var body: some View {
        ViewThatFits(in: .horizontal) {
            bar(withWord: true)
            bar(withWord: false)
        }
        .font(.title3)
        .foregroundStyle(.primary)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }

    private func bar(withWord: Bool) -> some View {
        HStack(spacing: 0) {
            Menu {
                replyButtons
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: Icons.reply)
                    Image(systemName: Icons.unfolded).font(.caption.weight(.semibold))
                    if withWord {
                        Text(ui: "Reply").lineLimit(1).fixedSize()
                    }
                }
            } primaryAction: {
                if let id = model.latest?.id { app.compose(.reply(id)) }
            }
            .accessibilityLabel(Text(ui: "Reply"))
            // The bar's, apart from each message's own Reply.
            .accessibilityIdentifier("reading.reply")
            Spacer(minLength: 12)
            button("Archive", Icons.archive) { model.archive() }
            Spacer(minLength: 12)
            button("Delete", Icons.delete, action: delete)
            Spacer(minLength: 12)
            if model.latest?.isFlagged == true {
                button("Unflag", Icons.flag) { model.toggleFlag() }
                    .foregroundStyle(Theme.flag)
            } else {
                button("Flag", Icons.flagOutline) { model.toggleFlag() }
            }
            Spacer(minLength: 12)
            Menu {
                more()
            } label: {
                Image(systemName: Icons.more)
            }
            .accessibilityLabel(Text(ui: "More"))
        }
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
