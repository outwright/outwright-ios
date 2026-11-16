// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import GRDB

extension Schema {
    /// Local new-mail notices: a row per account with them on, holding how far its Inbox has been
    /// announced and when that mark was set.
    static func registerNewMailNotices(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("newMailNotices") { database in
            try database.execute(
                sql: """
                    CREATE TABLE new_mail_notice (
                        accountId TEXT PRIMARY KEY REFERENCES account(id) ON DELETE CASCADE,
                        uidValidity INTEGER NOT NULL, lastUID INTEGER NOT NULL, markedAt REAL NOT NULL)
                    """)
        }
    }
}
