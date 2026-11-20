// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
import GRDB
public import OutwrightModel

/// What the store keeps about folder changes besides the queue: tries, refusals, restored folders.
extension MailStore {
    /// One more try of a queued folder change at `date`; a try within a minute of the last counted
    /// one isn't counted again. Returns how many have been counted.
    public func noteFolderTry(_ action: Int64, at date: Date) throws(StoreError) -> Int {
        try write { database in
            let time = date.timeIntervalSince1970
            try database.execute(
                sql: """
                    UPDATE pending_action SET attempts = attempts + 1, triedAt = ?
                    WHERE id = ? AND (triedAt IS NULL OR ? - triedAt >= 60 OR ? < triedAt)
                    """, arguments: [time, action, time, time])
            return try Int.fetchOne(
                database, sql: "SELECT attempts FROM pending_action WHERE id = ?", arguments: [action]) ?? 0
        }
    }

    /// A delete given up: the folders come back here as they were (their ids, so what is queued for
    /// them still finds them), the delete completed in the same step. Their mail comes back with
    /// the next sync.
    /// A path taken meanwhile keeps its row: what is queued for the old one moves to it.
    public func restoreFolders(
        _ folders: [Folder], of account: AccountID, completing action: Int64, telling refusal: FolderRefusal? = nil
    ) throws(StoreError) {
        try write { database in
            try database.execute(sql: "DELETE FROM pending_action WHERE id = ?", arguments: [action])
            if let refusal {
                try Self.tell(database, refusal, account: account.raw.uuidString)
            }
            for folder in folders {
                if let taken = try Int64.fetchOne(
                    database, sql: "SELECT id FROM folder WHERE accountId = ? AND path = ?",
                    arguments: [folder.accountID.raw.uuidString, folder.path]), taken != folder.id.raw {
                    try database.execute(
                        sql: "UPDATE pending_action SET sourceFolderId = ? WHERE sourceFolderId = ?",
                        arguments: [taken, folder.id.raw])
                    try Self.redirectMoves(database, from: folder.id, to: FolderID(raw: taken))
                    continue
                }
                try database.execute(
                    sql: """
                        INSERT OR IGNORE INTO folder
                            (id, accountId, path, name, kind, uidValidity, isFavorite, delimiter)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        folder.id.raw, folder.accountID.raw.uuidString, folder.path, folder.name,
                        folder.kind.rawValue, Int64(folder.uidValidity), folder.isFavorite, folder.delimiter
                    ])
            }
        }
    }

    /// The folder changes refused for each account and not yet seen.
    public func folderRefusals() throws(StoreError) -> [AccountID: FolderRefusal] {
        try read { database in
            var result: [AccountID: FolderRefusal] = [:]
            let sql = "SELECT id, folderRefusal, folderRefusalGaveUp FROM account WHERE folderRefusal IS NOT NULL"
            for row in try Row.fetchAll(database, sql: sql) {
                guard let id = (row["id"] as String?).flatMap(UUID.init(uuidString:)),
                      let name = row["folderRefusal"] as String?
                else { continue }
                let gaveUp = (row["folderRefusalGaveUp"] as Bool?) ?? false
                result[AccountID(raw: id)] = FolderRefusal(name: name, gaveUp: gaveUp)
            }
            return result
        }
    }

    public func setFolderRefusal(_ refusal: FolderRefusal, for account: AccountID) throws(StoreError) {
        try write { database in try Self.tell(database, refusal, account: account.raw.uuidString) }
    }

    /// The owner has seen the refusal of `name`; a newer one stays.
    public func dismissFolderRefusal(_ account: AccountID, name: String) throws(StoreError) {
        try write { database in
            try database.execute(
                sql: """
                    UPDATE account SET folderRefusal = NULL, folderRefusalGaveUp = 0
                    WHERE id = ? AND folderRefusal = ?
                    """,
                arguments: [account.raw.uuidString, name])
        }
    }

    /// Queued moves into `from` go to `to` instead.
    static func redirectMoves(_ database: Database, from: FolderID, to: FolderID) throws {
        for row in try Row.fetchAll(database, sql: "SELECT id, action FROM pending_action") {
            guard let id = row["id"] as Int64?, let data = row["action"] as Data?,
                  case let .moveTo(message, destination)? = try? JSONDecoder().decode(MailAction.self, from: data),
                  destination == from
            else { continue }
            try database.execute(
                sql: "UPDATE pending_action SET action = ? WHERE id = ?",
                arguments: [try JSONEncoder().encode(MailAction.moveTo(message, to)), id])
        }
    }

    static func tell(_ database: Database, _ refusal: FolderRefusal, account: String) throws {
        try database.execute(
            sql: "UPDATE account SET folderRefusal = ?, folderRefusalGaveUp = ? WHERE id = ?",
            arguments: [refusal.name, refusal.gaveUp, account])
    }

    /// Where the account's new top-level folders go, as the last folder sync found it; nil before one.
    public func folderPrefix(_ account: AccountID) throws(StoreError) -> String? {
        try read { database in
            try String.fetchOne(
                database, sql: "SELECT folderPrefix FROM account WHERE id = ?", arguments: [account.raw.uuidString])
        }
    }

    public func setFolderPrefix(_ prefix: String, for account: AccountID) throws(StoreError) {
        try write { database in
            try database.execute(
                sql: "UPDATE account SET folderPrefix = ? WHERE id = ?", arguments: [prefix, account.raw.uuidString])
        }
    }

    /// True while one of the account's folder changes waits for the server; until it is taken,
    /// no other folder change is made.
    public func isFolderChangeWaiting(_ account: AccountID) throws(StoreError) -> Bool {
        try read { database in try Self.waitingFolderChange(database, account: account.raw.uuidString) }
    }

    /// The accounts with a folder change waiting for the server.
    public func accountsWithFolderChangeWaiting() throws(StoreError) -> Set<AccountID> {
        try read { database in try Self.waitingAccounts(database) }
    }

    /// The accounts with a folder change waiting for the server: now, then after each change.
    public func observeFolderChangeWaiting() -> AsyncThrowingStream<Set<AccountID>, any Error> {
        let observation = ValueObservation.tracking { database in try Self.waitingAccounts(database) }
            .removeDuplicates()
        let queue = queue
        return AsyncThrowingStream(Set<AccountID>.self, bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                do {
                    for try await accounts in observation.values(in: queue) {
                        continuation.yield(accounts)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
