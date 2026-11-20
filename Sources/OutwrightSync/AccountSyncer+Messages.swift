// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightIMAP
import OutwrightModel
import OutwrightStore

/// Folders and the messages in them.
extension AccountSyncer {
    // MARK: - Folders

    @discardableResult
    func refreshFolders(_ client: IMAPClient) async throws(SyncError) -> [IMAPFolder] {
        let listed = try await imap { try await client.listFolders() }
        // Every server has an Inbox: a list without one is broken, and nothing is changed for it.
        guard listed.contains(where: { $0.role == .inbox }) else {
            throw .imap(.protocolViolation)
        }
        let known = try stored { try store.folders(account.id) }
        let byPath = Dictionary(known.map { ($0.path, $0) }) { first, _ in first }
        var folders = listed.filter(\.selectable).prefix(Self.maxFolders).map { folder in
            Folder(
                id: FolderID(raw: 0), accountID: account.id, path: folder.path, name: folder.name,
                kind: FolderKind(rawValue: folder.role.rawValue) ?? .other,
                uidValidity: byPath[folder.path]?.uidValidity ?? 0, unread: 0,
                isFavorite: byPath[folder.path]?.isFavorite ?? false, delimiter: folder.delimiter)
        }
        // A kind the account lacks gets a folder here, made on the server when first used, where
        // the server keeps its others.
        let prefix = try await imap { try await client.personalNamespace() }?.prefix ?? Self.madePrefix(listed)
        folderPrefix = prefix
        if try stored({ try store.folderPrefix(account.id) }) != prefix {
            try stored { try store.setFolderPrefix(prefix, for: account.id) }
        }
        let listedPaths = Set(listed.map(\.path))
        for (kind, name) in Self.madeWhenMissing {
            let serversOwn = folders.first { $0.kind == kind }
            let path = serversOwn?.path ?? prefix + name
            // One made here before, at another place and still not on the server, gives way with
            // what waits on it: to the server's own folder of that kind, or to the right place.
            // Only a path this app makes counts: a server's own folder left out of one LIST stays.
            let madePaths: Set<String> = [name, "INBOX.\(name)", "INBOX/\(name)"]
            if let earlier = known.first(where: {
                $0.kind == kind && $0.uidValidity == 0 && $0.path != path && madePaths.contains($0.path)
                    && !listedPaths.contains($0.path)
            }) {
                try stored { try store.adoptFolder(earlier.id, as: path) }
            }
            if serversOwn == nil {
                folders.append(Folder(
                    id: FolderID(raw: 0), accountID: account.id, path: path, name: name, kind: kind, uidValidity: 0,
                    unread: 0, isFavorite: byPath[path]?.isFavorite ?? false))
            }
        }
        // Read now, right before the queue: a change made while the server was asked is in both. A
        // rename landing between the two reads is in the queue only, and keeps the server's name a sync.
        let current = try stored { try store.folders(account.id) }
        let queued = try stored { try store.pendingActions() }.filter { $0.accountID == account.id }.map(\.action)
        folders = FolderQueue.project(folders, known: current, queued: queued)
        try stored { try store.replaceFolders(folders, for: account.id) }
        return listed
    }

    /// True while the folder's own creation, or a rename of it or above it, is still queued: the
    /// server doesn't have it at its path yet.
    func waitsForFolderChange(_ folder: Folder) throws(SyncError) -> Bool {
        let queued = try stored { try store.pendingActions() }.filter { $0.accountID == account.id }.map(\.action)
        return FolderQueue.waits(folder, queued: queued)
    }

    /// `INBOX.` (with the server's delimiter) when every folder but the Inbox is under it, as on
    /// servers that refuse folders anywhere else; else nothing.
    static func madePrefix(_ listed: [IMAPFolder]) -> String {
        guard let delimiter = listed.first(where: { $0.role == .inbox })?.delimiter else {
            return ""
        }
        let prefix = "INBOX" + delimiter
        let others = listed.filter { $0.role != .inbox }
        guard !others.isEmpty, others.allSatisfy({ $0.path.uppercased().hasPrefix(prefix.uppercased()) }) else {
            return ""
        }
        return prefix
    }

    // MARK: - Messages

    /// New mail of a folder still to be fetched: the next batch is a turn of its own.
    struct NewMail {
        var folder: Folder
        var uidValidity: UInt32
        var uids: [UInt32]
        var builder: RowBuilder
    }

    /// Selects the folder, brings the flags held in step (by mod-sequence where the server keeps
    /// them) and fetches the first batch of new mail; returns what is left of it.
    func syncMessages(_ id: FolderID, _ client: IMAPClient) async throws(SyncError) -> NewMail? {
        guard let folder = try stored({ try store.folders(account.id) }).first(where: { $0.id == id }) else {
            throw .store("noSuchFolder")
        }
        if try waitsForFolderChange(folder) { return nil }
        let remembered = try stored { try store.highestModSeq(id) }
        let held = try stored { try store.folderIndex(id) }
        let point = resyncPoint(folder, remembered: remembered, held: held)
        let status: FolderStatus
        let changes: ResyncChanges?
        do {
            (status, changes) = try await client.select(folder.path, from: point)
        } catch {
            // A local archive the server has not been asked to make yet: nothing to fetch.
            switch error {
            case .folderMissing, .no:
                if folder.uidValidity == 0 {
                    return nil
                }
            default:
                break
            }
            if point != nil {
                // An answer to the point that failed would fail again: the next sync goes in full.
                try? store.setHighestModSeq(id, nil)
            }
            throw .imap(error)
        }
        if folder.uidValidity == 0 {
            try adoptUIDValidity(id, status.uidValidity)
        }
        let renumbered = folder.uidValidity != 0 && status.uidValidity != folder.uidValidity
        if renumbered {
            try stored { try store.resetFolder(id, uidValidity: status.uidValidity) }
        }
        // The same snapshot the point was made from, unless the reset emptied it.
        let local = renumbered ? try stored { try store.folderIndex(id) } : held
        let since = Resync(
            remembered: renumbered ? nil : remembered,
            asked: changes != nil, status: status, changes: changes ?? .none)
        try await reconcile(id, local, client, since)
        let inWindow = try await uidsToFetch(id, local, client)
        let fresh = Set(inWindow).subtracting(try notNew(id, local)).sorted()
        guard !fresh.isEmpty else {
            return nil
        }
        let builder = RowBuilder(
            account: account, folder: folder, store: store,
            correspondents: try stored { try store.knownSenders(account.id) },
            overrides: try stored { try store.overrides() })
        let mail = NewMail(folder: folder, uidValidity: status.uidValidity, uids: fresh, builder: builder)
        return try await fetchBatch(mail, client, selected: true)
    }

    /// The server's uids within the window; and where the owner has looked further back (older
    /// mail fetched), a message that came into the folder since (moved here), which has a uid above
    /// every one held. A folder held to its start asks for no date at all.
    func uidsToFetch(_ id: FolderID, _ local: [UInt32: MessageID], _ client: IMAPClient) async throws(SyncError)
        -> [UInt32] {
        let windowStart = now().addingTimeInterval(-Self.window)
        var found = try await imap { try await client.uids(since: windowStart) }
        if let heldSince = try stored({ try store.heldSince(id) }), heldSince < windowStart {
            let since = heldSince.timeIntervalSince1970 > 0 ? heldSince : nil
            let highest = local.keys.max() ?? 0
            found += try await imap { try await client.uids(since: since, above: highest) }
        }
        return found
    }

    /// First look at a folder known only here (the Archive made for a move): what was moved into
    /// it was numbered by this server, so it stays, under the server's UIDVALIDITY.
    func adoptUIDValidity(_ id: FolderID, _ uidValidity: UInt32) throws(SyncError) {
        let all = try stored { try store.folders(account.id) }.map { known in
            var known = known
            if known.id == id {
                known.uidValidity = uidValidity
            }
            return known
        }
        try stored { try store.replaceFolders(all, for: account.id) }
    }

    /// The uids of the folder not to fetch as new: those held here, and those the owner moved
    /// away whose move the server has still to hear of.
    func notNew(_ folder: FolderID, _ local: [UInt32: MessageID]) throws(SyncError) -> Set<UInt32> {
        Set(local.keys).union(try stored { try store.movedAwayUIDs(folder) })
    }

    /// One batch of new mail; returns what is left. Between batches anything may have been done
    /// on the connection, so the folder is selected again, and a renumbered folder ends the fetch
    /// (the next synchronisation starts it over).
    func fetchBatch(_ mail: NewMail, _ client: IMAPClient, selected: Bool = false) async throws(SyncError)
        -> NewMail? {
        if !selected {
            let status = try await imap { try await client.select(mail.folder.path) }
            guard status.uidValidity == mail.uidValidity else {
                return nil
            }
        }
        var mail = mail
        let part = Array(mail.uids.prefix(Self.batch))
        let summaries = try await imap { try await client.summaries(uids: part) }
        let rows = summaries.filter { !$0.flags.contains("\\Deleted") }.map { mail.builder.row($0) }
        _ = try stored { try store.upsert(rows) }
        mail.uids.removeFirst(part.count)
        return mail.uids.isEmpty ? nil : mail
    }

    /// Flags of the messages held, as the server has them now; those it no longer has (or has
    /// marked deleted) go. Asks for every held message's flags.
    func fullReconcile(
        _ folder: FolderID, _ local: [UInt32: MessageID], _ client: IMAPClient
    ) async throws(SyncError) {
        guard !local.isEmpty else {
            return
        }
        let present = try await imap { try await client.flags(uids: Array(local.keys)) }
        let gone = local.keys.filter { present[$0] == nil }
        if !gone.isEmpty {
            try stored { try store.removeMessages(folder: folder, uids: gone) }
        }
        try applyFlags(present, held: local, folder: folder)
    }
}
