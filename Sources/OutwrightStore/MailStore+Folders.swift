// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import GRDB
public import OutwrightModel

/// Folders made here that give way to the server's.
extension MailStore {
    /// A folder made here gives way to `path`, its messages and the changes waiting on it going
    /// along: into the account's folder at that path when there is one, else it takes that path.
    public func adoptFolder(_ folder: FolderID, as path: String) throws(StoreError) {
        try write { database in
            guard let account = try String.fetchOne(
                database, sql: "SELECT accountId FROM folder WHERE id = ?", arguments: [folder.raw])
            else { throw StoreError.noSuchFolder }
            guard let target = try Int64.fetchOne(
                database, sql: "SELECT id FROM folder WHERE accountId = ? AND path = ?", arguments: [account, path])
            else {
                try database.execute(sql: "UPDATE folder SET path = ? WHERE id = ?", arguments: [path, folder.raw])
                return
            }
            guard target != folder.raw else { return }
            try database.execute(
                sql: "UPDATE message SET folderId = ? WHERE folderId = ?", arguments: [target, folder.raw])
            try database.execute(
                sql: "UPDATE pending_action SET sourceFolderId = ? WHERE sourceFolderId = ?",
                arguments: [target, folder.raw])
            // A move queued to the folder now goes to the one it gave way to.
            for row in try Row.fetchAll(
                database, sql: "SELECT id, action FROM pending_action WHERE accountId = ?", arguments: [account]) {
                guard let id = row["id"] as Int64?, let data = row["action"] as Data?,
                      case let .moveTo(message, destination)? = try? JSONDecoder().decode(MailAction.self, from: data),
                      destination == folder
                else { continue }
                try database.execute(
                    sql: "UPDATE pending_action SET action = ? WHERE id = ?",
                    arguments: [try JSONEncoder().encode(MailAction.moveTo(message, FolderID(raw: target))), id])
            }
            try database.execute(sql: "DELETE FROM folder WHERE id = ?", arguments: [folder.raw])
        }
    }
}

extension MailStore {
    /// The first value is now; another follows each change to the accounts, their folders or a
    /// folder's unread count (new mail, a message read, a sync of the folder list). Only the newest
    /// unseen change is kept. If the database can't be watched any more, the stream ends with that error.
    public func observeFolders() -> AsyncThrowingStream<Void, any Error> {
        let observation = ValueObservation.tracking { database in
            // Compared as text: a row is not Sendable.
            try Row.fetchAll(database, sql: "SELECT * FROM account").map(\.description)
                + Row.fetchAll(
                    database,
                    sql: """
                        SELECT f.*, (SELECT COUNT(*) FROM message m WHERE m.folderId = f.id AND m.isRead = 0)
                            AS unread FROM folder f
                        """
                ).map(\.description)
        }.removeDuplicates()
        let queue = queue
        return AsyncThrowingStream(Void.self, bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                do {
                    for try await _ in observation.values(in: queue) { continuation.yield() }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
