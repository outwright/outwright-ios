// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
import GRDB
public import OutwrightModel

extension MailStore {
    /// The calendar object as the server last gave it; nil for an event the server never had.
    public func serverEvent(_ id: EventID) throws(StoreError) -> Data? {
        try read { database in
            try Data.fetchOne(database, sql: "SELECT ics FROM event WHERE id = ?", arguments: [id.raw])
        }
    }

    /// The owner gave up a change the server did not take: the server's version (`series` read from
    /// `serverEvent`) is the event again, and the change, its failure and any held conflict go. An
    /// event the server never had (no address) is removed. For every event the server has, its tag
    /// and its calendar's sync token go, since the server may have changed it while the failure
    /// waited: the next sync lists the calendar's window and fetches it again, and the server's
    /// object replaces what is shown (`series` nil when the held object can't be read).
    public func restoreEventServerVersion(_ id: EventID, series: EventSeries?) throws(StoreError) {
        let account: String = try write { database in
            let row = try EventRow.fetch(database, id)
            guard row.href != nil else {
                try database.execute(sql: "DELETE FROM event WHERE id = ?", arguments: [id.raw])
                return row.account
            }
            try database.execute(
                sql: """
                    UPDATE event SET pendingEditJSON = NULL, changeFailed = 0, conflictJSON = NULL, attempts = 0,
                        newHref = NULL, newIcs = NULL, revision = revision + 1, failedReplyJSON = NULL WHERE id = ?
                    """, arguments: [id.raw])
            // The server may have changed it while the failure waited, which sync did not apply: its
            // tag and its calendar's sync token go, so the next sync lists the calendar and fetches it.
            try database.execute(sql: "UPDATE event SET etag = NULL WHERE id = ?", arguments: [id.raw])
            try database.execute(
                sql: "UPDATE calendar SET syncToken = NULL WHERE id = (SELECT calendarId FROM event WHERE id = ?)",
                arguments: [id.raw])
            guard let series else { return row.account }
            try CalendarRecords.save(database, series, event: id.raw)
            try CalendarRecords.expand(database, event: id.raw, series: series, try Expansion.current(database))
            return row.account
        }
        announce(account: account)
    }
}
