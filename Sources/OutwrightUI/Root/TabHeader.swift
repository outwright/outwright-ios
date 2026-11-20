// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightModel
import SwiftUI

/// The header every tab has: the account avatar that opens the drawer, the title in large type, a
/// glass capsule with the tab's own buttons, and under them what the tab keeps in a second row.
struct TabHeader<Trailing: View, Below: View>: View {
    @Bindable var app: AppModel
    let title: String
    let titleID: String
    /// A title that is a button (Calendar's month opens the month): what a tap does, and whether what
    /// it opens is open, which its chevron shows.
    let titleAction: (() -> Void)?
    let titleExpanded: Bool
    @ViewBuilder let trailing: () -> Trailing
    @ViewBuilder let below: () -> Below
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.wideLayout) private var wideLayout

    init(
        app: AppModel, title: String, titleID: String, titleAction: (() -> Void)? = nil, titleExpanded: Bool = false,
        @ViewBuilder trailing: @escaping () -> Trailing, @ViewBuilder below: @escaping () -> Below
    ) {
        self.app = app
        self.title = title
        self.titleID = titleID
        self.titleAction = titleAction
        self.titleExpanded = titleExpanded
        self.trailing = trailing
        self.below = below
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Button {
                    if wideLayout == .sidebar {
                        withAnimation(.snappy) { app.toggleSidebar() }
                    } else {
                        withAnimation(.snappy) { app.isDrawerOpen = true }
                    }
                } label: {
                    HeaderAvatar(app: app)
                        .attentionDot(!app.attentionInView.isEmpty, ring: Theme.header)
                }
                .accessibilityLabel(Text(ui: "Folders and accounts"))
                // Icons only, as a bar's buttons: past the largest standard size they would take the title's room.
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                if let titleAction {
                    Button(action: titleAction) {
                        HStack(spacing: 4) {
                            titleText
                            // At the largest sizes the header has no room for it.
                            if !dynamicTypeSize.isAccessibilitySize {
                                Image(systemName: Icons.miniMonth(open: titleExpanded))
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(Theme.headerText)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .layoutPriority(1)
                    .accessibilityAddTraits(titleExpanded ? .isSelected : [])
                    .accessibilityIdentifier(titleID)
                } else {
                    titleText.accessibilityIdentifier(titleID)
                }
                Spacer(minLength: 8)
                HStack(spacing: 22, content: trailing)
                    .font(.title3)
                    .foregroundStyle(Theme.headerText)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .glassEffect(.regular.tint(Theme.accent.opacity(0.12)).interactive(), in: .capsule)
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            }
            below()
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 12)
        .background(Theme.header.ignoresSafeArea(edges: .top))
    }

    private var titleText: some View {
        Text(verbatim: title)
            .font(.largeTitle.bold())
            .foregroundStyle(Theme.headerText)
            .lineLimit(1)
            // A long title (a month, at the largest sizes any) shrinks rather than losing its end.
            .minimumScaleFactor(0.5)
            .truncationMode(.tail)
    }
}

/// The banners of what needs attention under a tab's header: in Mail the account in view's, or
/// every account's. A tap goes where the item is put right.
struct AttentionBanners: View {
    let app: AppModel

    var body: some View {
        ForEach(app.attentionInView, id: \.self) { item in
            ProblemBanner(
                text: "\(name(item.account)): \(item.text)", onTap: { app.act(on: item) },
                tapHint: hint(item.action),
                accessory: {
                    if item.action == .signInAgain {
                        if app.isSigningIn(item.account) {
                            ProgressView()
                        } else if let account = app.accounts.first(where: { $0.id == item.account }) {
                            SignInAgainButton(app: app, account: account)
                        }
                    }
                })
        }
    }

    private func name(_ id: AccountID) -> String {
        app.accounts.first { $0.id == id }?.displayName ?? ""
    }

    private func hint(_ action: AttentionItem.Action) -> Text {
        switch action {
        case .drafts: Text(ui: "Opens the account's Drafts")
        case .signInAgain: Text(ui: "Signs in again")
        case .accountSettings: Text(ui: "Opens the account's settings")
        case .dismiss: Text(ui: "Dismisses this")
        }
    }
}

extension TabHeader where Below == EmptyView {
    init(
        app: AppModel, title: String, titleID: String, titleAction: (() -> Void)? = nil, titleExpanded: Bool = false,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.init(
            app: app, title: title, titleID: titleID, titleAction: titleAction, titleExpanded: titleExpanded,
            trailing: trailing) { EmptyView() }
    }
}
