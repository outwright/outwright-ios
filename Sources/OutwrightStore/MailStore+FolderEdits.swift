// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
import GRDB
public import OutwrightModel

/// Folders the owner makes, renames, moves and deletes: changed here at once, and queued for the
/// server with the account's other changes.
extension MailStore {
    /// One folder's row, as the edits need it.
    struct EditedFolder {
        var id: Int64
        var account: String
        var path: String
        var kind: String
        var delimiter: String?
        var isFavorite = false
        var uidValidity: UInt32 = 0
    }

    /// Makes a folder under `parent`, or at the top under `prefix` (the account's namespace). `name`
    /// is what the owner typed; `wire` is the same name as the server writes it (modified UTF-7).
    public func createFolder(
        named name: String, wire: String, in parent: FolderID?, account: AccountID, prefix: String
    ) throws(StoreError) -> FolderID {
        let made: Int64 = try write { database in
            let key = account.raw.uuidString
            try Self.refuseWhileWaiting(database, account: key)
            let (base, delimiter) = try Self.place(database, account: key, parent: parent, prefix: prefix)
            let name = try Self.checked(name, wire: wire, delimiter: delimiter)
            let path = base + wire
            try Self.refuseTaken(database, account: key, path: path)
            try database.execute(
                sql: """
                    INSERT INTO folder (accountId, path, name, kind, uidValidity, isFavorite, delimiter)
                    VALUES (?, ?, ?, ?, 0, 0, ?)
                    """, arguments: [key, path, name, FolderKind.other.rawValue, delimiter])
            let id = database.lastInsertedRowID
            try Self.queueFolder(database, .createFolder(FolderID(raw: id)), account: key, folder: id)
            return id
        }
        announceQueued(account)
        return FolderID(raw: made)
    }

    /// Renames a folder, or moves it under `parent` (nil: the top, under `prefix`); its subfolders
    /// and messages go with it, and it keeps its id and favourite mark.
    public func renameFolder(
        _ id: FolderID, to name: String, wire: String, under parent: FolderID?, prefix: String
    ) throws(StoreError) {
        let account: String? = try write { database in
            let folder = try Self.editable(database, id)
            try Self.refuseWhileWaiting(database, account: folder.account)
            if let parent, try Self.subtree(database, folder).contains(where: { $0.id == parent.raw }) {
                throw StoreError.folderNameInvalid
            }
            let (base, delimiter) = try Self.place(database, account: folder.account, parent: parent, prefix: prefix)
            // A move keeps the server's own name as it is: only a new name is checked.
            let kept = folder.delimiter.flatMap { folder.path.components(separatedBy: $0).last } ?? folder.path
            let name = wire == kept && !wire.contains(delimiter)
                ? name : try Self.checked(name, wire: wire, delimiter: delimiter)
            let path = base + wire
            guard path != folder.path else { return nil }
            try Self.refuseTaken(database, account: folder.account, path: path)
            try Self.repath(database, folder, to: path, delimiter: delimiter)
            try database.execute(sql: "UPDATE folder SET name = ? WHERE id = ?", arguments: [name, folder.id])
            try Self.queueFolder(
                database, .renameFolder(id, from: folder.path, to: path), account: folder.account, folder: folder.id)
            return folder.account
        }
        if let account, let uuid = UUID(uuidString: account) {
            announceQueued(AccountID(raw: uuid))
        }
    }

    /// Deletes a folder with its subfolders and the messages in them, and every change queued
    /// for those messages. A message moved out of them before keeps its move.
    public func deleteFolder(_ id: FolderID) throws(StoreError) {
        let account: String = try write { database in
            let folder = try Self.editable(database, id)
            try Self.refuseWhileWaiting(database, account: folder.account)
            let tree = try Self.subtree(database, folder)
            let ids = tree.map(\.id)
            let marks = databaseList(ids)
            try Self.dropActions(database, onMessagesIn: ids)
            try database.execute(
                sql: "DELETE FROM message_fts WHERE rowid IN (SELECT id FROM message WHERE folderId IN (\(marks)))",
                arguments: StatementArguments(ids))
            try database.execute(
                sql: "DELETE FROM message WHERE folderId IN (\(marks))", arguments: StatementArguments(ids))
            try database.execute(sql: "DELETE FROM folder WHERE id IN (\(marks))", arguments: StatementArguments(ids))
            let paths = tree.map {
                FolderPath(
                    id: FolderID(raw: $0.id), path: $0.path, isFavorite: $0.isFavorite, uidValidity: $0.uidValidity)
            }
            try Self.queueFolder(database, .deleteFolder(id, paths: paths), account: folder.account, folder: folder.id)
            return folder.account
        }
        if let uuid = UUID(uuidString: account) {
            announceQueued(AccountID(raw: uuid))
        }
    }

    /// The server refused to make a folder made here: it goes, and every message moved into it
    /// goes back where it was, its move no longer queued.
    /// `completing`: the refused change itself, done with in the same step.
    /// `telling`: kept for the owner in the same step.
    public func undoFolderCreate(
        _ id: FolderID, completing action: Int64? = nil, telling refusal: FolderRefusal? = nil
    ) throws(StoreError) {
        try write { database in
            if let action {
                try database.execute(sql: "DELETE FROM pending_action WHERE id = ?", arguments: [action])
            }
            if let refusal, let folder = try Self.folderRow(database, id.raw) {
                try Self.tell(database, refusal, account: folder.account)
            }
            // Where each message filed into the folder really is on the server.
            try Self.repointQueued(database, filedInto: id)
            for row in try Row.fetchAll(
                database,
                // Newest first: a message filed in more than once goes back to where its last move took it from.
                sql: "SELECT id, action, sourceFolderId, sourceUid FROM pending_action ORDER BY id DESC") {
                guard let pending = row["id"] as Int64?, let data = row["action"] as Data?,
                      case let .moveTo(message, destination)? = try? JSONDecoder().decode(MailAction.self, from: data),
                      destination == id
                else { continue }
                if let source = row["sourceFolderId"] as Int64?,
                   try Int64.fetchOne(database, sql: "SELECT id FROM folder WHERE id = ?", arguments: [source]) != nil {
                    try database.execute(
                        sql: "UPDATE message SET folderId = ?, uid = ? WHERE id = ? AND folderId = ?",
                        arguments: [source, (row["sourceUid"] as Int64?) ?? 0, message.raw, id.raw])
                }
                try database.execute(sql: "DELETE FROM pending_action WHERE id = ?", arguments: [pending])
            }
            try database.execute(
                sql: "DELETE FROM message_fts WHERE rowid IN (SELECT id FROM message WHERE folderId = ?)",
                arguments: [id.raw])
            try database.execute(sql: "DELETE FROM folder WHERE id = ?", arguments: [id.raw])
        }
    }

    /// The server refused a rename: the folder and its subfolders take their paths back, and the
    /// folder its old `name`.
    public func undoFolderRename(
        _ id: FolderID, from: String, to: String, name: String, completing action: Int64? = nil,
        telling refusal: FolderRefusal? = nil
    ) throws(StoreError) {
        try write { database in
            if let action {
                try database.execute(sql: "DELETE FROM pending_action WHERE id = ?", arguments: [action])
            }
            if let refusal, let folder = try Self.folderRow(database, id.raw) {
                try Self.tell(database, refusal, account: folder.account)
            }
            guard let folder = try Self.folderRow(database, id.raw), folder.path == to else { return }
            try Self.repath(database, folder, to: from, delimiter: folder.delimiter)
            try database.execute(sql: "UPDATE folder SET name = ? WHERE id = ?", arguments: [name, id.raw])
        }
    }

    // MARK: - Helpers

    /// Changes queued for messages filed into a folder the server refused act where each message
    /// really is: oldest first, each against where the message was at that point.
    private static func repointQueued(_ database: Database, filedInto id: FolderID) throws {
        // Oldest first: a message filed into the folder, and each change queued while it was
        // there acts where the message really was at that point.
        var origins: [Int64: (folder: Int64, uid: Int64)] = [:]
        var rescued: [Int64: (folder: Int64, uid: Int64)] = [:]
        for row in try Row.fetchAll(
            database, sql: "SELECT id, action, sourceFolderId, sourceUid FROM pending_action ORDER BY id") {
            guard let pending = row["id"] as Int64?, let data = row["action"] as Data?,
                  let action = try? JSONDecoder().decode(MailAction.self, from: data),
                  let target = action.target
            else { continue }
            let source = row["sourceFolderId"] as Int64?
            if source == id.raw, let origin = origins[target.raw], case .delete = action,
               try String.fetchOne(
                database, sql: "SELECT kind FROM folder WHERE id = ?", arguments: [origin.folder])
                == FolderKind.trash.rawValue {
                // Deleted from the folder after being taken out of Trash: on the server it never
                // left Trash, and deleting it there would be for good. It stays in Trash.
                try database.execute(sql: "DELETE FROM pending_action WHERE id = ?", arguments: [pending])
                try database.execute(
                    sql: "UPDATE message SET folderId = ?, uid = ? WHERE id = ?",
                    arguments: [origin.folder, origin.uid, target.raw])
                rescued[target.raw] = origin
            } else if let back = rescued[target.raw], source == back.folder,
                      (row["sourceUid"] as Int64?) ?? 0 == 0 {
                // A change queued for it in Trash afterwards finds it by its uid there.
                try database.execute(
                    sql: "UPDATE pending_action SET sourceUid = ? WHERE id = ?", arguments: [back.uid, pending])
            } else if source == id.raw, let origin = origins[target.raw] {
                try database.execute(
                    sql: "UPDATE pending_action SET sourceFolderId = ?, sourceUid = ? WHERE id = ?",
                    arguments: [origin.folder, origin.uid, pending])
            } else if case let .moveTo(_, destination) = action, destination == id, let source {
                origins[target.raw] = (source, (row["sourceUid"] as Int64?) ?? 0)
            }
        }
    }

    static func waitingAccounts(_ database: Database) throws -> Set<AccountID> {
        Set(try Row.fetchAll(database, sql: "SELECT accountId, action FROM pending_action").compactMap { row in
            guard let data = row["action"] as Data?,
                  (try? JSONDecoder().decode(MailAction.self, from: data))?.target == nil,
                  let account = (row["accountId"] as String?).flatMap(UUID.init(uuidString:))
            else { return nil }
            return AccountID(raw: account)
        })
    }

    static func waitingFolderChange(_ database: Database, account: String) throws -> Bool {
        try Row.fetchAll(
            database, sql: "SELECT action FROM pending_action WHERE accountId = ?", arguments: [account]
        ).contains { row in
            guard let data = row["action"] as Data?,
                  let action = try? JSONDecoder().decode(MailAction.self, from: data)
            else { return false }
            return action.target == nil
        }
    }

    private static func refuseWhileWaiting(_ database: Database, account: String) throws {
        if try waitingFolderChange(database, account: account) { throw StoreError.folderChangeWaiting }
    }

    static func folderRow(_ database: Database, _ id: Int64) throws -> EditedFolder? {
        guard let row = try Row.fetchOne(
            database,
            sql: "SELECT id, accountId, path, kind, delimiter, isFavorite, uidValidity FROM folder WHERE id = ?",
            arguments: [id]),
            let account = row["accountId"] as String?, let path = row["path"] as String?
        else { return nil }
        return EditedFolder(
            id: id, account: account, path: path, kind: (row["kind"] as String?) ?? "",
            delimiter: row["delimiter"] as String?, isFavorite: (row["isFavorite"] as Bool?) ?? false,
            uidValidity: UInt32(clamping: (row["uidValidity"] as Int64?) ?? 0))
    }

    /// A folder the owner may rename, move or delete: neither it nor a folder under it is one the
    /// app relies on.
    private static func editable(_ database: Database, _ id: FolderID) throws -> EditedFolder {
        guard let folder = try folderRow(database, id.raw) else { throw StoreError.noSuchFolder }
        guard try subtree(database, folder).allSatisfy({ $0.kind == FolderKind.other.rawValue }) else {
            throw StoreError.folderProtected
        }
        return folder
    }

    /// The folder and every folder under it, the folder first.
    private static func subtree(_ database: Database, _ folder: EditedFolder) throws -> [EditedFolder] {
        guard let delimiter = folder.delimiter, !delimiter.isEmpty else { return [folder] }
        let rows = try Row.fetchAll(
            database, sql: "SELECT id FROM folder WHERE accountId = ? AND substr(path, 1, ?) = ? ORDER BY path",
            arguments: [folder.account, (folder.path + delimiter).unicodeScalars.count, folder.path + delimiter])
        let under = try rows.compactMap { row in try (row["id"] as Int64?).flatMap { try folderRow(database, $0) } }
        return [folder] + under
    }

    /// Where a new name goes: its parent's path and delimiter, or the prefix and the account's own.
    private static func place(
        _ database: Database, account: String, parent: FolderID?, prefix: String
    ) throws -> (base: String, delimiter: String) {
        if let parent {
            guard let folder = try folderRow(database, parent.raw), folder.account == account else {
                throw StoreError.noSuchFolder
            }
            let delimiter = try folder.delimiter ?? accountDelimiter(database, account)
            return (folder.path + delimiter, delimiter)
        }
        return (prefix, try accountDelimiter(database, account))
    }

    /// The Inbox's delimiter, else any folder's, else `/`.
    private static func accountDelimiter(_ database: Database, _ account: String) throws -> String {
        try String.fetchOne(
            database,
            sql: """
                SELECT delimiter FROM folder WHERE accountId = ? AND delimiter IS NOT NULL AND delimiter != ''
                ORDER BY kind = 'inbox' DESC, id LIMIT 1
                """, arguments: [account]) ?? "/"
    }

    private static func checked(_ name: String, wire: String, delimiter: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // The wire form is the trimmed name's: a space around it would reach the server.
        guard !trimmed.isEmpty, !wire.isEmpty, wire == wire.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.contains(delimiter), !wire.contains(delimiter),
              !trimmed.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
        else { throw StoreError.folderNameInvalid }
        return trimmed
    }

    private static func refuseTaken(_ database: Database, account: String, path: String) throws {
        let taken = try Int64.fetchOne(
            database,
            sql: """
                SELECT id FROM folder WHERE accountId = ?
                    AND (path = ? OR (upper(?) = 'INBOX' AND upper(path) = 'INBOX'))
                """,
            arguments: [account, path, path])
        if taken != nil { throw StoreError.folderNameTaken }
    }

    /// The folder takes `path`, and each folder under it the same start.
    private static func repath(
        _ database: Database, _ folder: EditedFolder, to path: String, delimiter: String?
    ) throws {
        if let old = folder.delimiter, !old.isEmpty {
            let start = folder.path + old
            try database.execute(
                sql: """
                    UPDATE folder SET path = ? || substr(path, ?) WHERE accountId = ? AND substr(path, 1, ?) = ?
                    """,
                arguments: [
                    path + old, start.unicodeScalars.count + 1, folder.account, start.unicodeScalars.count, start
                ])
        }
        try database.execute(
            sql: "UPDATE folder SET path = ?, delimiter = coalesce(?, delimiter) WHERE id = ?",
            arguments: [path, delimiter, folder.id])
    }

    /// Removes every queued change to a message in one of `folders`.
    private static func dropActions(_ database: Database, onMessagesIn folders: [Int64]) throws {
        let marks = databaseList(folders)
        let held = Set(try Int64.fetchAll(
            database, sql: "SELECT id FROM message WHERE folderId IN (\(marks))",
            arguments: StatementArguments(folders)))
        guard !held.isEmpty else { return }
        for row in try Row.fetchAll(database, sql: "SELECT id, action FROM pending_action") {
            guard let id = row["id"] as Int64?, let data = row["action"] as Data?,
                  let target = (try? JSONDecoder().decode(MailAction.self, from: data))?.target,
                  held.contains(target.raw)
            else { continue }
            try database.execute(sql: "DELETE FROM pending_action WHERE id = ?", arguments: [id])
        }
    }

    private static func queueFolder(_ database: Database, _ action: MailAction, account: String, folder: Int64) throws {
        try database.execute(
            sql: "INSERT INTO pending_action (accountId, action, sourceFolderId, sourceUid) VALUES (?, ?, ?, 0)",
            arguments: [account, try JSONEncoder().encode(action), folder])
    }
}

/// `?, ?, ?` for `values`.
private func databaseList(_ values: [Int64]) -> String {
    Array(repeating: "?", count: values.count).joined(separator: ", ")
}
