// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import GRDB
public import OutwrightModel

/// Rows the server hasn't numbered yet, and the changes queued for them.
extension MailStore {
    /// Completes a change and, in the same step, drops `message`'s stray copy (`dropStrayCopy`).
    public func completeAction(_ id: Int64, droppingStrayCopyOf message: MessageID) throws(StoreError) {
        try write { database in
            try database.execute(sql: "DELETE FROM pending_action WHERE id = ?", arguments: [id])
            try Self.dropStray(database, message, in: nil)
        }
    }

    /// Drops `message`'s row (in `folder`, when given) if it waits for a number the server will
    /// never give it: the server once had the message, so the folder that holds it brings it back
    /// at its next sync. A row only the phone has (never numbered: a draft never saved), or one a
    /// send, a draft save or a filing still waits on, is never dropped.
    public func dropStrayCopy(_ message: MessageID, in folder: FolderID?) throws(StoreError) {
        try write { database in try Self.dropStray(database, message, in: folder) }
    }

    private static func dropStray(_ database: Database, _ message: MessageID, in folder: FolderID?) throws {
        let waitedOn = try Row.fetchAll(database, sql: "SELECT action FROM pending_action").contains { row in
            guard let data = row["action"] as Data?,
                  let action = try? JSONDecoder().decode(MailAction.self, from: data)
            else { return false }
            switch action {
            case let .send(id), let .saveDraft(id), let .fileSent(id): return id == message
            default: return false
            }
        }
        guard !waitedOn else { return }
        let stray = "id = ? AND uid = 0 AND serverKnown = 1 AND (? IS NULL OR folderId = ?)"
        let arguments: StatementArguments = [message.raw, folder?.raw, folder?.raw]
        try database.execute(
            sql: "DELETE FROM message_fts WHERE rowid IN (SELECT id FROM message WHERE \(stray))", arguments: arguments)
        try database.execute(sql: "DELETE FROM message WHERE \(stray)", arguments: arguments)
    }

    /// The server gave `message` the number `uid` in `folder` (by the move queued as `move`), after
    /// the row had moved on: its changes queued in that folder after the move, up to and with the
    /// first that takes it out again, take this number. A later visit to the folder has its own.
    public func carryUID(_ uid: UInt32, of message: MessageID, in folder: FolderID, after move: Int64)
        throws(StoreError) {
        try write { database in
            let sql = "SELECT id, action, sourceFolderId, sourceUid FROM pending_action WHERE id > ? ORDER BY id"
            for row in try Row.fetchAll(database, sql: sql, arguments: [move]) {
                guard let id = row["id"] as Int64?, let data = row["action"] as Data?,
                      let action = try? JSONDecoder().decode(MailAction.self, from: data),
                      action.target == message
                else { continue }
                guard (row["sourceFolderId"] as Int64?) == folder.raw else { break }
                if (row["sourceUid"] as Int64?) ?? 0 == 0 {
                    try database.execute(
                        sql: "UPDATE pending_action SET sourceUid = ? WHERE id = ?", arguments: [Int64(uid), id])
                }
                switch action {
                case .move, .moveTo, .delete: return
                default: continue
                }
            }
        }
    }
}
