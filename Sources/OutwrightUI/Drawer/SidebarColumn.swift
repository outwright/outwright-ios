// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightModel
import OutwrightStore
import SwiftUI

/// What the drawer holds, and on iPad the sidebar: a column of accounts (All accounts, one badge
/// each, plus), with help and settings at its foot, and beside it the chosen account and what the
/// tab shows of it (Favorites and folders, calendars, or address books). On an iPad the accounts are
/// in the tab rail, and the sidebar is only what is beside them.
struct SidebarColumn: View {
    @ScaledMetric(relativeTo: .body) private var foldWidth: CGFloat = 32
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 44
    @Bindable var app: AppModel
    @Bindable var model: DrawerModel
    @Bindable var calendar: CalendarModel
    @Bindable var contacts: ContactsModel
    /// The column of accounts (the drawer); on an iPad the rail holds them instead.
    var showsAccounts = true
    @State private var isEditingFavorites = false
    @State var folderSheet: FolderSheet?
    @State var deleting: (folder: Folder, warning: DeleteWarning)?
    @State var folderProblem: String?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The round badges and the column they stand in grow with the text, up to a limit the drawer can hold.
    @ScaledMetric(relativeTo: .title2) private var badgeSize: CGFloat = 52
    private var badgeDiameter: CGFloat { min(badgeSize, 80) }

    /// At the accessibility sizes the accounts go in a row above the folders, which then have the
    /// drawer's whole width.
    private var isStacked: Bool { dynamicTypeSize.isAccessibilitySize }

    var body: some View {
        let layout = isStacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 0))
        layout {
            // Avatars and icons only: past the largest standard size they would take the folders' room.
            if showsAccounts {
                accountColumn.dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            }
            folderColumn
                .padding(.leading, isStacked || !showsAccounts ? 16 : 0)
        }
        .sheet(
            isPresented: $isEditingFavorites, onDismiss: { app.openPending() },
            content: { FavoritesEditor(model: model) })
        .closesForEvents(isOpen: isEditingFavorites, inDrawer: true) { isEditingFavorites = false }
        .sheet(item: $folderSheet, content: folderSheetView)
        .alert(
            Text(ui: "The folder couldn't be changed."),
            isPresented: Binding(get: { folderProblem != nil }, set: { if !$0 { folderProblem = nil } }),
            presenting: folderProblem
        ) { _ in
            Button { folderProblem = nil } label: { Text(ui: "OK") }
        } message: { problem in
            Text(problem)
        }
        // A folder change the server took, or refused, frees the drawer for the next.
        .task {
            do {
                for try await _ in app.store.observeFolderChangeWaiting() { model.reload() }
            } catch {
                // The database can't be watched any more: the drawer reads it when it opens.
            }
        }
        .closesForEvents(isOpen: folderSheet != nil, inDrawer: true) { folderSheet = nil }
        .confirmationDialog(
            Text(ui: "Delete folder?"),
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible, presenting: deleting
        ) { chosen in
            Button(role: .destructive) {
                folderProblem = app.deleteFolder(chosen.folder)
                model.reload()
            } label: {
                Text(ui: "Delete")
            }
            .accessibilityIdentifier("folderEdit.delete")
        } message: { chosen in
            Text(chosen.warning.message(FolderNames.name(chosen.folder)))
        }
    }

    // MARK: Accounts

    @ViewBuilder private var accountColumn: some View {
        if isStacked {
            HStack(spacing: 14) {
                ScrollView(.horizontal) {
                    HStack(spacing: 14) { AccountBadges(app: app, model: model, diameter: badgeDiameter) }
                        .padding(.vertical, 4)
                }
                .scrollIndicators(.hidden)
                drawerButtons
            }
            .font(.title2)
            .foregroundStyle(.primary)
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 4)
        } else {
            VStack(spacing: 18) {
                AccountBadges(app: app, model: model, diameter: badgeDiameter)
                Spacer()
                drawerButtons
            }
            .font(.title2)
            .foregroundStyle(.primary)
            .buttonStyle(.plain)
            .padding(.top, 8)
            .padding(.bottom, 16)
            .frame(width: badgeDiameter + 32)
        }
    }

    /// Help and settings, at the column's foot or the row's end.
    @ViewBuilder private var drawerButtons: some View {
        Button {
            app.isShowingHelp = true
        } label: {
            Image(systemName: Icons.help)
        }
        .accessibilityLabel(Text(ui: "Help"))
        Button {
            app.showSettings(account: model.selected)
        } label: {
            Image(systemName: Icons.settings)
        }
        .accessibilityLabel(Text(ui: "Settings"))
    }

    // MARK: Folders

    private var folderColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                accountHeader
                    .padding(.bottom, 14)
                switch app.selectedTab {
                case .mail:
                    ForEach(model.sections) { section in
                        sectionView(section)
                    }
                case .calendar:
                    DrawerCalendars(app: app, model: calendar, account: model.selected)
                case .contacts:
                    DrawerAddressBooks(model: contacts, account: model.selected)
                }
            }
            .padding(.top, 10)
            .padding(.trailing, 16)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder private var accountHeader: some View {
        if let account = model.selectedAccount {
            Button {
                app.showSettings(account: account.id)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.displayName).font(.title2.bold()).lineLimit(1)
                        .accessibilityIdentifier("drawer.accountHeader")
                    Text(account.email).font(.body).foregroundStyle(Theme.secondaryText).lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .accessibilityIdentifier("drawer.accountEmail")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            Text(ui: "All accounts").font(.title2.bold())
                .accessibilityIdentifier("drawer.accountHeader")
        }
    }

    @ViewBuilder private func sectionView(_ section: DrawerSection) -> some View {
        switch section.kind {
        case .favorites:
            HStack {
                SectionHeader("Favorites")
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
            newFolderRow(id)
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
                accountColor: markAccount ? accountColor(folder.accountID) : nil,
                accountName: markAccount ? model.accountNameBelow(folder) : nil)
        }
        .buttonStyle(.plain)
    }

    /// A folder in its account's tree: indented under its parent, with a fold toggle when it has
    /// subfolders.
    private func treeRow(_ folder: Folder) -> some View {
        HStack(spacing: 4) {
            folderRow(folder)
                .contextMenu { folderMenu(folder) }
            if model.hasSubfolders(folder) {
                let folded = model.isCollapsed(folder)
                Button {
                    withAnimation(.snappy) { model.toggle(folder) }
                } label: {
                    Image(systemName: folded ? Icons.folded : Icons.unfolded)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.secondaryText)
                        .frame(width: foldWidth, height: rowHeight)
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
    /// The account's name under the folder's, when the same name stands twice among the favourites.
    var accountName: String?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .title3) private var iconWidth: CGFloat = 28

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: isCurrent ? icon + ".fill" : icon)
                .font(.title3)
                .frame(width: iconWidth)
                .foregroundStyle(isCurrent ? Theme.accent : Theme.secondaryText)
            VStack(alignment: .leading, spacing: 0) {
                Text(name)
                    .font(.title3.weight(isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Theme.accent : .primary)
                    // At the accessibility sizes a long name wraps rather than losing its end.
                    .lineLimit(isStacked ? 3 : 1)
                if let accountName {
                    Text(verbatim: accountName)
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(isStacked ? 2 : 1)
                }
                // At the accessibility sizes the count goes under the name, which keeps the row's width.
                if isStacked, accountColor != nil || unread > 0 {
                    HStack(spacing: 8) { marks }
                        .padding(.top, 4)
                }
            }
            Spacer(minLength: 8)
            if !isStacked { marks }
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private var isStacked: Bool { dynamicTypeSize.isAccessibilitySize }

    /// The account's dot and the unread count.
    @ViewBuilder private var marks: some View {
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
}
