// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI

/// Selection mode's bar, in place of the floating actions: how many are chosen, and what can be done
/// to them all (Archive, Delete, Move, Flag, Read or Unread, Select all), or Cancel.
struct SelectionBar: View {
    @Bindable var model: InboxModel
    /// Delete was tapped: the view asks first where it is for good.
    let delete: () -> Void
    /// Move was tapped: the view shows the folders.
    let move: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            Text(String(format: L10n.string("%lld selected"), Int64(model.selection.count)))
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .glassEffect(.regular, in: .capsule)
                .accessibilityIdentifier("selection.count")
            // At the largest text sizes the buttons go on two lines rather than off the screen.
            ViewThatFits(in: .horizontal) {
                capsule(HStack(spacing: 20) { buttons })
                capsule(
                    VStack(spacing: 14) {
                        HStack(spacing: 20) { first }
                        HStack(spacing: 20) { second }
                    })
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }

    private func capsule(_ content: some View) -> some View {
        content
            .font(.title3)
            .foregroundStyle(.primary)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 28))
    }

    @ViewBuilder private var buttons: some View {
        first
        second
    }

    @ViewBuilder private var first: some View {
        button("Cancel", Icons.close, id: "selection.cancel") { model.endSelecting() }
        button(model.allSelected ? "Select none" : "Select all", Icons.selectAll, id: "selection.all") {
            if model.allSelected { model.endSelecting() } else { model.selectAll() }
        }
        let read = model.selectionIsRead
        let flagged = model.selectionIsFlagged
        button(read ? "Mark as unread" : "Mark as read", read ? Icons.unread : Icons.markRead, id: "selection.read") {
            model.readSelected()
        }
        button(flagged ? "Unflag" : "Flag", flagged ? Icons.unflag : Icons.flagOutline, id: "selection.flag") {
            model.flagSelected()
        }
    }

    @ViewBuilder private var second: some View {
        button("Move", Icons.move, id: "selection.move", action: move)
            .disabled(model.moveTargets(model.selection).isEmpty)
        button("Archive", Icons.archive, id: "selection.archive") { model.archiveSelected() }
        button("Delete", Icons.delete, id: "selection.delete", action: delete)
            .foregroundStyle(Theme.delete)
    }

    private func button(
        _ title: LocalizedStringKey, _ icon: String, id: String, action: @escaping () -> Void
    ) -> some View {
        Button {
            withAnimation(.snappy) { action() }
        } label: {
            Image(systemName: icon)
        }
        .accessibilityLabel(Text(ui: title))
        .accessibilityIdentifier(id)
    }
}
