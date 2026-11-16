// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import GRDB

extension Schema {
    /// v16: subscribed calendars (a published iCalendar address): its calendar row, the keychain key
    /// its address is kept under, the address's host, the last answer's validators and body hash,
    /// and the last fetch and its failure.
    static func registerSubscriptions(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v16") { database in
            try database.execute(
                sql: """
                    CREATE TABLE calendar_subscription (
                        calendarId INTEGER PRIMARY KEY REFERENCES calendar(id) ON DELETE CASCADE,
                        key TEXT NOT NULL UNIQUE, host TEXT NOT NULL,
                        etag TEXT, lastModified TEXT, bodyHash TEXT, fetchedAt REAL, failure TEXT)
                    """)
        }
    }

    /// v17: a subscribed calendar belongs to no account. `calendar.accountId` and `event.accountId`
    /// may be null, and the subscriptions and their events kept under an account lose it, so they
    /// stay when that account goes. SQLite can't drop a NOT NULL, so both tables are made again from
    /// their own definitions (SQLite's twelve steps; GRDB runs a migration with foreign keys off and
    /// checks them after).
    static func registerAccountlessSubscriptions(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v17") { database in
            for table in ["calendar", "event"] {
                try relaxAccount(of: table, database)
            }
            try database.execute(
                sql: """
                    UPDATE calendar SET accountId = NULL
                    WHERE id IN (SELECT calendarId FROM calendar_subscription);
                    UPDATE event SET accountId = NULL
                    WHERE calendarId IN (SELECT calendarId FROM calendar_subscription);
                    """)
        }
    }

    /// Makes the table again with `accountId` nullable, keeping its rows and indexes.
    private static func relaxAccount(of table: String, _ database: Database) throws {
        guard
            let definition = try String.fetchOne(
                database, sql: "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?", arguments: [table])
        else { return }
        let indexes = try String.fetchAll(
            database,
            sql: "SELECT sql FROM sqlite_master WHERE type = 'index' AND tbl_name = ? AND sql IS NOT NULL",
            arguments: [table])
        let relaxed = definition
            .replacingOccurrences(of: "accountId TEXT NOT NULL REFERENCES", with: "accountId TEXT REFERENCES")
            .replacingOccurrences(of: "CREATE TABLE \(table) (", with: "CREATE TABLE \(table)_new (")
        try database.execute(sql: relaxed)
        try database.execute(sql: "INSERT INTO \(table)_new SELECT * FROM \(table)")
        try database.execute(sql: "DROP TABLE \(table)")
        try database.execute(sql: "ALTER TABLE \(table)_new RENAME TO \(table)")
        for index in indexes {
            try database.execute(sql: index)
        }
    }
}
