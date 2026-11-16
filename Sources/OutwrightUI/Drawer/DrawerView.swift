// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightModel
import OutwrightStore
import SwiftUI

/// The drawer: a column of accounts (All accounts, one badge each, plus) with help and settings
/// at its foot; beside it the chosen account, its Favorites and its folders.
struct DrawerView: View {
    @Bindable var app: AppModel
    @Bindable var model: DrawerModel
    @State private var isEditingFavorites = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            accountColumn
            folderColumn
        }
        .background(Theme.drawerBackground.ignoresSafeArea())
        .sheet(
            isPresented: $isEditingFavorites, onDismiss: { app.openPending() },
            content: { FavoritesEditor(model: model) })
        .closesForEvents(isOpen: isEditingFavorites) { isEditingFavorites = false }
    }

    // MARK: Accounts

    private var accountColumn: some View {
        VStack(spacing: 18) {
            if app.accounts.count > 1 {
                badge(selected: model.selected == nil) {
                    Circle()
                        .fill(Theme.accent)
                        .overlay {
                            Image(systemName: Icons.allAccounts).font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(Theme.onAccent)
                        }
                } action: {
                    model.selected = nil
                }
                .accessibilityLabel(Text(ui: "All accounts"))
            }
            ForEach(model.accounts) { account in
                badge(selected: model.selected == account.id) {
                    Avatar(name: account.displayName, email: account.email, size: 52, colorIndex: account.colorIndex)
                } action: {
                    model.selected = account.id
                }
                .accessibilityLabel(Text(account.email))
            }
            Button {
                app.isAddingAccount = true
            } label: {
                Circle()
                    .fill(Theme.background)
                    .overlay(Circle().stroke(Theme.separator))
                    .overlay(Image(systemName: Icons.add).font(.title2).foregroundStyle(.primary))
                    .frame(width: 52, height: 52)
            }
            .accessibilityLabel(Text(ui: "Add account"))
            Spacer()
            Button {
                app.isShowingHelp = true
            } label: {
                Image(systemName: Icons.help)
            }
            .accessibilityLabel(Text(ui: "Help"))
            Button {
                app.showSettings()
            } label: {
                Image(systemName: Icons.settings)
            }
            .accessibilityLabel(Text(ui: "Settings"))
        }
        .font(.title2)
        .foregroundStyle(.primary)
        .buttonStyle(.plain)
        .padding(.top, 8)
        .padding(.bottom, 16)
        .frame(width: 84)
    }

    private func badge(
        selected: Bool, @ViewBuilder content: () -> some View, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            content()
                .frame(width: 52, height: 52)
                .padding(3)
                .overlay(Circle().stroke(selected ? Theme.accent : .clear, lineWidth: 3))
        }
        .buttonStyle(.plain)
    }

    // MARK: Folders

    private var folderColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                accountHeader
                    .padding(.bottom, 14)
                ForEach(model.sections) { section in
                    sectionView(section)
                }
            }
            .padding(.top, 10)
            .padding(.trailing, 16)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder private var accountHeader: some View {
        if let account = model.selectedAccount {
            VStack(alignment: .leading, spacing: 2) {
                Text(account.displayName).font(.title2.bold()).lineLimit(1)
                    .accessibilityIdentifier("drawer.accountHeader")
                Text(account.email).font(.body).foregroundStyle(Theme.secondaryText).lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .accessibilityIdentifier("drawer.accountEmail")
            }
        } else {
            Text(ui: "All accounts").font(.title2.bold())
                .accessibilityIdentifier("drawer.accountHeader")
        }
    }

    @ViewBuilder private func sectionView(_ section: DrawerSection) -> some View {
        switch section.kind {
        case .favorites:
            HStack {
                Text(ui: "Favorites").font(.title3).foregroundStyle(Theme.secondaryText)
                    .accessibilityIdentifier("drawer.favorites")
                Spacer()
                Button {
                    isEditingFavorites = true
                } label: {
                    Image(systemName: Icons.edit).font(.title3).foregroundStyle(Theme.secondaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(ui: "Edit favorites"))
            }
            .padding(.bottom, 4)
            if model.selected == nil {
                allInboxesRow
            }
            ForEach(section.folders) { folder in
                folderRow(folder, markAccount: model.selected == nil && model.accounts.count > 1)
            }
            Spacer().frame(height: 14)
        case .account(let id):
            if model.selected == nil, let account = model.accounts.first(where: { $0.id == id }) {
                Text(account.email).font(.subheadline).foregroundStyle(Theme.secondaryText)
                    .lineLimit(1).padding(.top, 10).padding(.bottom, 4)
            }
            ForEach(section.folders) { folder in
                treeRow(folder)
            }
        }
    }

    private var allInboxesRow: some View {
        let isCurrent = app.scope == .allAccounts
        return Button {
            withAnimation(.snappy) { app.openAllInboxes() }
        } label: {
            FolderRowLabel(
                icon: Icons.allAccounts, name: L10n.string("All inboxes"), unread: totalInboxUnread,
                isCurrent: isCurrent)
        }
        .buttonStyle(.plain)
    }

    private var totalInboxUnread: Int {
        model.sections.filter { $0.kind != .favorites }.flatMap(\.folders).filter { $0.kind == .inbox }
            .reduce(0) { $0 + $1.unread }
    }

    private func folderRow(_ folder: Folder, markAccount: Bool = false) -> some View {
        Button {
            withAnimation(.snappy) { app.open(folder.id) }
        } label: {
            FolderRowLabel(
                icon: Icons.folder(folder.kind), name: FolderNames.name(folder),
                unread: folder.kind == .sent || folder.kind == .trash ? 0 : folder.unread,
                isCurrent: app.scope == .folder(folder.id),
                accountColor: markAccount ? accountColor(folder.accountID) : nil)
        }
        .buttonStyle(.plain)
    }

    /// A folder in its account's tree: indented under its parent, with a fold toggle when it has
    /// subfolders.
    private func treeRow(_ folder: Folder) -> some View {
        HStack(spacing: 4) {
            folderRow(folder)
            if model.hasSubfolders(folder) {
                let folded = model.isCollapsed(folder)
                Button {
                    withAnimation(.snappy) { model.toggle(folder) }
                } label: {
                    Image(systemName: folded ? Icons.folded : Icons.unfolded)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.secondaryText)
                        .frame(width: 32, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(ui: folded ? "Show subfolders" : "Hide subfolders"))
            }
        }
        .padding(.leading, CGFloat(model.depth(folder)) * 20)
    }

    private func accountColor(_ id: AccountID) -> Color? {
        model.accounts.first { $0.id == id }.map { Theme.avatarColor($0.colorIndex) }
    }
}

struct FolderRowLabel: View {
    let icon: String
    let name: String
    let unread: Int
    let isCurrent: Bool
    /// Which account a favourite belongs to, when several accounts' favourites are listed.
    var accountColor: Color?

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: isCurrent ? icon + ".fill" : icon)
                .font(.title3)
                .frame(width: 28)
                .foregroundStyle(isCurrent ? Theme.accent : Theme.secondaryText)
            Text(name)
                .font(.title3.weight(isCurrent ? .semibold : .regular))
                .foregroundStyle(isCurrent ? Theme.accent : .primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let accountColor {
                Circle().fill(accountColor).frame(width: 8, height: 8)
            }
            if unread > 0 {
                Text("\(unread)")
                    .font(.body)
                    .foregroundStyle(isCurrent ? Theme.accent : Theme.secondaryText)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5).fill(isCurrent ? Theme.accentSoft : Theme.separator))
            }
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}
