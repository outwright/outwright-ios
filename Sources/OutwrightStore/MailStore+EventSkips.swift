// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import GRDB
public import OutwrightModel

extension MailStore {
    // MARK: Calendar objects not kept

    /// href to (ETag, refused) of every calendar object of the calendar that the server listed and that
    /// is not kept as an event: one that could not be read (`refused`), or one with no occurrence in
    /// the window.
    public func skippedEvents(_ cal: CalendarID) throws(StoreError) -> [String: (etag: String, refused: Bool)] {
        try read { database in
            var result: [String: (etag: String, refused: Bool)] = [:]
            let rows = try Row.fetchAll(
                database, sql: "SELECT href, etag, refused FROM event_skipped WHERE calendarId = ?",
                arguments: [cal.raw])
            for row in rows {
                guard let href = row["href"] as String?, let etag = row["etag"] as String? else { continue }
                result[href] = (etag, ((row["refused"] as Int?) ?? 0) != 0)
            }
            return result
        }
    }

    /// Remembers a calendar object of the calendar that is not kept, at the ETag it was read at.
    public func setSkippedEvent(href: String, etag: String, refused: Bool, in cal: CalendarID) throws(StoreError) {
        try write { database in
            try database.execute(
                sql: "INSERT OR REPLACE INTO event_skipped (calendarId, href, etag, refused) VALUES (?, ?, ?, ?)",
                arguments: [cal.raw, href, etag, refused])
        }
    }

    public func removeSkippedEvents(hrefs: [String], in cal: CalendarID) throws(StoreError) {
        guard !hrefs.isEmpty else { return }
        try write { database in
            for href in hrefs {
                try database.execute(
                    sql: "DELETE FROM event_skipped WHERE calendarId = ? AND href = ?", arguments: [cal.raw, href])
            }
        }
    }

    /// How many of the calendar's objects on the server could not be read (malformed, or past a cap):
    /// they are not shown.
    public func refusedEventCount(_ cal: CalendarID) throws(StoreError) -> Int {
        try read { database in
            try Int.fetchOne(
                database, sql: "SELECT COUNT(*) FROM event_skipped WHERE calendarId = ? AND refused = 1",
                arguments: [cal.raw]) ?? 0
        }
    }

    /// Drops a queued delete of an event the server never had (no create was sent for it), with no
    /// request: the event goes. Nothing happens when the owner has edited it since `revision`.
    public func dropEventChange(_ id: EventID, revision: Int) throws(StoreError) {
        try write { database in
            let row: EventRow
            do {
                row = try EventRow.fetch(database, id)
            } catch StoreError.noSuchEvent {
                return
            }
            guard row.revision == revision, row.isDeleted else { return }
            try database.execute(sql: "DELETE FROM event WHERE id = ?", arguments: [id.raw])
        }
    }
}
