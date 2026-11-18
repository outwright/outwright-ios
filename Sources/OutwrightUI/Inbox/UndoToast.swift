// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI

/// What the undo toast says of a staged batch, for one conversation or several.
enum UndoText {
    static func deleted(_ count: Int) -> String { say(count, "Deleted (toast)", "%lld conversations deleted") }
    static func archived(_ count: Int) -> String { say(count, "Archived (toast)", "%lld conversations archived") }
    static func movedToJunk(_ count: Int) -> String {
        say(count, "Moved to Junk (toast)", "%lld conversations moved to Junk")
    }
    /// Moved to the folder, or plainly moved when its name isn't known.
    static func moved(_ count: Int, to folder: String) -> String {
        guard !folder.isEmpty else { return say(count, "Moved (toast)", "%lld conversations moved") }
        let format = count > 1 ? L10n.string("%lld conversations moved to %@") : L10n.string("Moved to %@ (toast)")
        return count > 1 ? String(format: format, Int64(count), folder) : String(format: format, folder)
    }

    private static func say(_ count: Int, _ one: String, _ many: String) -> String {
        count > 1 ? String(format: L10n.string(many), Int64(count)) : L10n.string(one)
    }
}

/// The bar at the bottom while a move or delete waits out its undo window: what was done, and Undo.
/// It stands in the shared root, so it shows on whatever screen staged the batch.
struct UndoToast: View {
    let pending: PendingMail

    var body: some View {
        if let batch = pending.current {
            HStack(spacing: 12) {
                Text(verbatim: batch.text)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    withAnimation(.snappy) { pending.undo() }
                } label: {
                    Label { Text(ui: "Undo") } icon: { Image(systemName: Icons.undo) }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .lineLimit(1)
                        .fixedSize()
                }
                .accessibilityIdentifier("undo.button")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 26))
            .dynamicTypeSize(...DynamicTypeSize.accessibility3)
            .padding(.horizontal, 16)
            .id(batch.id)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("undo.toast")
        }
    }
}

/// The bar at the bottom while a message just sent goes out: "Sending…". Where the undo toast stands.
struct SendingToast: View {
    let sending: SendingMail?

    var body: some View {
        if let sending {
            HStack(spacing: 12) {
                ProgressView()
                Text(ui: "Sending…")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .glassEffect(.regular, in: .rect(cornerRadius: 26))
            .dynamicTypeSize(...DynamicTypeSize.accessibility3)
            .padding(.horizontal, 16)
            .id(sending.id)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("sending.toast")
        }
    }
}

/// The height the undo toast takes at the bottom, so the bottom bars of a screen move up over it.
struct UndoToastRoomKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var undoToastRoom: CGFloat {
        get { self[UndoToastRoomKey.self] }
        set { self[UndoToastRoomKey.self] = newValue }
    }
}
