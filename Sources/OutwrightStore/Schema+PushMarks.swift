// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import GRDB

extension Schema {
    /// Push marks: a row per account a push has come for, holding how far its Inbox has been
    /// announced and when that mark was set (the columns of `new_mail_notice`, kept apart from it).
    static func registerPushMailMarks(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("pushMailMarks") { database in
            try database.execute(
                sql: """
                    CREATE TABLE push_mail_mark (
                        accountId TEXT PRIMARY KEY REFERENCES account(id) ON DELETE CASCADE,
                        uidValidity INTEGER NOT NULL, lastUID INTEGER NOT NULL, markedAt REAL NOT NULL)
                    """)
        }
    }
}
