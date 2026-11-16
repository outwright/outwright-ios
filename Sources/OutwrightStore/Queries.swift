// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import GRDB
public import OutwrightModel

public enum InboxScope: Hashable, Sendable {
    case allAccounts
    case folder(FolderID)
}

public enum InboxFilter: Sendable {
    case all, unread, flagged, attachments
}

/// `allAccounts` is every account's inbox. Rows are collapsed to the newest per thread, with
/// `threadCount` the number of messages the thread has in that scope.
public struct InboxQuery: Hashable, Sendable {
    public var scope: InboxScope
    public var inboxClass: InboxClass?
    public var filter: InboxFilter

    public init(scope: InboxScope, inboxClass: InboxClass?, filter: InboxFilter) {
        self.scope = scope
        self.inboxClass = inboxClass
        self.filter = filter
    }
}

extension InboxFilter: Hashable {}

enum Queries {
    static func messages(_ database: Database, _ query: InboxQuery, limit: Int) throws -> [MessageRow] {
        let scopeSQL: String
        var args: [any DatabaseValueConvertible] = []
        switch query.scope {
        case .allAccounts:
            scopeSQL = "m.folderId IN (SELECT id FROM folder WHERE kind = 'inbox')"
        case .folder(let id):
            scopeSQL = "m.folderId = ?"
            args.append(id.raw)
        }
        var conditions: [String] = []
        switch query.filter {
        case .all: break
        case .unread: conditions.append("isRead = 0")
        case .flagged: conditions.append("isFlagged = 1")
        case .attachments: conditions.append("hasAttachment = 1")
        }
        if let cls = query.inboxClass {
            conditions.append("inboxClass = ?")
            args.append(cls.rawValue)
        }
        let whereSQL = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        args.append(max(0, min(limit, 10_000)))
        let sql = """
            SELECT * FROM (
                SELECT *, ROW_NUMBER() OVER (
                    PARTITION BY accountId, threadId ORDER BY date DESC, id DESC) AS rn
                FROM (
                    SELECT \(Records.messageColumns),
                        COUNT(*) OVER (PARTITION BY m.accountId, m.threadId) AS cnt
                    FROM message m WHERE \(scopeSQL))
                \(whereSQL))
            WHERE rn = 1 ORDER BY date DESC, id DESC LIMIT ?
            """
        return try Row.fetchAll(database, sql: sql, arguments: StatementArguments(args)).compactMap(Records.message)
    }

    static func thread(_ database: Database, _ thread: ThreadID, account: AccountID) throws -> [MessageRow] {
        let sql = """
            SELECT \(Records.messageColumns), COUNT(*) OVER () AS cnt FROM message m
            WHERE m.accountId = ? AND m.threadId = ? ORDER BY m.date ASC, m.id ASC LIMIT 5000
            """
        return try Row.fetchAll(database, sql: sql, arguments: [account.raw.uuidString, thread.raw])
            .compactMap(Records.message)
    }

    static func search(_ database: Database, _ text: String, filter: SearchFilter, limit: Int) throws -> [MessageRow] {
        guard let match = Records.ftsQuery(text) else { return [] }
        let (conditions, values) = filter.conditions()
        let narrowing = conditions.map { " AND " + $0 }.joined()
        let sql = """
            SELECT \(Records.messageColumns), 1 AS cnt FROM message_fts JOIN message m ON m.id = message_fts.rowid
            WHERE message_fts MATCH ?\(narrowing)
            ORDER BY m.date DESC, m.id DESC LIMIT ?
            """
        let arguments: [any DatabaseValueConvertible] = [match] + values + [max(0, min(limit, 10_000))]
        return try Row.fetchAll(database, sql: sql, arguments: StatementArguments(arguments))
            .compactMap(Records.message)
    }
}

extension Queries {
    static func message(_ database: Database, _ id: MessageID) throws -> MessageRow? {
        let sql = """
            SELECT \(Records.messageColumns), (SELECT COUNT(*) FROM message x
                WHERE x.accountId = m.accountId AND x.threadId = m.threadId) AS cnt
            FROM message m WHERE m.id = ?
            """
        return try Row.fetchOne(database, sql: sql, arguments: [id.raw]).flatMap(Records.message)
    }
}
