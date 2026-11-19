// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightMIME
import OutwrightModel
import SwiftUI

/// One message of the conversation: open (sender, body, pictures bar, attachments) or a line.
struct ThreadItemView: View {
    @ScaledMetric(relativeTo: .body) private var moreWidth: CGFloat = 32
    @ScaledMetric(relativeTo: .body) private var moreHeight: CGFloat = 24
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.colorScheme) private var colorScheme
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
    /// The web view has laid out the body (for these settings); until then a spinner stands in.
    @State private var webShown: WebKey?
    /// The owner chose to see this message as written, on white, in dark mode.
    @State private var asWritten = false

    /// What the body's page is made for: a change of any of them makes a new one.
    private struct WebKey: Hashable {
        let remote: Bool
        let dark: Bool
        let asWritten: Bool
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if item.isExpanded, let facts = item.content?.facts,
                let screens = app.modules.screens(for: facts.protection) {
                // Apart from the header, so a tap on a mark (or its Verify, Find key) never folds the message.
                let id = item.id
                screens.readingMarks(facts, sender: item.row.from) { await model.reverify(id) }
                    .padding(.leading, 16 + 40 + 12)
                    .padding(.trailing, 16)
            }
            if item.isExpanded {
                content
            }
        }
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }

    /// Sender and recipients, with the time and the message's buttons beside them, or under them at the
    /// largest text sizes.
    private var header: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 12) { avatar; who }
                    HStack(spacing: 8) {
                        stamp
                        Spacer(minLength: 8)
                        if item.isExpanded { buttons }
                    }
                }
            } else {
                HStack(alignment: .top, spacing: 12) {
                    avatar
                    who
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 6) {
                        stamp
                        if item.isExpanded { buttons }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
        .onTapGesture {
            Task { await model.toggle(item.id) }
        }
    }

    private var avatar: some View {
        Avatar(name: item.row.from.name, email: item.row.from.email, size: 40)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: senderName))
            .accessibilityHint(Text(ui: "Opens the contact card"))
            .accessibilityAddTraits(.isButton)
            .onTapGesture { onPerson(item.row.from) }
    }

    private var who: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(senderName)
                .font(.title3)
                .lineLimit(1)
                .accessibilityHint(Text(ui: "Opens the contact card"))
                .accessibilityAddTraits(.isButton)
                .onTapGesture { onPerson(item.row.from) }
            Text(item.isExpanded ? recipients : item.row.shownPreview())
                .font(.body)
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
        }
    }

    /// The flag and the time: with the date for older mail once the message is open.
    private var stamp: some View {
        HStack(spacing: 4) {
            if item.row.isFlagged {
                Image(systemName: Icons.flag)
                    .foregroundStyle(Theme.flag)
                    .accessibilityLabel(Text(ui: "Flagged"))
            }
            Text(item.isExpanded
                ? DaySections.readingLabel(item.row.date, now: Date())
                : DaySections.rowLabel(item.row.date, now: Date(), calendar: .autoupdatingCurrent))
                .lineLimit(1)
                .fixedSize()
        }
        .font(.subheadline)
        .foregroundStyle(Theme.secondaryText)
    }

    /// Reply to this message, and its ⋯.
    private var buttons: some View {
        HStack(spacing: 4) {
            if colorScheme == .dark, item.content?.html != nil, !webUnavailable {
                Button { asWritten.toggle() } label: {
                    Image(systemName: asWritten ? Icons.darkBackground : Icons.lightBackground)
                        .foregroundStyle(Theme.secondaryText)
                        .frame(width: moreWidth, height: moreHeight)
                }
                .accessibilityLabel(Text(ui: asWritten ? "Dark background" : "Light background"))
            }
            Button { app.compose(.reply(item.id)) } label: {
                Image(systemName: Icons.reply)
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: moreWidth, height: moreHeight)
            }
            .accessibilityLabel(Text(ui: "Reply"))
            Menu {
                menu()
            } label: {
                Image(systemName: Icons.more)
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: moreWidth, height: moreHeight)
            }
            .accessibilityLabel(Text(ui: "More"))
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
            } else if content.offersRemotePictures && !item.allowsRemote && !webUnavailable {
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
                AttachmentList(
                    attachments: files, actions: app.modules.attachmentActions,
                    account: app.accounts.first { $0.id == item.row.accountID }
                ).padding(.horizontal, 16)
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
            let remote = item.allowsRemote && !junk && (content.facts?.allowsRemoteContent ?? true)
            let key = WebKey(remote: remote, dark: colorScheme == .dark, asWritten: asWritten)
            let shown = webShown == key
            ZStack(alignment: .top) {
                LockedWebView(
                    html: html, attachments: content.attachments, allowRemote: remote, dark: key.dark,
                    adaptsColors: !asWritten, height: $webHeight, onLink: { if !junk { onLink($0) } },
                    onUnavailable: { webUnavailable = true }, onShown: { webShown = key }
                )
                .id(key)
                .frame(height: shown ? webHeight : 1)
                .opacity(shown ? 1 : 0)
                if !shown {
                    // In the body's place until the web view has laid it out.
                    ProgressView().frame(maxWidth: .infinity).padding()
                }
            }
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
