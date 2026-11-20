// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightIMAP
import OutwrightModel
import OutwrightStore

/// The owner's folder changes, carried to the server in order with the other changes.
extension ActionRunner {
    /// The folders as the server has them before `queue` runs: a rename still queued is undone
    /// here, and a folder whose delete is queued is back, so a change queued before either finds
    /// the server's folder.
    mutating func rewind(for queue: [PendingAction]) {
        // A folder made after this runner read the folders (a follow-up run) is read now, at its
        // path in the store; the walk below takes it back through the renames queued after it.
        let missing = queue.compactMap { pending -> FolderID? in
            guard case let .createFolder(id) = pending.action, folder(id: id) == nil else { return nil }
            return id
        }
        if !missing.isEmpty, let stored = try? store.folders(account.id) {
            folders += stored.filter { missing.contains($0.id) }
        }
        // An account has one folder change queued at most: a rename is undone here, a deleted
        // folder is back.
        for pending in queue.reversed() {
            switch pending.action {
            case let .renameFolder(_, from, to):
                repath(from: to, to: from)
            case let .deleteFolder(_, paths):
                // Its number unknown (0), so a uid queued for it is taken as it is.
                for held in paths where !folders.contains(where: { $0.id == held.id }) {
                    folders.append(Folder(
                        id: held.id, accountID: account.id, path: held.path, name: held.path, kind: .other,
                        uidValidity: held.uidValidity ?? 0, unread: 0, isFavorite: false,
                        delimiter: folders.first { $0.kind == .inbox }?.delimiter))
                }
            default:
                continue
            }
        }
    }

    /// A refused folder change is kept in the store for the owner; it is told only when nothing
    /// else in the run went wrong. One that waits counts as any other error.
    mutating func runFolderAction(
        _ pending: PendingAction, refusal: inout SyncError?, folderRefusal: inout SyncError?
    ) async throws(SyncError) {
        switch try await runFolderOrWait(pending) {
        case let refused? where refused.isFolderRefusal: folderRefusal = folderRefusal ?? refused
        case let other?: refusal = refusal ?? other
        case nil: break
        }
    }

    /// Runs the account's folder change. One the server can't take now waits, and so does what
    /// acts in that folder; the rest of the run goes on. After `maxAttempts` runs it is given up.
    mutating func runFolderOrWait(_ pending: PendingAction) async throws(SyncError) -> SyncError? {
        do {
            return try await runFolder(pending)
        } catch {
            if error.breaksConnection {
                throw error
            }
            // One the server keeps putting off is given up after as many runs as a message change
            // that can't be found, and undone: the account's folder editing is never locked for good.
            if try stored({ try store.noteFolderTry(pending.id, at: now) }) >= Self.maxAttempts {
                return try refuse(pending, gaveUp: true)
            }
            markStuck(pending.action)
            return error
        }
    }

    /// The change's folder and every folder under it wait, and so does what acts in them.
    private mutating func markStuck(_ action: MailAction) {
        guard let id = Self.folderID(of: action) else { return }
        folderRun.stuck.insert(id)
        guard let top = folder(id: id) else { return }
        for each in folders
        where FolderQueue.remainder(of: each.path, under: top.path, delimiter: each.delimiter) != nil {
            folderRun.stuck.insert(each.id)
        }
    }

    /// True when a message change acts in a folder whose change waits.
    func waitsOnStuckFolder(_ pending: PendingAction) -> Bool {
        guard !folderRun.stuck.isEmpty else {
            return false
        }
        if let source = pending.sourceFolderID, folderRun.stuck.contains(source) {
            return true
        }
        switch pending.action {
        case let .moveTo(_, destination):
            return folderRun.stuck.contains(destination)
        case let .move(_, kind):
            return folder(kind).map { folderRun.stuck.contains($0.id) } ?? false
        default:
            return false
        }
    }

    static func folderID(of action: MailAction) -> FolderID? {
        switch action {
        case let .createFolder(id), let .renameFolder(id, _, _), let .deleteFolder(id, _): id
        default: nil
        }
    }

    /// Runs one folder change. A refusal for good is undone and completed (`refuse`) and returned;
    /// any other failure is thrown, the change left queued.
    mutating func runFolder(_ pending: PendingAction) async throws(SyncError) -> SyncError? {
        // A move out of the folder was given up: its message may still be in there, so the
        // folder isn't deleted; it comes back on the phone.
        if case let .deleteFolder(_, paths) = pending.action,
           paths.contains(where: { folderRun.givenUpIn.contains($0.id) }) {
            return try refuse(pending, gaveUp: true)
        }
        do {
            try await performFolder(pending)
        } catch {
            guard case let .imap(refusal) = error, Self.isForGood(refusal) else {
                throw error
            }
            return try refuse(pending, gaveUp: false)
        }
        try stored { try store.completeAction(pending.id) }
        return nil
    }

    /// Undoes a change the server won't take (`gaveUp`: never took, after several tries) and
    /// completes it, in one step, and keeps it for the owner to see; returns it as an error.
    mutating func refuse(_ pending: PendingAction, gaveUp: Bool) throws(SyncError) -> SyncError {
        let name = try undo(pending, gaveUp: gaveUp)
        if case .createFolder = pending.action {
            try repoint(after: pending)
        }
        return .folderChangeRefused(name)
    }

    private static func isForGood(_ error: IMAPError) -> Bool {
        switch error {
        case .no, .bad, .folderMissing: true
        default: false
        }
    }

    private mutating func performFolder(_ pending: PendingAction) async throws(SyncError) {
        switch pending.action {
        case let .createFolder(id):
            // Made after this runner read the folders: read it now.
            if folder(id: id) == nil,
               let made = try stored({ try store.folders(account.id) }).first(where: { $0.id == id }) {
                folders.append(made)
            }
            guard let folder = folder(id: id) else {
                return
            }
            try await ensureOnServer(folder)
            try await subscription(folder.path, on: true)
        case let .renameFolder(_, from, to):
            try await renameOnServer(from: from, to: to)
        case let .deleteFolder(_, paths):
            guard let top = paths.first else {
                return
            }
            // A change queued earlier for mail in it (a move out that failed) goes first; the
            // folder waits for it.
            let doomed = Set(paths.map(\.id))
            let earlier = try stored { try store.pendingActions() }.contains { other in
                other.id < pending.id && other.accountID == account.id
                    && other.sourceFolderID.map(doomed.contains) == true
            }
            if earlier {
                throw .imap(.unavailable("A change to mail in the folder waits"))
            }
            try await deleteOnServer(top.path, held: paths)
            let ids = Set(paths.map(\.id))
            folders.removeAll { ids.contains($0.id) }
        default:
            return
        }
    }

    private mutating func renameOnServer(from: String, to: String) async throws(SyncError) {
        let paths = try await knownServerPaths()
        // Done before, its answer lost (a dropped connection): only the subscriptions are left.
        let done = !paths.contains(from) && paths.contains(to)
        // RENAME leaves subscriptions behind (RFC 3501): the subscribed ones under the folder
        // follow it. Best effort: without the list, only the folder itself is subscribed.
        let subscribed = try await subscribedPaths()
            .filter { FolderQueue.remainder(of: $0, under: from, delimiter: delimiter) != nil }
            .prefix(AccountSyncer.maxFolders)
        if !done {
            try await leaveSelected()
            try await imap { try await client.rename(from: from, to: to) }
        }
        repath(from: from, to: to)
        try await subscription(to, on: true)
        for old in subscribed {
            let rest = FolderQueue.remainder(of: old, under: from, delimiter: delimiter) ?? ""
            try await subscription(old, on: false)
            try await subscription(to + rest, on: true)
        }
        try await subscription(from, on: false)
    }

    /// Leaves whatever the connection has selected (an earlier sync's folder too): UNSELECT, else
    /// the Inbox selected. A server that won't rename or delete a folder in use (`[INUSE]`) is then
    /// not asked to. The next change selects its own folder again, renumbering checked.
    private mutating func leaveSelected() async throws(SyncError) {
        // Whatever happens next, the connection no longer has the runner's folder selected.
        selected = nil
        if try await !imap({ try await client.leaveSelected() }) {
            do {
                _ = try await client.select("INBOX")
            } catch {
                // Not the folder change refused: it waits for the next run.
                let broken = SyncError.imap(error).breaksConnection
                throw broken ? .imap(error) : .imap(.unavailable("The Inbox can't be selected"))
            }
        }
        selected = nil
    }

    /// The server's subscriptions; none when it won't say (a broken connection still throws).
    private func subscribedPaths() async throws(SyncError) -> Set<String> {
        do {
            return try await client.subscribedFolders()
        } catch {
            if SyncError.imap(error).breaksConnection {
                throw .imap(error)
            }
            return []
        }
    }

    /// Every folder the server has at or under `top`, deepest first, unsubscribed and deleted.
    private mutating func deleteOnServer(_ top: String, held: [FolderPath]) async throws(SyncError) {
        let listed = try await imap { try await client.listFolders() }
        // What the server no longer has (deleted in an earlier run, or by another client) is gone.
        let present = Set(listed.map(\.path))
        folderRun.deleted.formUnion(held.map(\.path).filter { !present.contains($0) })
        let doomed = listed.filter { FolderQueue.remainder(of: $0.path, under: top, delimiter: $0.delimiter) != nil }
            .prefix(AccountSyncer.maxFolders)
            .sorted { $0.path.utf8.count > $1.path.utf8.count }
        try await leaveSelected()
        for folder in doomed {
            try await subscription(folder.path, on: false)
            try await imap { try await client.delete(folder.path) }
            folderRun.deleted.insert(folder.path)
            serverPaths?.remove(folder.path)
        }
    }

    /// Undoes the change here, completes it and keeps the refusal for the owner, in one step;
    /// returns the folder's name.
    mutating func undo(_ pending: PendingAction, gaveUp: Bool) throws(SyncError) -> String {
        let delimiter = delimiter
        switch pending.action {
        case let .createFolder(id):
            let name = folder(id: id)?.name ?? ""
            let told = FolderRefusal(name: name, gaveUp: gaveUp)
            try stored { try store.undoFolderCreate(id, completing: pending.id, telling: told) }
            folders.removeAll { $0.id == id }
            return name
        case let .renameFolder(id, from, to):
            let shown = Self.lastName(to, delimiter: delimiter)
            let told = FolderRefusal(name: shown, gaveUp: gaveUp)
            try stored {
                try store.undoFolderRename(
                    id, from: from, to: to, name: Self.lastName(from, delimiter: delimiter), completing: pending.id,
                    telling: told)
            }
            return shown
        case let .deleteFolder(_, paths):
            // Back as it was, so a change still queued for mail in it keeps finding it; what the
            // server already deleted stays gone.
            let name = paths.first.map { Self.lastName($0.path, delimiter: delimiter) } ?? ""
            let restored = paths.filter { !folderRun.deleted.contains($0.path) }.map { held in
                Folder(
                    id: held.id, accountID: account.id, path: held.path,
                    name: Self.lastName(held.path, delimiter: delimiter), kind: .other,
                    uidValidity: held.uidValidity ?? 0, unread: 0, isFavorite: held.isFavorite ?? false,
                    delimiter: delimiter)
            }
            let told = FolderRefusal(name: name, gaveUp: gaveUp)
            try stored { try store.restoreFolders(restored, of: account.id, completing: pending.id, telling: told) }
            return name
        default:
            try stored { try store.completeAction(pending.id) }
            return ""
        }
    }

    /// The decoded last part of a path.
    private static func lastName(_ path: String, delimiter: String?) -> String {
        let last = delimiter.flatMap { path.components(separatedBy: $0).last } ?? path
        return ModifiedUTF7.decode(last) ?? last
    }

    /// The account's hierarchy delimiter.
    var delimiter: String? {
        folders.first { $0.kind == .inbox }?.delimiter ?? folders.lazy.compactMap(\.delimiter).first
    }

    /// The folder at `from` and every folder under it take `to` in its place. A message moved
    /// earlier in the run goes along.
    private mutating func repath(from: String, to: String) {
        for (message, earlier) in moved {
            let delimiter = earlier.folder.delimiter
            if let rest = FolderQueue.remainder(of: earlier.folder.path, under: from, delimiter: delimiter) {
                moved[message]?.folder.path = to + rest
            }
        }
        for index in folders.indices {
            let delimiter = folders[index].delimiter
            if let rest = FolderQueue.remainder(of: folders[index].path, under: from, delimiter: delimiter) {
                folders[index].path = to + rest
            }
        }
        if let known = serverPaths {
            serverPaths = Set(known.map { path in
                FolderQueue.remainder(of: path, under: from, delimiter: delimiter).map { to + $0 } ?? path
            })
        }
    }

    private mutating func knownServerPaths() async throws(SyncError) -> Set<String> {
        if let serverPaths {
            return serverPaths
        }
        let paths = Set(try await imap { try await client.listFolders() }.map(\.path))
        serverPaths = paths
        return paths
    }

    /// Subscribes to `path` or not: a refusal is no failure, a broken connection is.
    private func subscription(_ path: String, on subscribed: Bool) async throws(SyncError) {
        do {
            if subscribed {
                try await client.subscribe(path)
            } else {
                try await client.unsubscribe(path)
            }
        } catch {
            if SyncError.imap(error).breaksConnection {
                throw .imap(error)
            }
        }
    }

    // MARK: - Folders

    func folder(_ kind: FolderKind) -> Folder? {
        folders.first { $0.kind == kind }
    }

    func folder(id: FolderID) -> Folder? {
        folders.first { $0.id == id }
    }

    mutating func select(_ folder: Folder) async throws(SyncError) {
        guard selected != folder.path else {
            return
        }
        selected = nil
        let status = try await imap { try await client.select(folder.path) }
        selected = folder.path
        if folder.uidValidity != 0, status.uidValidity != folder.uidValidity {
            renumbered.insert(folder.id)
        }
    }

    /// Makes a folder the server has not got yet (one made here for a kind the account lacked)
    /// before anything goes to it.
    mutating func ensureOnServer(_ folder: Folder) async throws(SyncError) {
        guard folder.uidValidity == 0 else {
            return
        }
        if serverPaths == nil {
            serverPaths = Set(try await imap { try await client.listFolders() }.map(\.path))
        }
        guard serverPaths?.contains(folder.path) == false else {
            return
        }
        // The path of a folder made here is already the server's form. One made meanwhile by
        // another client is no failure; any other refusal leaves the change queued.
        try await imap { try await client.create(path: folder.path) }
        serverPaths?.insert(folder.path)
    }
}
