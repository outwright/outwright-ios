// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightMIME
import OutwrightModel
import SwiftUI

/// A conversation: the round back button, the subject over the messages (in the top bar once it has
/// scrolled away), the messages stacked with the latest open, and the glass action bar. Beside the
/// list on a wide screen, the round button widens it instead.
struct MessageView: View {
    let app: AppModel
    @State var model: ThreadModel
    /// Set when the conversation is the pane beside the list: whether the list is hidden.
    var isListHidden: Binding<Bool>?
    /// In the pane: the conversation is gone (the list moves on by itself when it was one of its rows).
    var onGone: () -> Void = {}
    /// In the pane: the list's row for this conversation, which moves to a reply when one comes in.
    var follows: MessageID?
    @Environment(\.dismiss) private var dismiss
    @State private var linkToConfirm: LinkTarget?
    @State private var isMoving = false
    @State private var details: MessageRow?
    @State private var askingDeleteForGood = false
    /// The subject at the top of the messages has scrolled out of sight: the top bar shows it.
    @State private var subjectAway = false
    @Environment(\.undoToastRoom) private var toastRoom

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            if model.failed {
                ProblemBanner(text: L10n.string("Something went wrong with this conversation. Try again."))
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Text(subject)
                        .font(.title2.bold())
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 4)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("message.subject")
                        .onGeometryChange(
                            for: Bool.self, of: { $0.frame(in: .scrollView).maxY < 0 },
                            action: { away in withAnimation(.snappy) { subjectAway = away } })
                    ForEach(model.items) { item in
                        ThreadItemView(
                            app: app, item: item, model: model, onLink: { linkToConfirm = LinkTarget(url: $0) },
                            onPerson: { showPerson($0, account: item.row.accountID) },
                            menu: { AnyView(messageMenu(item.row)) })
                        Divider().padding(.leading, 16)
                    }
                }
                .padding(.bottom, 100)
            }
        }
        .background(Theme.background)
        .overlay(alignment: .bottom) {
            ActionBar(app: app, model: model, delete: delete, more: { AnyView(moreMenu) })
                .padding(.horizontal, 16)
                .clearOfTabCapsule()
                .padding(.bottom, 8 + toastRoom)
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        // Pushed over the list on a phone, the message has the screen: its action bar stands where
        // the tabs were. Beside the list the tabs stay.
        .toolbar(isListHidden == nil ? .hidden : .automatic, for: .tabBar)
        #endif
        .task { await model.open() }
        .onChange(of: follows) { _, row in
            guard let row else { return }
            Task { await model.follow(row) }
        }
        .onChange(of: model.isGone) { _, gone in
            guard gone else { return }
            if isListHidden == nil { dismiss() } else { onGone() }
        }
        .sheet(
            item: $linkToConfirm, onDismiss: { app.openPending() },
            content: { LinkConfirmation(url: $0.url).presentationDetents([.medium]) })
        .sheet(
            isPresented: $isMoving, onDismiss: { app.openPending() },
            content: { MovePicker(folders: model.folders()) { model.move(to: $0) } })
        .closesForEvents(
            isOpen: linkToConfirm != nil || isMoving || details != nil || askingDeleteForGood, close: closeSheets)
        .confirmationDialog(
            Text(ui: "Delete for good?"), isPresented: $askingDeleteForGood, titleVisibility: .visible
        ) {
            Button(role: .destructive) { model.deleteForGood() } label: { Text(ui: "Delete for good") }
                .accessibilityIdentifier("message.deleteForGood")
        } message: {
            Text(ui: "It can't be brought back.")
        }
        .sheet(item: $details, onDismiss: { app.openPending() }, content: { row in
            MessageDetails(row: row, content: model.items.first { $0.id == row.id }?.content) { address in
                app.pendingPerson = PersonRequest(address: address, account: row.accountID)
                details = nil
            }
            .presentationDetents([.medium, .large])
        })
    }

    private func closeSheets() {
        (linkToConfirm, isMoving, details, askingDeleteForGood) = (nil, false, nil, false)
    }

    private var subject: String {
        model.subject.isEmpty ? String(localized: "(No subject)", bundle: .module) : model.subject
    }

    /// Delete: through the undo window, or for good (from Trash) once asked.
    private func delete() {
        if model.deleteNeedsConfirmation { askingDeleteForGood = true } else { model.delete() }
    }

    /// Mark unread goes back to the list on a phone; beside the list the row stays selected.
    private func markUnread() {
        if model.markUnread() == .close, isListHidden == nil { dismiss() }
    }
    /// Opens the person card of an address from the message's account's point of view.
    private func showPerson(_ address: Address, account: AccountID) {
        app.personToShow = PersonRequest(address: address, account: account)
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            if let isListHidden {
                let hidden = isListHidden.wrappedValue
                GlassIconButton(
                    hidden ? Icons.showList : Icons.fullWidth, label: hidden ? "Show list" : "Show full width"
                ) {
                    withAnimation(.snappy) { isListHidden.wrappedValue.toggle() }
                }
                .accessibilityIdentifier("message.fullWidth")
            } else {
                GlassIconButton(Icons.back, label: "Back") { dismiss() }
            }
            Text(subject)
                .font(.headline)
                .lineLimit(1)
                .opacity(subjectAway ? 1 : 0)
                .accessibilityHidden(!subjectAway)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// The ⋯ of one message.
    @ViewBuilder private func messageMenu(_ row: MessageRow) -> some View {
        Button { app.compose(.reply(row.id)) } label: { ModuleLabel("Reply", systemImage: Icons.reply) }
        Button { app.compose(.replyAll(row.id)) } label: { ModuleLabel("Reply all", systemImage: Icons.replyAll) }
        Button { app.compose(.forward(row.id)) } label: { ModuleLabel("Forward", systemImage: Icons.forward) }
        Button { details = row } label: { ModuleLabel("Show details", systemImage: Icons.details) }
    }

    /// The bar's More: for the conversation (Reply all and Forward are behind Reply, Flag is on the bar).
    @ViewBuilder private var moreMenu: some View {
        if let latest = model.latest {
            Button { markUnread() } label: { ModuleLabel("Mark unread", systemImage: Icons.unread) }
            Button { isMoving = true } label: { ModuleLabel("Move", systemImage: Icons.move) }
            if model.isInJunk {
                Button { model.notJunk() } label: { ModuleLabel("Not junk", systemImage: Icons.folder(.inbox)) }
            } else {
                Button { model.junk() } label: { ModuleLabel("Junk", systemImage: Icons.junk) }
            }
            if latest.inboxClass == .focused {
                Button { model.setInboxClass(.other) } label: {
                    ModuleLabel("Move to Other", systemImage: Icons.moveToOther)
                }
            } else {
                Button { model.setInboxClass(.focused) } label: {
                    ModuleLabel("Move to Focused", systemImage: Icons.moveToFocused)
                }
            }
            Button { details = latest } label: { ModuleLabel("Show details", systemImage: Icons.details) }
        }
    }
}

/// A link waiting for the owner's say-so.
struct LinkTarget: Identifiable {
    let url: URL
    let id = UUID()
}

/// A tapped link: its real address first, opened only on the owner's say-so and only for
/// http, https, mailto and tel.
struct LinkConfirmation: View {
    let url: URL
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(ui: "Open this link?").font(.title2.bold())
            Text(verbatim: url.absoluteString)
                .font(.body.monospaced())
                .textSelection(.enabled)
                .lineLimit(8)
            if !LinkPolicy.isOpenable(url) {
                Text(ui: "Outwright doesn't open this kind of link.")
                    .foregroundStyle(Theme.delete)
            }
            Spacer()
            HStack {
                Button { dismiss() } label: { Text(ui: "Cancel").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
                if LinkPolicy.isOpenable(url) {
                    Button {
                        openURL(url)
                        dismiss()
                    } label: {
                        Text(ui: "Open").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .controlSize(.large)
        }
        .padding(24)
    }
}

/// Move: the account's other folders.
struct MovePicker: View {
    let folders: [FolderNode]
    let choose: (FolderID) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(folders) { node in
                Button {
                    choose(node.folder.id)
                    dismiss()
                } label: {
                    Label(FolderNames.name(node.folder), systemImage: Icons.folder(node.folder.kind))
                        .padding(.leading, CGFloat(node.indent) * 20)
                }
            }
            .navigationTitle(Text(ui: "Move to"))
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Text(ui: "Cancel") }
                }
            }
        }
    }
}
