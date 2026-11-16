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
