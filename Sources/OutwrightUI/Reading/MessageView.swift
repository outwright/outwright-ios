// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightMIME
import OutwrightModel
import SwiftUI

/// A conversation: round back button and subject, the messages stacked with the latest open,
/// and the glass action bar. Beside the list on a wide screen, the round button widens it instead.
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

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            if model.failed {
                ProblemBanner(text: L10n.string("Something went wrong with this conversation. Try again."))
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
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
            ActionBar(app: app, model: model, more: { AnyView(moreMenu) })
                .padding(.horizontal, 16)
                .clearOfTabCapsule()
                .padding(.bottom, 8)
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
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
        .closesForEvents(isOpen: linkToConfirm != nil || isMoving || details != nil, close: closeSheets)
        .sheet(item: $details, onDismiss: { app.openPending() }, content: { row in
            MessageDetails(row: row, content: model.items.first { $0.id == row.id }?.content) { address in
                app.pendingPerson = PersonRequest(address: address, account: row.accountID)
                details = nil
            }
            .presentationDetents([.medium, .large])
        })
    }

    private func closeSheets() { (linkToConfirm, isMoving, details) = (nil, false, nil) }
    /// Opens the person card of an address from the message's account's point of view.
    private func showPerson(_ address: Address, account: AccountID) {
        app.personToShow = PersonRequest(address: address, account: account)
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            if let isListHidden {
                let hidden = isListHidden.wrappedValue
                Button {
                    withAnimation(.snappy) { isListHidden.wrappedValue.toggle() }
                } label: {
                    Image(systemName: hidden ? Icons.showList : Icons.fullWidth)
                        .font(.title2.weight(.medium))
                        .frame(width: 48, height: 48)
                        .foregroundStyle(.primary)
                }
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel(hidden ? Text(ui: "Show list") : Text(ui: "Show full width"))
                .accessibilityIdentifier("message.fullWidth")
            } else {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: Icons.back)
                        .font(.title2.weight(.medium))
                        .frame(width: 48, height: 48)
                        .foregroundStyle(.primary)
                }
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel(Text(ui: "Back"))
            }
            Text(model.subject.isEmpty ? String(localized: "(No subject)", bundle: .module) : model.subject)
                .font(.title2.bold())
                .lineLimit(2)
                .accessibilityIdentifier("message.subject")
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
        Button { details = row } label: { ModuleLabel("Show details", systemImage: "info.circle") }
    }

    /// The bar's More: for the conversation.
    @ViewBuilder private var moreMenu: some View {
        if let latest = model.latest {
            Button { app.compose(.replyAll(latest.id)) } label: {
                ModuleLabel("Reply all", systemImage: Icons.replyAll)
            }
            Button { app.compose(.forward(latest.id)) } label: { ModuleLabel("Forward", systemImage: Icons.forward) }
            Button { model.markUnread() } label: { ModuleLabel("Mark unread", systemImage: Icons.unread) }
            Button { isMoving = true } label: { ModuleLabel("Move", systemImage: "folder") }
            Button { model.toggleFlag() } label: {
                if latest.isFlagged {
                    ModuleLabel("Unflag", systemImage: "flag.slash")
                } else {
                    ModuleLabel("Flag", systemImage: "flag")
                }
            }
            if latest.inboxClass == .focused {
                Button { model.setInboxClass(.other) } label: {
                    ModuleLabel("Move to Other", systemImage: "arrow.right.square")
                }
            } else {
                Button { model.setInboxClass(.focused) } label: {
                    ModuleLabel("Move to Focused", systemImage: "arrow.left.square")
                }
            }
            Button { details = latest } label: { ModuleLabel("Show details", systemImage: "info.circle") }
        }
    }
}

/// A link waiting for the owner's say-so.
struct LinkTarget: Identifiable {
    let url: URL
    let id = UUID()
}

/// One message of the conversation: open (sender, body, pictures bar, attachments) or a line.
struct ThreadItemView: View {
    let app: AppModel
    let item: ThreadItem
    let model: ThreadModel
    let onLink: (URL) -> Void
    let onPerson: (Address) -> Void
    let menu: () -> AnyView
    @State private var webHeight: CGFloat = 60
    /// The locked web view couldn't be set up; the plain text is shown instead.
    @State private var webUnavailable = false
    /// The meeting card is shown: the calendar part it stands for is not listed as an attachment.
    @State private var cardShown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if item.isExpanded {
                content
            }
        }
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Avatar(name: item.row.from.name, email: item.row.from.email, size: 40)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: senderName))
                .accessibilityHint(Text(ui: "Opens the contact card"))
                .accessibilityAddTraits(.isButton)
                .onTapGesture { onPerson(item.row.from) }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.row.from.name.flatMap { $0.isEmpty ? nil : $0 } ?? item.row.from.email)
                    .font(.title3)
                    .lineLimit(1)
                    .accessibilityHint(Text(ui: "Opens the contact card"))
                    .accessibilityAddTraits(.isButton)
                    .onTapGesture { onPerson(item.row.from) }
                if item.isExpanded, let facts = item.content?.facts, let screens = app.modules.protectionUI {
                    screens.readingMarks(facts, sender: item.row.from)
                }
                Text(item.isExpanded ? recipients : item.row.shownPreview())
                    .font(.body)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                Text(DaySections.rowLabel(item.row.date, now: Date(), calendar: .autoupdatingCurrent))
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                if item.isExpanded {
                    Menu {
                        menu()
                    } label: {
                        Image(systemName: Icons.more)
                            .foregroundStyle(Theme.secondaryText)
                            .frame(width: 32, height: 24)
                    }
                    .accessibilityLabel(Text(ui: "More"))
                }
            }
        }
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
        .onTapGesture {
            Task { await model.toggle(item.id) }
        }
    }

    private var senderName: String {
        item.row.from.name.flatMap { $0.isEmpty ? nil : $0 } ?? item.row.from.email
    }

    /// "To you" when the account's own address is a recipient, else the recipients.
    private var recipients: String {
        switch model.recipients(of: item) {
        case .you:
            return String(localized: "To you", bundle: .module)
        case .others(let names):
            let list = names.prefix(4).joined(separator: ", ")
            return String(localized: "To \(list)", bundle: .module)
        }
    }

    @ViewBuilder private var content: some View {
        if item.isLoading && item.content == nil {
            ProgressView().frame(maxWidth: .infinity).padding()
        } else if let content = item.content {
            if model.isInJunk {
                JunkBar { model.notJunk() }
                    .padding(.horizontal, 16)
            } else if content.hasRemotePictures && !item.allowsRemote && !webUnavailable {
                PicturesBar { model.allowPictures(item.id) }
                    .padding(.horizontal, 16)
            }
            if item.row.isInvitation {
                InvitationCard(app: app, message: item.id, hidesCalendarPart: $cardShown)
                    .padding(.horizontal, 16)
            }
            if content.isUnreadable { UnreadableNote() }
            messageBody(content)
            let files = content.files(besideCard: cardShown)
            if !files.isEmpty {
                AttachmentList(attachments: files).padding(.horizontal, 16)
            }
        } else if item.failed {
            Text(ui: "This message couldn't be loaded. Pull down in the list to try again.")
                .foregroundStyle(Theme.secondaryText)
                .padding(.horizontal, 16)
        }
    }

    @ViewBuilder private func messageBody(_ content: MessageContent) -> some View {
        #if os(iOS)
        if let html = content.html, !webUnavailable {
            // In Junk a link does nothing and pictures are never fetched: Not junk opens them up.
            let junk = model.isInJunk
            LockedWebView(
                html: html, attachments: content.attachments, allowRemote: item.allowsRemote && !junk,
                height: $webHeight, onLink: { if !junk { onLink($0) } }, onUnavailable: { webUnavailable = true }
            )
            .id(item.allowsRemote && !junk)
            .frame(height: webHeight)
        } else {
            plain(content)
        }
        #else
        plain(content)
        #endif
    }

    private func plain(_ content: MessageContent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(content.text ?? "")
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if content.isShortened {
                Text(ui: "This message is long; only its beginning is shown.")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(.horizontal, 16)
    }
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
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Text(ui: "Cancel") }
                }
            }
        }
    }
}
