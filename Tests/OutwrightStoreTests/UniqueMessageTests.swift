// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import GRDB
import OutwrightModel
import Testing

@testable import OutwrightStore

/// The app and its notification extension can sync one Inbox at once: the store holds one row per
/// message in a folder, whoever stores it first.
@Suite final class UniqueMessageTests {
    private let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("outwright-unique-\(UUID().uuidString)", isDirectory: true)

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    private func count(_ store: MailStore, _ sql: String, _ arguments: StatementArguments = []) throws -> Int {
        try store.queue.read { try Int.fetchOne($0, sql: sql, arguments: arguments) ?? 0 }
    }

    /// A raw copy of the message with `uid` in the Inbox, as a second process would have written it.
    private func copy(_ store: MailStore, uid: UInt32, folder: FolderID, body: Data? = nil) throws {
        try store.queue.write { database in
            try database.execute(
                sql: """
                    INSERT INTO message (accountId, folderId, uid, threadId, fromName, fromEmail, toJSON, ccJSON,
                        subject, preview, date, isRead, isFlagged, hasAttachment, isInvitation, inboxClass,
                        messageIdHeader, body)
                    SELECT accountId, folderId, uid, threadId, fromName, fromEmail, toJSON, ccJSON, subject,
                        preview, date, isRead, isFlagged, hasAttachment, isInvitation, inboxClass, messageIdHeader, ?
                    FROM message WHERE folderId = ? AND uid = ? LIMIT 1
                    """,
                arguments: [body, folder.raw, Int64(uid)])
        }
    }

    @Test func aSecondRowForTheSameUIDIsRefused() throws {
        let f = try Fixture()
        _ = try f.store.upsert([row(f.account.id, f.inbox.id, uid: 7)])
        #expect(throws: (any Error).self) { try self.copy(f.store, uid: 7, folder: f.inbox.id) }
        #expect(try count(f.store, "SELECT COUNT(*) FROM message WHERE uid = 7") == 1)
    }

    @Test func placeholdersMayRepeat() throws {
        let f = try Fixture()
        _ = try f.store.upsert([row(f.account.id, f.inbox.id, uid: 1), row(f.account.id, f.inbox.id, uid: 2)])
        try f.store.queue.write { try $0.execute(sql: "UPDATE message SET uid = 0") }
        #expect(try count(f.store, "SELECT COUNT(*) FROM message WHERE uid = 0") == 2)
    }

    @Test func theMigrationKeepsOneOfEachDuplicate() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent("mail.sqlite")
        var store: MailStore? = try MailStore(path: path)
        let account = Fixture.makeAccount(name: "Anna", email: "anna@example.org", order: 0)
        let inbox: FolderID
        do {
            let opened = try #require(store)
            try opened.save(account)
            try opened.replaceFolders(Fixture.folders(for: account.id), for: account.id)
            inbox = try #require(try opened.folders(account.id).first { $0.kind == .inbox }).id
            _ = try opened.upsert([row(account.id, inbox, uid: 7), row(account.id, inbox, uid: 8)])
            // As a store from before the migration: no index, and a second copy of UID 7 with a body.
            try opened.queue.write { database in
                try database.execute(sql: "DROP INDEX message_folder_uid_unique")
                try database.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'uniqueFolderUID'")
            }
            try copy(opened, uid: 7, folder: inbox, body: Data("body".utf8))
            try opened.queue.write { database in
                try database.execute(
                    sql: "INSERT INTO message_fts (rowid, subject, senderName, senderAddress, preview, body) "
                        + "SELECT id, subject, '', fromEmail, preview, '' FROM message WHERE body IS NOT NULL")
                // The copy that goes (no body) is a reply to an invitation: rows hang on it.
                let losing = try #require(try Int64.fetchOne(
                    database, sql: "SELECT id FROM message WHERE uid = 7 AND body IS NULL"))
                try database.execute(
                    sql: "INSERT INTO message_ref (messageId, accountId, ref) VALUES (?, ?, 'a@example.org')",
                    arguments: [losing, account.id.raw.uuidString])
                try database.execute(
                    sql: "INSERT INTO invitation_message (messageId, method, uid, sequence, applied) "
                        + "VALUES (?, 'REQUEST', 'event-1', 0, 0)",
                    arguments: [losing])
            }
            #expect(try count(opened, "SELECT COUNT(*) FROM message WHERE uid = 7") == 2)
        }
        store = nil
        let migrated = try MailStore(path: path)
        #expect(try count(migrated, "SELECT COUNT(*) FROM message WHERE uid = 7") == 1)
        #expect(try count(migrated, "SELECT COUNT(*) FROM message WHERE uid = 7 AND body IS NOT NULL") == 1)
        #expect(try count(migrated, "SELECT COUNT(*) FROM message WHERE uid = 8") == 1)
        #expect(try count(migrated, "SELECT COUNT(*) FROM message_fts WHERE rowid NOT IN (SELECT id FROM message)") == 0)
        #expect(try count(migrated, "SELECT COUNT(*) FROM message_ref") == 0)
        #expect(try count(migrated, "SELECT COUNT(*) FROM invitation_message") == 0)
        _ = store
    }

    /// The placeholder is what queued changes, an open message and its fetched body point at: it
    /// keeps them and takes the UID, and the copy a sync stored meanwhile goes.
    @Test func assigningAUIDAlreadyStoredKeepsThePlaceholder() throws {
        let f = try Fixture()
        _ = try f.store.upsert([row(f.account.id, f.inbox.id, uid: 3)])
        let placeholder = try #require(try f.store.folderIndex(f.inbox.id)[3])
        try f.store.queue.write { database in
            try database.execute(
                sql: "UPDATE message SET uid = 0, body = ?, isFlagged = 1 WHERE id = ?",
                arguments: [Data("kept".utf8), placeholder.raw])
        }
        // Meanwhile the other process stored the server's row for UID 7 (no Message-ID to match).
        _ = try f.store.upsert([row(f.account.id, f.inbox.id, uid: 7)])
        try f.store.settleMove(placeholder, newUID: 7)
        #expect(try f.store.folderIndex(f.inbox.id) == [7: placeholder])
        #expect(try f.store.body(placeholder) == Data("kept".utf8))
        #expect(try f.store.message(placeholder)?.isFlagged == true)
        // A draft numbered anew the same way.
        _ = try f.store.upsert([row(f.account.id, f.inbox.id, uid: 9)])
        try f.store.setUID(9, for: placeholder)
        #expect(try f.store.folderIndex(f.inbox.id) == [9: placeholder])
    }
}
