// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import GRDB

extension Schema {
    /// v12: search over events and suggestions. Each occurrence keeps its words as searched
    /// (`searchText`, see `CalendarRecords.searchText`), and the events held are laid out again so
    /// the ones already stored get theirs; `message_vocab` reads the words of the mail search index,
    /// with how many messages hold each.
    static func registerSearch(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v12") { database in
            try database.execute(sql: """
                ALTER TABLE occurrence ADD COLUMN searchText TEXT NOT NULL DEFAULT '';
                CREATE VIRTUAL TABLE message_vocab USING fts5vocab(message_fts, row);
                """)
            let expansion = try Expansion.current(database)
            let rows = try Row.fetchAll(database, sql: "SELECT id, seriesJSON, pendingEditJSON FROM event")
            for row in rows {
                guard let id = row["id"] as Int64? else { continue }
                if CalendarRecords.decodeEdits(row["pendingEditJSON"] as String?).contains(.delete(scope: .event)) {
                    continue
                }
                guard let series = CalendarRecords.decodeSeries(row["seriesJSON"] as String?) else { continue }
                try CalendarRecords.expand(database, event: id, series: series, expansion)
            }
        }
    }
}
