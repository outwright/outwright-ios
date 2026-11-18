// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
import GRDB
public import OutwrightModel
import Synchronization

/// Errors carry no message text, address or SQL.
public enum StoreError: Error, Sendable {
    case noSuchMessage
    case noSuchFolder
    case noSuchContact
    case noSuchAddressBook
    case readOnlyAddressBook
    /// The contact's stored details can't be read: it is not edited until they are read again
    /// from the server's card.
    case unreadableContact
    /// The account has no CardDAV address: it keeps no contacts.
    case noCardDAV
    case noSuchCalendar
    case noSuchEvent
    /// The event or its calendar is not the owner's to change.
    case readOnly
    /// The event's stored series can't be read: it is not edited until read again from the server.
    case unreadableEvent
    /// The account has no CalDAV address: it keeps no calendars.
    case noCalDAV
    case database

    static func wrap(_ error: any Error) -> StoreError {
        (error as? StoreError) ?? .database
    }
}

/// Everything the app knows about mail, in one SQLite file (or in memory). The file is a pool:
/// reads go on while a synchronisation writes.
public final class MailStore: Sendable {
    let queue: any DatabaseWriter
    let queueListeners = Mutex<[UUID: AsyncStream<AccountID>.Continuation]>([:])
    let openings = Mutex<[any MessageOpening]>([])
    /// What opening applied: the migrations and how long they took (none for a current store).
    public let migrated: Migrated

    /// `nil` keeps the store in memory.
    public init(path: URL?) throws(StoreError) {
        do {
            let config = Self.configuration()
            if let path {
                queue = try DatabasePool(path: path.path, configuration: config)
            } else {
                queue = try DatabaseQueue(configuration: config)
            }
            migrated = try Self.migrate(queue)
        } catch {
            throw StoreError.wrap(error)
        }
    }

    /// The store at `path` only when the app has brought it up to date: it is never migrated
    /// here (the notification extension opens it, while the app may be migrating it).
    public init(current path: URL) throws(StoreError) {
        do {
            queue = try DatabasePool(path: path.path, configuration: Self.configuration())
            guard try queue.read({ try Schema.migrator().hasCompletedMigrations($0) }) else {
                throw StoreError.database
            }
            migrated = Migrated(names: [], seconds: 0)
        } catch {
            throw StoreError.wrap(error)
        }
    }

    func read<T>(_ body: (Database) throws -> T) throws(StoreError) -> T {
        do { return try queue.read(body) } catch { throw StoreError.wrap(error) }
    }

    func write<T>(_ body: (Database) throws -> T) throws(StoreError) -> T {
        do { return try queue.write(body) } catch { throw StoreError.wrap(error) }
    }

    // MARK: Accounts and folders

    public func save(_ account: Account) throws(StoreError) {
        try write { database in
            try database.execute(
                sql: """
                    INSERT INTO account (id, displayName, email, colorIndex, imapHost, imapPort, imapSecurity,
                        smtpHost, smtpPort, smtpSecurity, user, signature, sortOrder, cardDAV, cardDAVUnconfirmed,
                        savesContactsToPhone, cardDAVOff, calDAV, calDAVUnconfirmed, calDAVOff, auth, provider,
                        calendarVia, contactsVia)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET displayName = excluded.displayName,
                        email = excluded.email, colorIndex = excluded.colorIndex,
                        imapHost = excluded.imapHost, imapPort = excluded.imapPort,
                        imapSecurity = excluded.imapSecurity, smtpHost = excluded.smtpHost,
                        smtpPort = excluded.smtpPort, smtpSecurity = excluded.smtpSecurity,
                        user = excluded.user, signature = excluded.signature,
                        sortOrder = excluded.sortOrder, cardDAV = excluded.cardDAV,
                        cardDAVUnconfirmed = excluded.cardDAVUnconfirmed,
                        savesContactsToPhone = excluded.savesContactsToPhone, cardDAVOff = excluded.cardDAVOff,
                        calDAV = excluded.calDAV, calDAVUnconfirmed = excluded.calDAVUnconfirmed,
                        calDAVOff = excluded.calDAVOff, auth = excluded.auth, provider = excluded.provider,
                        calendarVia = excluded.calendarVia, contactsVia = excluded.contactsVia
                    """,
                arguments: [
                    account.id.raw.uuidString, account.displayName, account.email,
                    max(0, min(account.colorIndex, 7)),
                    account.imap.host, Int(account.imap.port), account.imap.security,
                    account.smtp.host, Int(account.smtp.port), account.smtp.security,
                    account.user, account.signature, account.sortOrder, account.cardDAV,
                    account.cardDAVUnconfirmed, account.savesContactsToPhone, account.cardDAVOff, account.calDAV,
                    account.calDAVUnconfirmed, account.calDAVOff, account.auth.rawValue, account.provider.raw,
                    account.calendarVia.rawValue, account.contactsVia.rawValue
                ])
        }
    }

    public func accounts() throws(StoreError) -> [Account] {
        try read { database in
            try Row.fetchAll(database, sql: "SELECT * FROM account ORDER BY sortOrder, email")
                .compactMap(Records.account)
        }
    }

    public func removeAccount(_ id: AccountID) throws(StoreError) {
        try write { database in
            try database.execute(
                sql: "DELETE FROM message_fts WHERE rowid IN (SELECT id FROM message WHERE accountId = ?)",
                arguments: [id.raw.uuidString])
            try database.execute(sql: "DELETE FROM account WHERE id = ?", arguments: [id.raw.uuidString])
        }
    }

    /// Folders are matched by path: a known path keeps its id (and its messages) and its favourite
    /// mark, a new one gets an id, a path no longer given is removed with its messages, unless it
    /// holds something the server has not got (a row numbered 0: an unsaved draft, an unsettled
    /// move) or a change still queued from it. The ids in `given` are ignored.
    public func replaceFolders(_ given: [Folder], for account: AccountID) throws(StoreError) {
        try write { database in
            let key = account.raw.uuidString
            for folder in given {
                try database.execute(
                    sql: """
                        INSERT INTO folder (accountId, path, name, kind, uidValidity, isFavorite, delimiter)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(accountId, path) DO UPDATE SET name = excluded.name,
                            kind = excluded.kind, uidValidity = excluded.uidValidity,
                            delimiter = excluded.delimiter
                        """,
                    arguments: [
                        key, folder.path, folder.name, folder.kind.rawValue, Int64(folder.uidValidity),
                        folder.isFavorite, folder.delimiter
                    ])
            }
            let keep = Set(given.map(\.path))
            let known = try Row.fetchAll(
                database,
                sql: """
                    SELECT f.id, f.path FROM folder f WHERE f.accountId = ?
                        AND NOT EXISTS (SELECT 1 FROM message m WHERE m.folderId = f.id AND m.uid = 0)
                        AND NOT EXISTS (SELECT 1 FROM pending_action p WHERE p.sourceFolderId = f.id)
                    """, arguments: [key])
            for folder in known {
                guard let id = folder["id"] as Int64?, let path = folder["path"] as String?,
                    !keep.contains(path)
                else { continue }
                try database.execute(
                    sql: "DELETE FROM message_fts WHERE rowid IN (SELECT id FROM message WHERE folderId = ?)",
                    arguments: [id])
                try database.execute(sql: "DELETE FROM folder WHERE id = ?", arguments: [id])
            }
        }
    }

    /// Makes one folder a favourite or not; nothing else of it changes.
    public func setFavorite(_ folder: FolderID, _ isFavorite: Bool) throws(StoreError) {
        try write { database in
            try database.execute(
                sql: "UPDATE folder SET isFavorite = ? WHERE id = ?", arguments: [isFavorite, folder.raw])
            guard database.changesCount > 0 else { throw StoreError.noSuchFolder }
        }
    }

    public func folders(_ account: AccountID) throws(StoreError) -> [Folder] {
        try read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT f.*, (SELECT COUNT(*) FROM message m WHERE m.folderId = f.id AND m.isRead = 0)
                        AS unread FROM folder f WHERE f.accountId = ? ORDER BY f.id
                    """, arguments: [account.raw.uuidString]
            ).compactMap(Records.folder)
        }
    }

    // MARK: Messages

    /// A row is matched to a stored one by its id when that exists, else by (folder, uid), else (in the
    /// same folder, by Message-ID) to a uid-0 placeholder a local move left; else it is added with a new id
    /// (the id in the row is then ignored). Returns the stored ids in input order. A stored body is kept.
    public func upsert(_ rows: [MessageRow]) throws(StoreError) -> [MessageID] {
        try write { database in
            var ids: [MessageID] = []
            for row in rows {
                let id = try Self.store(database, row)
                try Self.reindex(database, id)
                try Self.keepReferences(database, id, row)
                ids.append(MessageID(raw: id))
            }
            return ids
        }
    }

    /// Keeps what the row answers, then gathers into its thread every thread holding an answer to
    /// it (a reply that arrived first, in an earlier batch or another folder, started one alone).
    static func keepReferences(_ database: Database, _ id: Int64, _ row: MessageRow) throws {
        let account = row.accountID.raw.uuidString
        if !row.references.isEmpty {
            try database.execute(sql: "DELETE FROM message_ref WHERE messageId = ?", arguments: [id])
            for ref in Set(row.references.prefix(272)) where !ref.isEmpty {
                try database.execute(
                    sql: "INSERT OR IGNORE INTO message_ref (messageId, accountId, ref) VALUES (?, ?, ?)",
                    arguments: [id, account, ref])
            }
        }
        guard let header = row.messageIDHeader, !header.isEmpty else { return }
        try database.execute(
            sql: """
                UPDATE message SET threadId = ? WHERE accountId = ? AND threadId != ? AND threadId IN (
                    SELECT m.threadId FROM message_ref r JOIN message m ON m.id = r.messageId
                    WHERE r.accountId = ? AND r.ref = ?)
                """, arguments: [row.threadID.raw, account, row.threadID.raw, account, header])
    }

    private static func match(_ database: Database, _ row: MessageRow) throws -> Int64? {
        if let byID = try Int64.fetchOne(
            database, sql: "SELECT id FROM message WHERE id = ?", arguments: [row.id.raw]) {
            return byID
        }
        if row.uid > 0,
            let byUID = try Int64.fetchOne(
                database, sql: "SELECT id FROM message WHERE folderId = ? AND uid = ?",
                arguments: [row.folderID.raw, Int64(row.uid)]) {
            return byUID
        }
        guard let header = row.messageIDHeader else { return nil }
        return try Int64.fetchOne(
            database,
            sql: "SELECT id FROM message WHERE folderId = ? AND uid = 0 AND messageIdHeader = ? LIMIT 1",
            arguments: [row.folderID.raw, header])
    }

    /// Stores the row, over the one held for it. `isInvitation` is never lowered: the headers alone
    /// miss an invitation inside a multipart that the whole body showed (`setBody`). Nor is
    /// `isProtected`, and a protected row keeps its subject and preview: what the server holds is
    /// only the outer one.
    static func store(_ database: Database, _ row: MessageRow) throws -> Int64 {
        let existing = try match(database, row)
        let values: [any DatabaseValueConvertible] = [
            row.accountID.raw.uuidString, row.folderID.raw, Int64(row.uid), row.threadID.raw,
            row.from.name, row.from.email, Records.encode(row.to), Records.encode(row.cc),
            row.subject, row.preview, row.date.timeIntervalSince1970, row.isRead, row.isFlagged,
            row.hasAttachment, row.isInvitation, row.inboxClass.rawValue, row.messageIDHeader, row.isProtected
        ]
        if let existing {
            try database.execute(
                sql: """
                    UPDATE message SET accountId = ?, folderId = ?, uid = ?,
                        threadId = CASE WHEN isProtected = 1 THEN threadId ELSE ? END, fromName = ?, fromEmail = ?,
                        toJSON = ?, ccJSON = ?, subject = CASE WHEN isProtected = 1 THEN subject ELSE ? END,
                        preview = CASE WHEN isProtected = 1 THEN preview ELSE ? END, date = ?,
                        isRead = ?, isFlagged = ?,
                        hasAttachment = CASE WHEN isProtected = 1 AND body IS NOT NULL THEN hasAttachment ELSE ? END,
                        isInvitation = MAX(isInvitation, ?), inboxClass = ?, messageIdHeader = ?,
                        isProtected = MAX(isProtected, ?)
                    WHERE id = ?
                    """, arguments: StatementArguments(values + [existing]))
            return existing
        }
        try database.execute(
            sql: """
                INSERT INTO message (accountId, folderId, uid, threadId, fromName, fromEmail, toJSON, ccJSON,
                    subject, preview, date, isRead, isFlagged, hasAttachment, isInvitation, inboxClass,
                    messageIdHeader, isProtected)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: StatementArguments(values))
        return database.lastInsertedRowID
    }

    /// Rewrites the search entry of a message: with `bodyText` (worked out before the write, so no
    /// message is parsed while the database is held), else keeping the body text it has.
    static func reindex(_ database: Database, _ id: Int64, bodyText: String? = nil) throws {
        guard
            let row = try Row.fetchOne(
                database, sql: "SELECT subject, fromName, fromEmail, preview FROM message WHERE id = ?",
                arguments: [id])
        else { return }
        let fields: [any DatabaseValueConvertible] = [
            (row["subject"] as String?) ?? "", (row["fromName"] as String?) ?? "",
            (row["fromEmail"] as String?) ?? "", (row["preview"] as String?) ?? ""
        ]
        let indexed = try Int64.fetchOne(
            database, sql: "SELECT rowid FROM message_fts WHERE rowid = ?", arguments: [id])
        if bodyText == nil, indexed != nil {
            try database.execute(
                sql: """
                    UPDATE message_fts SET subject = ?, senderName = ?, senderAddress = ?, preview = ?
                    WHERE rowid = ?
                    """, arguments: StatementArguments(fields + [id]))
            return
        }
        try database.execute(sql: "DELETE FROM message_fts WHERE rowid = ?", arguments: [id])
        try database.execute(
            sql: """
                INSERT INTO message_fts (rowid, subject, senderName, senderAddress, preview, body)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: StatementArguments([id] + fields + [bodyText ?? ""]))
    }

    static func require(_ database: Database, _ id: MessageID) throws {
        let found = try Int64.fetchOne(database, sql: "SELECT id FROM message WHERE id = ?", arguments: [id.raw])
        guard found != nil else { throw StoreError.noSuchMessage }
    }
}
