// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
public import OutwrightModel
public import OutwrightStore
public import OutwrightSync

/// What the owner can do to a folder from the drawer.
public enum FolderEdit: String, Identifiable, Sendable {
    case newSubfolder, rename, move, delete
    public var id: String { rawValue }
}

/// How a folder edit went: done (with the folder, for a new one), or a problem to show.
public enum FolderEditOutcome: Equatable, Sendable {
    case done(FolderID)
    case problem(String)
}

/// What deleting a folder takes with it on the server, as far as it can be asked.
public enum DeleteWarning: Equatable, Sendable {
    case count(Int)
    /// Offline, or the server didn't say.
    case unknown
}

/// Making, renaming, moving and deleting the owner's folders. Each change is made in the store
/// at once and queued for the server.
@MainActor public struct FolderEdits {
    let store: MailStore
    let sync: SyncCoordinator?
    /// The move or delete waiting out its undo window: committed before a folder changes, so what
    /// it moves out of the folder is out before the folder goes.
    let pending: PendingMail?

    public init(store: MailStore, sync: SyncCoordinator?, pending: PendingMail? = nil) {
        self.store = store
        self.sync = sync
        self.pending = pending
    }

    /// What the folder offers: the folders the app relies on are only given subfolders, and none
    /// is made under the Inbox (the drawer never shows one there) or where the server keeps no
    /// hierarchy (no delimiter).
    /// `among`: the account's folders when the caller holds them (the drawer), else read here.
    /// Nothing while another folder change of the account waits for the server.
    /// `waiting`: whether the account's folder change waits, when the caller knows (the drawer).
    public func actions(for folder: Folder, among known: [Folder]? = nil, waiting: Bool? = nil) -> [FolderEdit] {
        guard !(waiting ?? isWaiting(folder.accountID)) else { return [] }
        let takesSubfolders = Self.takesSubfolders(folder)
        // A folder the app relies on, or one holding such a folder, stays where it is.
        let all = known ?? (try? store.folders(folder.accountID)) ?? []
        let holdsSpecial = all.contains { $0.kind != .other && Self.isUnder($0.path, folder) }
        guard folder.kind == .other, !holdsSpecial else {
            return takesSubfolders ? [.newSubfolder] : []
        }
        return (takesSubfolders ? [.newSubfolder] : []) + [.rename, .move, .delete]
    }

    /// Where the folder can move: its account's folders that take subfolders, but not itself or
    /// what is under it. Empty where the server keeps no hierarchy.
    public func moveDestinations(for folder: Folder) -> [FolderNode] {
        guard folder.delimiter?.isEmpty == false else { return [] }
        let all = (try? store.folders(folder.accountID)) ?? []
        return DrawerModel.tree(all).filter { node in
            node.folder.id != folder.id && !Self.isUnder(node.folder.path, folder) && Self.takesSubfolders(node.folder)
        }
    }

    /// True while a folder change of the account waits for the server: one at a time.
    public func isWaiting(_ account: AccountID) -> Bool {
        (try? store.isFolderChangeWaiting(account)) ?? false
    }

    private static func takesSubfolders(_ folder: Folder) -> Bool {
        folder.kind != .inbox && folder.delimiter?.isEmpty == false
    }

    public func create(named name: String, in parent: Folder?, account: AccountID) async -> FolderEditOutcome {
        let prefix = parent == nil ? await sync?.folderPrefix(for: account) ?? "" : ""
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        pending?.commitNow()
        do {
            let made = try store.createFolder(
                named: name, wire: FolderNaming.wire(name), in: parent?.id, account: account, prefix: prefix)
            return .done(made)
        } catch {
            return .problem(Self.problem(error))
        }
    }

    /// Renames the folder where it stands. Returns the problem to show, or nil.
    public func rename(_ folder: Folder, to name: String) async -> String? {
        let base = Self.base(of: folder)
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        pending?.commitNow()
        return change { () throws(StoreError) in
            try store.renameFolder(folder.id, to: name, wire: FolderNaming.wire(name), under: nil, prefix: base)
        }
    }

    /// Moves the folder under `parent`, or to the top when nil. Returns the problem to show, or nil.
    public func move(_ folder: Folder, under parent: Folder?) async -> String? {
        let prefix = parent == nil ? await sync?.folderPrefix(for: folder.accountID) ?? "" : ""
        let wire = String(folder.path.dropFirst(Self.base(of: folder).count))
        pending?.commitNow()
        return change { () throws(StoreError) in
            try store.renameFolder(folder.id, to: folder.name, wire: wire, under: parent?.id, prefix: prefix)
        }
    }

    /// Deletes the folder, its subfolders and their mail. Returns the problem to show, or nil.
    @discardableResult
    public func delete(_ folder: Folder) -> String? {
        pending?.commitNow()
        return change { () throws(StoreError) in try store.deleteFolder(folder.id) }
    }

    public func deleteWarning(for folder: Folder) async -> DeleteWarning {
        guard let count = await sync?.serverMessageCount(inTreeOf: folder.id) else {
            return .unknown
        }
        return .count(count)
    }

    // MARK: - Helpers

    private func change(_ body: () throws(StoreError) -> Void) -> String? {
        do {
            try body()
            return nil
        } catch {
            return Self.problem(error)
        }
    }

    private static func problem(_ error: StoreError) -> String {
        switch error {
        case .folderNameTaken: L10n.string("There's already a folder with that name here.")
        case .folderNameInvalid: L10n.string("A folder's name can't be empty or contain that character.")
        case .folderProtected: L10n.string("This folder can't be changed.")
        case .folderChangeWaiting: L10n.string("Your last folder change is still on its way to the server.")
        default: L10n.string("The folder couldn't be changed.")
        }
    }

    /// The folder's path up to and with its last delimiter; `""` at the top.
    static func base(of folder: Folder) -> String {
        guard let delimiter = folder.delimiter, !delimiter.isEmpty,
              let cut = folder.path.range(of: delimiter, options: .backwards)
        else { return "" }
        return String(folder.path[..<cut.upperBound])
    }

    private static func isUnder(_ path: String, _ folder: Folder) -> Bool {
        guard let delimiter = folder.delimiter, !delimiter.isEmpty else { return false }
        return path.hasPrefix(folder.path + delimiter)
    }
}

extension AppModel {
    var folderEdits: FolderEdits { FolderEdits(store: store, sync: sync, pending: pendingMail) }

    /// Deletes the folder; when it, or a folder under it, was in view, All inboxes opens instead.
    /// Returns the problem to show, or nil.
    @discardableResult
    func deleteFolder(_ folder: Folder) -> String? {
        let problem = folderEdits.delete(folder)
        leaveVanishedFolder()
        return problem
    }

    /// The folder in view is gone (deleted here, or a folder made here that the server refused):
    /// All inboxes opens instead.
    func leaveVanishedFolder() {
        if case .folder(let folder) = scope, store.findFolder(folder) == nil {
            openAllInboxes()
        }
    }

    /// Makes a top-level folder in the account of `targets` (the move picker's folders), for mail
    /// to be moved into; nil when there is no one account.
    func newFolder(in targets: [FolderNode]) -> ((String) async -> FolderEditOutcome)? {
        guard let account = targets.first?.folder.accountID else { return nil }
        let edits = folderEdits
        // One folder change at a time: none is offered while the last one waits.
        guard !edits.isWaiting(account) else { return nil }
        return { name in await edits.create(named: name, in: nil, account: account) }
    }
}
