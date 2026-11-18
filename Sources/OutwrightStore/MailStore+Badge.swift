// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import GRDB
import OutwrightModel

/// The app icon's badge: unread mail in every account's Inbox.
extension MailStore {
    /// Unread messages in every account's Inbox; only Focused ones when `focusedOnly`.
    public func unreadInboxCount(focusedOnly: Bool) throws(StoreError) -> Int {
        try read { database in try Self.unreadInboxCount(database, focusedOnly: focusedOnly) }
    }

    /// `unreadInboxCount`, again whenever this store's mail changes (and on `lookAgain`).
    public func observeUnreadInboxCount(focusedOnly: Bool) -> AsyncStream<Int> {
        let observation = ValueObservation.tracking { database in
            try Self.unreadInboxCount(database, focusedOnly: focusedOnly)
        }.removeDuplicates()
        let queue = queue
        return AsyncStream { continuation in
            let task = Task {
                do {
                    for try await count in observation.values(in: queue) {
                        continuation.yield(count)
                    }
                } catch {}
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func unreadInboxCount(_ database: Database, focusedOnly: Bool) throws -> Int {
        try Int.fetchOne(
            database,
            sql: """
                SELECT COUNT(*) FROM message m JOIN folder f ON f.id = m.folderId
                WHERE f.kind = ? AND m.isRead = 0 AND (? = 0 OR m.inboxClass = ?)
                """,
            arguments: [FolderKind.inbox.rawValue, focusedOnly, InboxClass.focused.rawValue]) ?? 0
    }
}
