// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
public import Observation
public import OutwrightModel
public import OutwrightStore

/// One block of the drawer's folder list.
public struct DrawerSection: Identifiable, Equatable, Sendable {
    public enum Kind: Hashable, Sendable {
        case favorites
        case account(AccountID)
    }

    public var kind: Kind
    public var folders: [Folder]
    public var id: Kind { kind }
}

/// A folder in its account's tree.
public struct FolderNode: Identifiable, Equatable, Sendable {
    public var folder: Folder
    /// Steps under the top of the tree.
    public var depth: Int
    public var parent: FolderID?
    public var id: FolderID { folder.id }

    /// Deepest a row is indented; anything further down stands at this depth.
    static let maxIndent = 16

    /// How far the row is indented.
    var indent: Int { min(depth, Self.maxIndent) }
}

/// The drawer: accounts down the side; for the chosen one (or all), Favorites, then its folders.
@Observable @MainActor
public final class DrawerModel {
    @ObservationIgnored let store: MailStore
    /// The move or delete waiting out its undo window: its unread messages leave their folder's count.
    @ObservationIgnored let pending: PendingMail?
    public private(set) var accounts: [Account] = []
    /// nil: all accounts.
    public var selected: AccountID? {
        didSet { if selected != oldValue { reload() } }
    }
    /// Favorites, then each account's folders as far as they are unfolded.
    public private(set) var sections: [DrawerSection] = []
    public private(set) var failed = false
    /// Every folder of each account in view, unfolded or not, in tree order.
    private var trees: [DrawerSection] = []
    private var depths: [FolderID: Int] = [:]
    private var parents: Set<FolderID> = []
    /// Each folder's parent in its tree.
    private var parentOf: [FolderID: FolderID] = [:]
    /// Folders whose subfolders are shown; every other folder starts folded. Kept while the app runs.
    private var expanded: Set<FolderID> = []

    public init(store: MailStore, selected: AccountID?, pending: PendingMail? = nil) {
        self.store = store
        self.pending = pending
        self.selected = selected
        pending?.watch(self)
        reload()
    }

    /// The unread messages a staged move or delete takes from each folder.
    private func stagedUnread() -> [FolderID: Int] {
        var counts: [FolderID: Int] = [:]
        for id in pending?.hidden ?? [] {
            guard let row = (try? store.message(id)) ?? nil, !row.isRead else { continue }
            counts[row.folderID, default: 0] += 1
        }
        return counts
    }

    /// A folder as the drawer counts it: without the unread messages a staged batch takes away.
    private static func counted(_ folder: Folder, less staged: [FolderID: Int]) -> Folder {
        guard let taken = staged[folder.id] else { return folder }
        var folder = folder
        folder.unread = max(folder.unread - taken, 0)
        return folder
    }

    public var selectedAccount: Account? {
        accounts.first { $0.id == selected }
    }

    /// The account to name under a favourite, when favourites of several accounts share its name
    /// ("Inbox" twice): the account's address. nil when the name is unique or one account is in view.
    public func accountNameBelow(_ folder: Folder) -> String? {
        guard selected == nil, let favorites = sections.first(where: { $0.kind == .favorites }) else { return nil }
        let name = FolderNames.name(folder)
        let shared = favorites.folders.contains { $0.id != folder.id && FolderNames.name($0) == name }
        guard shared else { return nil }
        return accounts.first { $0.id == folder.accountID }?.email
    }

    /// Every folder that can be a favourite in this view, with its account, for the editor.
    public var editableFolders: [DrawerSection] {
        trees
    }

    /// How many steps a folder's row is indented under its parents.
    public func depth(_ folder: Folder) -> Int {
        min(depths[folder.id] ?? 0, FolderNode.maxIndent)
    }

    public func hasSubfolders(_ folder: Folder) -> Bool {
        parents.contains(folder.id)
    }

    public func isCollapsed(_ folder: Folder) -> Bool {
        parents.contains(folder.id) && !expanded.contains(folder.id)
    }

    /// Folds a folder's subfolders away, or out again.
    public func toggle(_ folder: Folder) {
        if expanded.remove(folder.id) == nil {
            expanded.insert(folder.id)
        }
        showUnfolded()
    }

    /// Unfolds every folder above this one, so that its row is shown.
    public func reveal(_ folder: FolderID) {
        var above = parentOf[folder]
        var steps = 0
        while let parent = above, steps <= depths.count {
            expanded.insert(parent)
            above = parentOf[parent]
            steps += 1
        }
        showUnfolded()
    }

    /// Reloads on each change to the accounts, folders or unread counts, while the sidebar shows.
    public func observe() async {
        do {
            for try await _ in store.observeFolders() { reload() }
        } catch {
            // The database can't be watched any more: the folders stay as last read.
        }
    }

    public func reload() {
        do {
            accounts = try store.accounts()
            let shown = accounts.filter { selected == nil || $0.id == selected }
            var favorites: [Folder] = []
            var perAccount: [DrawerSection] = []
            var depths: [FolderID: Int] = [:]
            var parents: Set<FolderID> = []
            var parentOf: [FolderID: FolderID] = [:]
            let staged = stagedUnread()
            for account in shown {
                let tree = Self.tree(try store.folders(account.id).map { Self.counted($0, less: staged) })
                favorites += tree.map(\.folder).filter(\.isFavorite)
                perAccount.append(DrawerSection(kind: .account(account.id), folders: tree.map(\.folder)))
                for node in tree {
                    depths[node.folder.id] = node.depth
                    if let parent = node.parent {
                        parents.insert(parent)
                        parentOf[node.folder.id] = parent
                    }
                }
            }
            trees = perAccount
            self.depths = depths
            self.parents = parents
            self.parentOf = parentOf
            sections = [DrawerSection(kind: .favorites, folders: favorites)]
            showUnfolded()
            failed = false
        } catch {
            failed = true
        }
    }

    /// Makes exactly these folders the favourites of the accounts in view; the others in view stop being.
    public func setFavorites(_ ids: Set<FolderID>) {
        var broke = false
        do {
            for section in trees {
                for folder in section.folders where folder.isFavorite != ids.contains(folder.id) {
                    try store.setFavorite(folder.id, ids.contains(folder.id))
                }
            }
        } catch {
            broke = true
        }
        reload()
        if broke { failed = true }
    }

    /// The account sections from the trees, without what lies under a folded folder.
    private func showUnfolded() {
        let favorites = sections.first { $0.kind == .favorites } ?? DrawerSection(kind: .favorites, folders: [])
        sections = [favorites] + trees.map { section in
            var shown: [Folder] = []
            var hiddenBelow: Int?
            for folder in section.folders {
                let depth = depths[folder.id] ?? 0
                if let limit = hiddenBelow {
                    if depth > limit { continue }
                    hiddenBelow = nil
                }
                shown.append(folder)
                if isCollapsed(folder) { hiddenBelow = depth }
            }
            return DrawerSection(kind: section.kind, folders: shown)
        }
    }

    /// The folders as a tree: the top in drawer order, each followed by its subfolders by name. A
    /// folder's parent is the nearest folder above it in its path; the Inbox is never one, so
    /// servers that keep every folder under it still show them at the top.
    static func tree(_ folders: [Folder]) -> [FolderNode] {
        let byPath = Dictionary(folders.map { ($0.path, $0) }) { first, _ in first }
        var children: [FolderID: [Folder]] = [:]
        var roots: [Folder] = []
        for folder in folders {
            if let parent = parent(of: folder, in: byPath) {
                children[parent.id, default: []].append(folder)
            } else {
                roots.append(folder)
            }
        }
        var nodes: [FolderNode] = []
        var stack = ordered(roots).reversed().map { FolderNode(folder: $0, depth: 0, parent: nil) }
        var seen: Set<FolderID> = []
        while let node = stack.popLast() {
            guard seen.insert(node.folder.id).inserted else { continue }
            nodes.append(node)
            let below = ordered(children[node.folder.id] ?? [])
            stack += below.reversed().map { FolderNode(folder: $0, depth: node.depth + 1, parent: node.folder.id) }
        }
        return nodes
    }

    private static func parent(of folder: Folder, in byPath: [String: Folder]) -> Folder? {
        guard let delimiter = folder.delimiter, !delimiter.isEmpty else { return nil }
        var path = Substring(folder.path)
        while let cut = path.range(of: delimiter, options: .backwards) {
            path = path[..<cut.lowerBound]
            if let found = byPath[String(path)], found.kind != .inbox, found.id != folder.id {
                return found
            }
        }
        return nil
    }

    static let kindOrder: [FolderKind] = [.inbox, .drafts, .sent, .archive, .trash, .junk, .other]

    /// System folders in a fixed order, then the rest by name.
    static func ordered(_ folders: [Folder]) -> [Folder] {
        folders.sorted { first, second in
            let one = kindOrder.firstIndex(of: first.kind) ?? kindOrder.count
            let two = kindOrder.firstIndex(of: second.kind) ?? kindOrder.count
            if one != two { return one < two }
            return first.name.localizedStandardCompare(second.name) == .orderedAscending
        }
    }
}

extension DrawerModel: PendingMailWatcher {
    func pendingMailChanged() {
        reload()
    }
}
