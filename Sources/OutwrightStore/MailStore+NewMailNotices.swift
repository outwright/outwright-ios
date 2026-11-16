// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
import GRDB
public import OutwrightModel

/// Local new-mail notices: an account with them on has a row in `new_mail_notice`, holding how far
/// its Inbox has been announced (the UIDVALIDITY and the last UID) and when that mark was set.
extension MailStore {
    /// Mail dated this long before the mark was set may still be new: delivery can be late.
    static let noticeSlack: TimeInterval = 3_600

    public func notifiesNewMail(_ account: AccountID) throws(StoreError) -> Bool {
        try read { database in
            try Bool.fetchOne(
                database, sql: "SELECT 1 FROM new_mail_notice WHERE accountId = ?",
                arguments: [account.raw.uuidString]) ?? false
        }
    }

    /// The accounts with local notices on.
    public func newMailNoticeAccounts() throws(StoreError) -> [AccountID] {
        try read { database in
            try String.fetchAll(database, sql: "SELECT accountId FROM new_mail_notice ORDER BY accountId")
                .compactMap { UUID(uuidString: $0).map { AccountID(raw: $0) } }
        }
    }

    /// On puts the mark at the Inbox's newest message, so nothing already there is announced; off
    /// forgets it.
    public func setNotifiesNewMail(_ wanted: Bool, for account: AccountID, now: Date = Date()) throws(StoreError) {
        try write { database in
            if wanted {
                try Self.markNewest(database, account.raw.uuidString, now: now)
            } else {
                try database.execute(
                    sql: "DELETE FROM new_mail_notice WHERE accountId = ?", arguments: [account.raw.uuidString])
            }
        }
    }

    /// The unread Inbox messages above the mark, oldest first; the mark moves past every Inbox
    /// message above it, read ones too. Mail dated well before the mark was set is old mail a sync
    /// cut short brought in late, and is not announced. A renumbered Inbox announces nothing: the
    /// mark starts again at its newest message.
    public func claimNewInboxMail(_ account: AccountID, now: Date = Date()) throws(StoreError) -> [MessageRow] {
        try write { database in
            let id = account.raw.uuidString
            guard
                let mark = try Row.fetchOne(
                    database, sql: "SELECT uidValidity, lastUID, markedAt FROM new_mail_notice WHERE accountId = ?",
                    arguments: [id]),
                let inbox = try Self.inbox(database, id)
            else { return [] }
            guard (mark["uidValidity"] as Int64?) == inbox.validity else {
                try Self.markNewest(database, id, now: now)
                return []
            }
            let last = (mark["lastUID"] as Int64?) ?? 0
            let since = ((mark["markedAt"] as Double?) ?? 0) - Self.noticeSlack
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT \(Records.messageColumns), 1 AS cnt FROM message m
                    WHERE m.folderId = ? AND m.uid > ? AND m.isRead = 0 AND m.date >= ? ORDER BY m.uid
                    """,
                arguments: [inbox.folder, last, since]
            ).compactMap(Records.message)
            // The mark passes everything held; when it was set stays.
            try database.execute(
                sql: """
                    UPDATE new_mail_notice SET lastUID = MAX(lastUID, (SELECT IFNULL(MAX(uid), 0) FROM message
                    WHERE folderId = ?)) WHERE accountId = ?
                    """,
                arguments: [inbox.folder, id])
            return rows
        }
    }

    /// Every mark to its Inbox's newest message: what is there now is never announced.
    public func moveNewMailMarks(now: Date = Date()) throws(StoreError) {
        try write { database in
            for id in try String.fetchAll(database, sql: "SELECT accountId FROM new_mail_notice") {
                try Self.markNewest(database, id, now: now)
            }
        }
    }

    private static func inbox(_ database: Database, _ account: String) throws -> (folder: Int64, validity: Int64)? {
        try Row.fetchOne(
            database, sql: "SELECT id, uidValidity FROM folder WHERE accountId = ? AND kind = ? LIMIT 1",
            arguments: [account, FolderKind.inbox.rawValue]
        ).flatMap { row in
            guard let folder = row["id"] as Int64?, let validity = row["uidValidity"] as Int64? else { return nil }
            return (folder, validity)
        }
    }

    /// The mark at the Inbox's UIDVALIDITY and highest UID (0 without an Inbox or mail in it), set
    /// `now`.
    private static func markNewest(_ database: Database, _ account: String, now: Date) throws {
        let inbox = try inbox(database, account)
        let highest = try inbox.map {
            try Int64.fetchOne(database, sql: "SELECT MAX(uid) FROM message WHERE folderId = ?", arguments: [$0.folder])
                ?? 0
        } ?? 0
        try database.execute(
            sql: """
                INSERT INTO new_mail_notice (accountId, uidValidity, lastUID, markedAt) VALUES (?, ?, ?, ?)
                ON CONFLICT (accountId) DO UPDATE SET uidValidity = excluded.uidValidity, lastUID = excluded.lastUID,
                    markedAt = excluded.markedAt
                """,
            arguments: [account, inbox?.validity ?? 0, highest, now.timeIntervalSince1970])
    }
}
