// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
import GRDB
public import OutwrightModel

/// A change waiting for the server, with where the message stood when it was made.
public struct PendingAction: Sendable {
    public var id: Int64
    public var action: MailAction
    public var accountID: AccountID
    public var sourceFolderID: FolderID?
    public var sourceUID: UInt32

    public init(id: Int64, action: MailAction, accountID: AccountID, sourceFolderID: FolderID?, sourceUID: UInt32) {
        self.id = id
        self.action = action
        self.accountID = accountID
        self.sourceFolderID = sourceFolderID
        self.sourceUID = sourceUID
    }
}

extension MailStore {
    // MARK: Classification

    /// Lower-case addresses the account's owner has written to (recipients of its Sent mail).
    public func correspondents(_ account: AccountID) throws(StoreError) -> Set<String> {
        try read { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT m.toJSON, m.ccJSON FROM message m JOIN folder f ON f.id = m.folderId
                    WHERE m.accountId = ? AND f.kind = 'sent' ORDER BY m.date DESC LIMIT 20000
                    """, arguments: [account.raw.uuidString])
            var result = Set<String>()
            for row in rows {
                let both = Records.decode(row["toJSON"] as String?) + Records.decode(row["ccJSON"] as String?)
                for address in both { result.insert(address.email.lowercased()) }
            }
            return result
        }
    }

    /// Sets how a sender is sorted, and re-sorts the mail already held from that sender.
    public func setOverride(_ sender: String, _ inboxClass: InboxClass) throws(StoreError) {
        let key = sender.lowercased()
        try write { database in
            try database.execute(
                sql: """
                    INSERT INTO sender_override (email, class) VALUES (?, ?)
                    ON CONFLICT(email) DO UPDATE SET class = excluded.class
                    """, arguments: [key, inboxClass.rawValue])
            try database.execute(
                sql: "UPDATE message SET inboxClass = ? WHERE swiftLowercaseString(fromEmail) = ?",
                arguments: [inboxClass.rawValue, key])
        }
    }

    /// Every sender override, keyed by lower-case address.
    public func overrides() throws(StoreError) -> [String: InboxClass] {
        try read { database in
            var result: [String: InboxClass] = [:]
            for row in try Row.fetchAll(database, sql: "SELECT email, class FROM sender_override") {
                let email = row["email"] as String?
                let cls = (row["class"] as String?).flatMap(InboxClass.init(rawValue:))
                if let email, let cls { result[email] = cls }
            }
            return result
        }
    }

    // MARK: Actions

    struct Source {
        var account: String
        var folder: Int64
        var uid: Int64
        var kind: String
    }

    static func source(_ database: Database, _ id: MessageID) throws -> Source {
        let row = try Row.fetchOne(
            database,
            sql: """
                SELECT m.accountId, m.folderId, m.uid, f.kind FROM message m
                JOIN folder f ON f.id = m.folderId WHERE m.id = ?
                """, arguments: [id.raw])
        guard let row, let account = row["accountId"] as String?, let folder = row["folderId"] as Int64? else {
            throw StoreError.noSuchMessage
        }
        return Source(
            account: account, folder: folder, uid: (row["uid"] as Int64?) ?? 0,
            kind: (row["kind"] as String?) ?? "")
    }

    /// Makes the change here, and queues it for the server with the message's folder and uid as they
    /// were, in one transaction. A move gives the message uid 0 until `settleMove`. Moving to the folder
    /// the message is in does nothing.
    public func apply(_ action: MailAction) throws(StoreError) {
        let queuedFor: String? = try write { database in
            let from = try Self.source(database, action.target)
            guard try Self.perform(database, action, from: from) else { return nil }
            try Self.queue(database, action, from: from)
            return from.account
        }
        if let queuedFor, let id = UUID(uuidString: queuedFor) {
            announceQueued(AccountID(raw: id))
        }
    }

    static func queue(_ database: Database, _ action: MailAction, from: Source) throws {
        try database.execute(
            sql: """
                INSERT INTO pending_action (accountId, action, sourceFolderId, sourceUid)
                VALUES (?, ?, ?, ?)
                """,
            arguments: [from.account, try JSONEncoder().encode(action), from.folder, from.uid])
    }

    /// The local effect. False when there was nothing to do.
    private static func perform(_ database: Database, _ action: MailAction, from: Source) throws -> Bool {
        switch action {
        case .setRead(let id, let value):
            try database.execute(sql: "UPDATE message SET isRead = ? WHERE id = ?", arguments: [value, id.raw])
        case .setFlagged(let id, let value):
            try database.execute(sql: "UPDATE message SET isFlagged = ? WHERE id = ?", arguments: [value, id.raw])
        case .move(let id, let kind):
            return try move(database, id, to: try folder(database, from, kind: kind), from: from)
        case .moveTo(let id, let folder):
            let found = try Int64.fetchOne(
                database, sql: "SELECT id FROM folder WHERE id = ? AND accountId = ?",
                arguments: [folder.raw, from.account])
            guard let found else { throw StoreError.noSuchFolder }
            return try move(database, id, to: found, from: from)
        case .delete(let id):
            if from.kind == FolderKind.trash.rawValue {
                try database.execute(sql: "DELETE FROM message_fts WHERE rowid = ?", arguments: [id.raw])
                try database.execute(sql: "DELETE FROM message WHERE id = ?", arguments: [id.raw])
            } else {
                return try move(database, id, to: try folder(database, from, kind: .trash), from: from)
            }
        case .send(let id), .saveDraft(let id):
            // The owner tries again: a refusal before no longer stands.
            try database.execute(sql: "UPDATE message SET notSent = NULL WHERE id = ?", arguments: [id.raw])
        case .fileSent:
            break
        }
        return true
    }

    private static func folder(_ database: Database, _ from: Source, kind: FolderKind) throws -> Int64 {
        let sql = "SELECT id FROM folder WHERE kind = ? AND accountId = ? ORDER BY id LIMIT 1"
        guard let found = try Int64.fetchOne(database, sql: sql, arguments: [kind.rawValue, from.account])
        else { throw StoreError.noSuchFolder }
        return found
    }

    private static func move(_ database: Database, _ id: MessageID, to folder: Int64, from: Source) throws -> Bool {
        if folder == from.folder { return false }
        try database.execute(
            sql: "UPDATE message SET folderId = ?, uid = 0 WHERE id = ?", arguments: [folder, id.raw])
        try retakeLeavingJunk(database, id, to: folder, from: from)
        return true
    }

    /// An invitation the intake refused in Junk is an invitation like any other once the owner moves
    /// it out (but not to Trash): what was recorded goes, so the intake takes it again.
    private static func retakeLeavingJunk(_ database: Database, _ id: MessageID, to folder: Int64, from: Source)
        throws {
        guard from.kind == FolderKind.junk.rawValue else { return }
        let target = try String.fetchOne(database, sql: "SELECT kind FROM folder WHERE id = ?", arguments: [folder])
        guard target != FolderKind.junk.rawValue, target != FolderKind.trash.rawValue else { return }
        try database.execute(
            sql: "DELETE FROM invitation_message WHERE messageId = ? AND applied = 0", arguments: [id.raw])
    }

    /// After the server moved a message: set its new uid when it said (UIDPLUS), else drop the uid-0
    /// placeholder, which the next synchronisation brings back with the real one.
    public func settleMove(_ message: MessageID, newUID: UInt32?) throws(StoreError) {
        try write { database in
            if let newUID {
                try database.execute(
                    sql: "UPDATE message SET uid = ? WHERE id = ? AND uid = 0",
                    arguments: [Int64(newUID), message.raw])
            } else {
                try database.execute(
                    sql: "DELETE FROM message_fts WHERE rowid IN (SELECT id FROM message WHERE id = ? AND uid = 0)",
                    arguments: [message.raw])
                try database.execute(
                    sql: "DELETE FROM message WHERE id = ? AND uid = 0", arguments: [message.raw])
            }
        }
    }

    /// Oldest first. An action that can't be read is removed.
    public func pendingActions() throws(StoreError) -> [PendingAction] {
        try write { database in
            var result: [PendingAction] = []
            var broken: [Int64] = []
            for row in try Row.fetchAll(database, sql: "SELECT * FROM pending_action ORDER BY id") {
                guard let id = row["id"] as Int64? else { continue }
                guard let data = row["action"] as Data?,
                    let action = try? JSONDecoder().decode(MailAction.self, from: data),
                    let account = (row["accountId"] as String?).flatMap({ UUID(uuidString: $0) })
                else {
                    broken.append(id)
                    continue
                }
                result.append(
                    PendingAction(
                        id: id, action: action, accountID: AccountID(raw: account),
                        sourceFolderID: (row["sourceFolderId"] as Int64?).map { FolderID(raw: $0) },
                        sourceUID: UInt32(clamping: (row["sourceUid"] as Int64?) ?? 0)))
            }
            for id in broken {
                try database.execute(sql: "DELETE FROM pending_action WHERE id = ?", arguments: [id])
            }
            return result
        }
    }

    /// The folder was renumbered: the uid the action was queued with means nothing now, so it
    /// is found again (by Message-ID) instead.
    public func forgetSourceUID(of action: Int64) throws(StoreError) {
        try write { database in
            try database.execute(sql: "UPDATE pending_action SET sourceUid = 0 WHERE id = ?", arguments: [action])
        }
    }

    /// The server took the draft for sending, in one step: the send is done, the row becomes the
    /// owner's copy in Sent (unnumbered, holding `copy`, dated `date`), and `fileSent` is queued
    /// with where the draft stood, to file the copy on the server and remove the draft there.
    /// Without a Sent folder the row just goes. A protected copy (`multipart/encrypted`) marks the row,
    /// which keeps the real subject and preview it was written with.
    public func settleSend(_ action: Int64, draft: MessageID, copy: Data, date: Date) throws(StoreError) {
        let isProtected = MessageReader.isEncryptedShape(copy)
        try write { database in
            try database.execute(sql: "DELETE FROM pending_action WHERE id = ?", arguments: [action])
            let from = try Self.source(database, draft)
            guard let sent = try Int64.fetchOne(
                database, sql: "SELECT id FROM folder WHERE kind = 'sent' AND accountId = ? ORDER BY id LIMIT 1",
                arguments: [from.account])
            else {
                try database.execute(sql: "DELETE FROM message_fts WHERE rowid = ?", arguments: [draft.raw])
                try database.execute(sql: "DELETE FROM message WHERE id = ?", arguments: [draft.raw])
                return
            }
            try database.execute(
                sql: """
                    UPDATE message SET folderId = ?, uid = 0, body = ?, date = ?, isRead = 1, notSent = NULL,
                        protection = NULL, submittedTo = NULL, isProtected = MAX(isProtected, ?),
                        isDecrypted = CASE WHEN ? THEN 1 ELSE isDecrypted END
                    WHERE id = ?
                    """, arguments: [sent, copy, date.timeIntervalSince1970, isProtected, isProtected, draft.raw])
            try Self.reindex(database, draft.raw)
            try Self.queue(database, .fileSent(draft), from: from)
        }
    }

    /// The server refused the draft for good: the send is done with, and the draft stays, marked.
    public func refuseSend(_ action: Int64, draft: MessageID, reason: SendRefusal) throws(StoreError) {
        try write { database in
            try database.execute(sql: "DELETE FROM pending_action WHERE id = ?", arguments: [action])
            try database.execute(
                sql: "UPDATE message SET notSent = ? WHERE id = ?", arguments: [reason.rawValue, draft.raw])
        }
    }

    /// The addresses (lower-case) the server has taken the draft for, kept until it is sent whole.
    public func submittedTo(of message: MessageID) throws(StoreError) -> Set<String> {
        try read { database in
            let data = try Data.fetchOne(
                database, sql: "SELECT submittedTo FROM message WHERE id = ?", arguments: [message.raw])
            return Set(data.flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? [])
        }
    }

    /// The server has taken the draft for `addresses` too.
    public func addSubmitted(_ addresses: [String], to message: MessageID) throws(StoreError) {
        try write { database in
            try Self.require(database, message)
            let data = try Data.fetchOne(
                database, sql: "SELECT submittedTo FROM message WHERE id = ?", arguments: [message.raw])
            var all = Set(data.flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? [])
            all.formUnion(addresses.map { $0.lowercased() })
            try database.execute(
                sql: "UPDATE message SET submittedTo = ? WHERE id = ?",
                arguments: [try JSONEncoder().encode(all.sorted()), message.raw])
        }
    }

    /// The server keeps the message protected while the row holds it as written: the row is marked,
    /// so the server's outer headers never overwrite its subject and preview.
    public func markProtected(_ message: MessageID) throws(StoreError) {
        try write { database in
            try database.execute(
                sql: "UPDATE message SET isProtected = 1, isDecrypted = 1 WHERE id = ?", arguments: [message.raw])
        }
    }

    /// The draft changed: no address counts as having it any more, so a send goes to everyone.
    public func resetSubmitted(of message: MessageID) throws(StoreError) {
        try write { database in
            try database.execute(sql: "UPDATE message SET submittedTo = NULL WHERE id = ?", arguments: [message.raw])
        }
    }

    /// What the message asks to be sent with; nil: nothing. A value that cannot be read is none.
    public func protection(of message: MessageID) throws(StoreError) -> ProtectionRequirement? {
        try read { database in
            let data = try Data.fetchOne(
                database, sql: "SELECT protection FROM message WHERE id = ?", arguments: [message.raw])
            return data.flatMap { try? JSONDecoder().decode(ProtectionRequirement.self, from: $0) }
        }
    }

    public func setProtection(_ requirement: ProtectionRequirement?, for message: MessageID) throws(StoreError) {
        try write { database in
            try Self.require(database, message)
            let data = try requirement.map { try JSONEncoder().encode($0) }
            try database.execute(
                sql: "UPDATE message SET protection = ? WHERE id = ?", arguments: [data, message.raw])
        }
    }

    /// One more run could not find the action's message; returns how many have.
    public func noteMiss(_ action: Int64) throws(StoreError) -> Int {
        try write { database in
            try database.execute(
                sql: "UPDATE pending_action SET attempts = attempts + 1 WHERE id = ?", arguments: [action])
            return try Int.fetchOne(
                database, sql: "SELECT attempts FROM pending_action WHERE id = ?", arguments: [action]) ?? 0
        }
    }

    public func completeAction(_ id: Int64) throws(StoreError) {
        try write { database in
            try database.execute(sql: "DELETE FROM pending_action WHERE id = ?", arguments: [id])
        }
    }
}
