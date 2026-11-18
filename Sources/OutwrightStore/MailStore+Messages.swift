// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
import GRDB
import OutwrightMIME
public import OutwrightModel

extension MailStore {
    /// Keeps the raw message, marks the row as having a body, refreshes its search entry and, from
    /// the whole message, whether it carries an attachment. The message is opened before the write
    /// (opening may be slow). A protected one (`multipart/encrypted`, or one the build opened) is
    /// marked, and once opened its subject and preview are the inner message's, kept only here;
    /// one not opened has an empty preview (the screens say "Encrypted message"). Returns what
    /// opening found, for the caller to hand on.
    @discardableResult
    public func setBody(_ data: Data, for message: MessageID) throws(StoreError) -> OpenedMessage? {
        let opened = open(data, account: try self.message(message)?.accountID)
        let parsed = opened?.message
        let decrypted = opened?.facts?.decryption == .decrypted
        // The shape from the headers already read, unless the opener replaced the message.
        let shape = opened.map { $0.facts == nil && MessageReader.isEncryptedShape($0.message) }
            ?? MessageReader.isEncryptedShape(data)
        let isProtected = shape || (opened?.facts.map { $0.decryption != .none } ?? false)
        let text = parsed.map(Records.indexText) ?? ""
        // Closed, the outer parts say nothing about attachments: the encrypted blob is one.
        let hasAttachment = parsed.map { isProtected && !decrypted ? false : $0.attachments.contains { !$0.isInline } }
        let inner = decrypted ? parsed : nil
        let innerPreview = inner.map { Preview.text(of: $0) }
        try write { database in
            try Self.require(database, message)
            try database.execute(
                sql: "UPDATE message SET body = ? WHERE id = ?", arguments: [data, message.raw])
            if let hasAttachment, let parsed {
                // The whole body knows what the headers alone could not: an invitation in a multipart.
                try database.execute(
                    sql: "UPDATE message SET hasAttachment = ?, isInvitation = ? WHERE id = ?",
                    arguments: [hasAttachment, parsed.isInvitation, message.raw])
            }
            if isProtected {
                try database.execute(
                    sql: "UPDATE message SET isProtected = 1, isDecrypted = ? WHERE id = ?",
                    arguments: [decrypted, message.raw])
                if let inner, let innerPreview {
                    try database.execute(
                        sql: "UPDATE message SET subject = ?, preview = ? WHERE id = ?",
                        arguments: [inner.subject, innerPreview, message.raw])
                } else {
                    try database.execute(
                        sql: "UPDATE message SET preview = '' WHERE id = ?", arguments: [message.raw])
                }
            }
            try Self.reindex(database, message.raw, bodyText: text)
        }
        return opened
    }

    /// The server renumbered the folder: everything cached from it is dropped. What it never
    /// numbered (an unsaved draft, a move not yet settled) is kept. Changes queued from the folder
    /// forget the uid they were queued with, which may now name another message.
    public func resetFolder(_ id: FolderID, uidValidity: UInt32) throws(StoreError) {
        try write { database in
            try database.execute(
                sql: "DELETE FROM message_fts WHERE rowid IN (SELECT id FROM message WHERE folderId = ? AND uid > 0)",
                arguments: [id.raw])
            try database.execute(sql: "DELETE FROM message WHERE folderId = ? AND uid > 0", arguments: [id.raw])
            try database.execute(
                sql: "UPDATE pending_action SET sourceUid = 0 WHERE sourceFolderId = ?", arguments: [id.raw])
            try database.execute(
                sql: "UPDATE folder SET uidValidity = ?, heldSince = NULL, highestModSeq = NULL WHERE id = ?",
                arguments: [Int64(uidValidity), id.raw])
        }
    }

    /// The day back to which the folder's mail is held, once older mail was fetched; nil while
    /// only the sync window is.
    public func heldSince(_ folder: FolderID) throws(StoreError) -> Date? {
        try read { database in
            try Double.fetchOne(database, sql: "SELECT heldSince FROM folder WHERE id = ?", arguments: [folder.raw])
                .map { Date(timeIntervalSince1970: $0) }
        }
    }

    public func setHeldSince(_ folder: FolderID, _ date: Date?) throws(StoreError) {
        try write { database in
            try database.execute(
                sql: "UPDATE folder SET heldSince = ? WHERE id = ?",
                arguments: [date?.timeIntervalSince1970, folder.raw])
        }
    }

    /// The folder's HIGHESTMODSEQ as of its last reconcile; nil when the next one must be full.
    public func highestModSeq(_ folder: FolderID) throws(StoreError) -> UInt64? {
        try read { database in
            try Int64?.fetchOne(database, sql: "SELECT highestModSeq FROM folder WHERE id = ?", arguments: [folder.raw])
                .flatMap { $0 }
                .map { UInt64(bitPattern: $0) }
        }
    }

    public func setHighestModSeq(_ folder: FolderID, _ value: UInt64?) throws(StoreError) {
        try write { database in
            try database.execute(
                sql: "UPDATE folder SET highestModSeq = ? WHERE id = ?",
                arguments: [value.map { Int64(bitPattern: $0) }, folder.raw])
        }
    }

    /// The folder holding `message` forgets its HIGHESTMODSEQ, so its next sync reconciles in full
    /// (a flag change here the server never took).
    public func forgetHighestModSeq(holding message: MessageID) throws(StoreError) {
        try write { database in
            try database.execute(
                sql: "UPDATE folder SET highestModSeq = NULL WHERE id = (SELECT folderId FROM message WHERE id = ?)",
                arguments: [message.raw])
        }
    }

    /// The server no longer has these uids: their rows and search entries go.
    public func removeMessages(folder: FolderID, uids: [UInt32]) throws(StoreError) {
        try write { database in
            for chunk in stride(from: 0, to: uids.count, by: 500) {
                let part = uids[chunk..<min(chunk + 500, uids.count)].map { Int64($0) }
                let marks = Array(repeating: "?", count: part.count).joined(separator: ",")
                let arguments = StatementArguments([folder.raw] + part)
                try database.execute(
                    sql: """
                        DELETE FROM message_fts WHERE rowid IN
                            (SELECT id FROM message WHERE folderId = ? AND uid IN (\(marks)))
                        """, arguments: arguments)
                try database.execute(
                    sql: "DELETE FROM message WHERE folderId = ? AND uid IN (\(marks))", arguments: arguments)
            }
        }
    }

    /// Removes one message and its search entry, numbered or not (a sent draft).
    public func removeMessage(_ id: MessageID) throws(StoreError) {
        try write { database in
            try database.execute(sql: "DELETE FROM message_fts WHERE rowid = ?", arguments: [id.raw])
            try database.execute(sql: "DELETE FROM message WHERE id = ?", arguments: [id.raw])
        }
    }

    /// The server numbered the message anew (a draft saved again).
    public func setUID(_ uid: UInt32, for message: MessageID) throws(StoreError) {
        try write { database in
            try Self.number(database, message, Int64(uid))
        }
    }

    /// Gives the message `uid`. A row a sync stored meanwhile for that uid (here or in the
    /// notification extension) goes: this one is what queued changes, an open message and its
    /// fetched body point at.
    static func number(_ database: Database, _ message: MessageID, _ uid: Int64) throws {
        if uid > 0 {
            let others = """
                SELECT o.id FROM message o JOIN message m ON m.id = ?
                WHERE o.folderId = m.folderId AND o.uid = ? AND o.id != m.id
                """
            try database.execute(
                sql: "DELETE FROM message_fts WHERE rowid IN (\(others))", arguments: [message.raw, uid])
            try database.execute(sql: "DELETE FROM message WHERE id IN (\(others))", arguments: [message.raw, uid])
        }
        try database.execute(sql: "UPDATE message SET uid = ? WHERE id = ?", arguments: [uid, message.raw])
    }

    /// What the server says: no action is queued.
    public func updateFlags(_ message: MessageID, isRead: Bool, isFlagged: Bool) throws(StoreError) {
        try write { database in
            try database.execute(
                sql: "UPDATE message SET isRead = ?, isFlagged = ? WHERE id = ?",
                arguments: [isRead, isFlagged, message.raw])
        }
    }

    public func message(_ id: MessageID) throws(StoreError) -> MessageRow? {
        try read { database in try Queries.message(database, id) }
    }

    /// Every message of the folder the server has numbered (uid > 0), by uid.
    public func folderIndex(_ folder: FolderID) throws(StoreError) -> [UInt32: MessageID] {
        try read { database in
            var result: [UInt32: MessageID] = [:]
            let rows = try Row.fetchAll(
                database, sql: "SELECT uid, id FROM message WHERE folderId = ? AND uid > 0",
                arguments: [folder.raw])
            for row in rows {
                if let uid = row["uid"] as Int64?, let id = row["id"] as Int64? {
                    result[UInt32(clamping: uid)] = MessageID(raw: id)
                }
            }
            return result
        }
    }

    /// The uids of `folder` the owner has moved or deleted here while the server has still to
    /// hear of it (the action pending): the server still lists them in the folder, but they are
    /// not new mail there.
    public func movedAwayUIDs(_ folder: FolderID) throws(StoreError) -> Set<UInt32> {
        try read { database in
            let uids = try Int64.fetchAll(
                database,
                sql: """
                    SELECT p.sourceUid FROM pending_action p
                    WHERE p.sourceFolderId = ? AND p.sourceUid > 0
                    AND NOT EXISTS (SELECT 1 FROM message m WHERE m.folderId = ? AND m.uid = p.sourceUid)
                    """,
                arguments: [folder.raw, folder.raw])
            return Set(uids.map { UInt32(clamping: $0) })
        }
    }

    /// The thread a stored message with this Message-ID header belongs to.
    public func threadID(forMessageID header: String, account: AccountID) throws(StoreError) -> ThreadID? {
        try read { database in
            try String.fetchOne(
                database,
                sql: "SELECT threadId FROM message WHERE accountId = ? AND messageIdHeader = ? LIMIT 1",
                arguments: [account.raw.uuidString, header]
            ).map { ThreadID(raw: $0) }
        }
    }

    public func messages(_ query: InboxQuery, limit: Int) throws(StoreError) -> [MessageRow] {
        try read { database in try Queries.messages(database, query, limit: limit) }
    }

    /// Every unread message of a list (a folder, or every account's Inbox), not only the rows shown.
    public func unreadMessages(_ scope: InboxScope) throws(StoreError) -> [MessageID] {
        try read { database in
            switch scope {
            case .allAccounts:
                try Int64.fetchAll(
                    database,
                    sql: """
                        SELECT id FROM message WHERE isRead = 0
                        AND folderId IN (SELECT id FROM folder WHERE kind = 'inbox')
                        """
                ).map { MessageID(raw: $0) }
            case .folder(let folder):
                try Int64.fetchAll(
                    database, sql: "SELECT id FROM message WHERE isRead = 0 AND folderId = ?", arguments: [folder.raw]
                ).map { MessageID(raw: $0) }
            }
        }
    }

    /// The first value is the current state; a new one follows each change to the stored mail.
    public func observe(_ query: InboxQuery, limit: Int = 500) -> AsyncStream<[MessageRow]> {
        let observation = ValueObservation.tracking { database in
            try Queries.messages(database, query, limit: limit)
        }
        let queue = queue
        return AsyncStream { continuation in
            let task = Task {
                do {
                    for try await rows in observation.values(in: queue) {
                        continuation.yield(rows)
                    }
                } catch {}
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func thread(_ thread: ThreadID, account: AccountID) throws(StoreError) -> [MessageRow] {
        try read { database in try Queries.thread(database, thread, account: account) }
    }

    public func body(_ message: MessageID) throws(StoreError) -> Data? {
        try read { database in
            try Data.fetchOne(database, sql: "SELECT body FROM message WHERE id = ?", arguments: [message.raw])
        }
    }

    public func search(_ text: String, limit: Int) throws(StoreError) -> [MessageRow] {
        try search(text, filter: SearchFilter(), limit: limit)
    }

    /// The mail whose words start with each word of `text`, narrowed by `filter`; newest first.
    public func search(_ text: String, filter: SearchFilter, limit: Int) throws(StoreError) -> [MessageRow] {
        try read { database in try Queries.search(database, text, filter: filter, limit: limit) }
    }
}
