// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightModel
import SwiftUI

/// Making, renaming, moving and deleting folders from the drawer.
extension SidebarColumn {
    var edits: FolderEdits { app.folderEdits }

    @ViewBuilder func folderSheetView(_ sheet: FolderSheet) -> some View {
        switch sheet {
        case let .create(parent, account):
            FolderNameSheet(title: L10n.string(parent == nil ? "New folder" : "New subfolder"), initial: "") { name in
                switch await edits.create(named: name, in: parent, account: account) {
                case .done:
                    model.reload()
                    return nil
                case let .problem(problem):
                    return problem
                }
            }
        case let .rename(folder):
            FolderNameSheet(title: L10n.string("Rename folder"), initial: FolderNames.name(folder)) { name in
                reloading(await edits.rename(folder, to: name))
            }
        case let .move(folder):
            FolderMoveSheet(destinations: edits.moveDestinations(for: folder)) { parent in
                reloading(await edits.move(folder, under: parent))
            }
        }
    }

    /// On an iPhone the drawer reads the store when it opens: a change made in it shows at once.
    func reloading(_ problem: String?) -> String? {
        if problem == nil {
            model.reload()
        }
        return problem
    }

    /// Long-press actions on a folder in its account's tree.
    @ViewBuilder func folderMenu(_ folder: Folder) -> some View {
        let known = model.editableFolders.first { $0.kind == .account(folder.accountID) }?.folders
        let waiting = model.isWaiting(folder.accountID)
        if waiting {
            Text(ui: "Your last folder change is still on its way to the server.")
                .accessibilityIdentifier("drawer.folderMenu.waiting")
        }
        ForEach(edits.actions(for: folder, among: known, waiting: waiting)) { edit in
            Button(role: edit == .delete ? .destructive : nil) {
                start(edit, on: folder)
            } label: {
                switch edit {
                case .newSubfolder: Label(L10n.string("New subfolder"), systemImage: Icons.newFolder)
                case .rename: Label(L10n.string("Rename"), systemImage: Icons.edit)
                case .move: Label(L10n.string("Move"), systemImage: Icons.move)
                case .delete: Label(L10n.string("Delete"), systemImage: Icons.delete)
                }
            }
            .accessibilityIdentifier("drawer.folderMenu.\(edit.rawValue)")
        }
    }

    func start(_ edit: FolderEdit, on folder: Folder) {
        switch edit {
        case .newSubfolder: folderSheet = .create(parent: folder, account: folder.accountID)
        case .rename: folderSheet = .rename(folder)
        case .move: folderSheet = .move(folder)
        case .delete:
            // Asked at once; the server's count fills in when it comes.
            deleting = (folder, .unknown)
            let edits = edits
            Task {
                let warning = await edits.deleteWarning(for: folder)
                if deleting?.folder.id == folder.id { deleting = (folder, warning) }
            }
        }
    }

    /// The row at the end of an account's folders that makes a new top-level folder.
    /// While a folder change waits for the server it is greyed out and says why.
    func newFolderRow(_ account: AccountID) -> some View {
        let waiting = model.isWaiting(account)
        return VStack(alignment: .leading, spacing: 2) {
            Button {
                folderSheet = .create(parent: nil, account: account)
            } label: {
                FolderRowLabel(icon: Icons.newFolder, name: L10n.string("New folder"), unread: 0, isCurrent: false)
            }
            .buttonStyle(.plain)
            .disabled(waiting)
            .accessibilityIdentifier("drawer.newFolder")
            if waiting {
                Text(ui: "Your last folder change is still on its way to the server.")
                    .font(.footnote).foregroundStyle(Theme.secondaryText)
            }
        }
    }
}
