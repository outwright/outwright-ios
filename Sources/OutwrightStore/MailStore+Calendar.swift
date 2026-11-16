// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
import GRDB
public import OutwrightModel

// swiftlint:disable large_tuple
extension MailStore {
    // MARK: Calendars

    public func calendars(_ account: AccountID) throws(StoreError) -> [CalendarInfo] {
        try read { database in
            try Row.fetchAll(
                database, sql: "SELECT * FROM calendar WHERE accountId = ? AND gone = 0 ORDER BY name, id",
                arguments: [account.raw.uuidString]
            ).compactMap(CalendarRecords.calendar)
        }
    }

    public func allCalendars() throws(StoreError) -> [CalendarInfo] {
        try read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT c.* FROM calendar c LEFT JOIN account a ON a.id = c.accountId WHERE c.gone = 0
                    ORDER BY c.accountId IS NULL, a.sortOrder, a.email, c.name, c.id
                    """
            ).compactMap(CalendarRecords.calendar)
        }
    }

    /// Calendars are matched by href; no colour given means the palette's. Subscribed calendars are
    /// not the server's and are left alone. A calendar no longer given
    /// is removed with its events, except the events with a queued change: those stay (marked
    /// `changeFailed`, the change dropped) in a calendar that is no longer listed. An event the owner
    /// deleted goes with the calendar.
    public func replaceCalendars(
        _ cals: [(href: String, name: String, color: Int?, isReadOnly: Bool)], for account: AccountID
    ) throws(StoreError) {
        try write { database in
            let key = account.raw.uuidString
            // An account without CalDAV keeps no calendars (one turned off during a sync stays empty).
            let cals = try Self.hasCalDAV(database, account: key) ? Array(cals.prefix(100)) : []
            for cal in cals {
                let color = cal.color ?? CalendarPalette.color(account: account, href: cal.href)
                try database.execute(
                    sql: """
                        INSERT INTO calendar (accountId, href, name, color, isReadOnly) VALUES (?, ?, ?, ?, ?)
                        ON CONFLICT(accountId, href) DO UPDATE SET name = excluded.name,
                            color = excluded.color, isReadOnly = excluded.isReadOnly, gone = 0
                        """, arguments: [key, cal.href, cal.name, color & 0xFF_FFFF, cal.isReadOnly])
            }
            let keep = Set(cals.map(\.href))
            let known = try Row.fetchAll(
                database,
                sql: """
                    SELECT id, href FROM calendar WHERE accountId = ?
                    """, arguments: [key])
            for cal in known {
                guard let id = cal["id"] as Int64?, let href = cal["href"] as String?, !keep.contains(href)
                else { continue }
                try Self.dropDeleted(database, calendar: id)
                try database.execute(
                    sql: """
                        DELETE FROM event WHERE calendarId = ? AND NOT \(CalendarRecords.protected)
                        """, arguments: [id])
                try database.execute(
                    sql: """
                        UPDATE event SET changeFailed = 1, pendingEditJSON = NULL
                        WHERE calendarId = ? AND conflictJSON IS NULL
                        """,
                    arguments: [id])
                let left = try Int.fetchOne(
                    database, sql: "SELECT COUNT(*) FROM event WHERE calendarId = ?", arguments: [id])
                if (left ?? 0) == 0 {
                    try database.execute(sql: "DELETE FROM calendar WHERE id = ?", arguments: [id])
                } else {
                    try database.execute(sql: "UPDATE calendar SET gone = 1 WHERE id = ?", arguments: [id])
                }
            }
        }
    }

    /// Removes the events of the calendar that the owner has deleted (their delete is queued).
    private static func dropDeleted(_ database: Database, calendar: Int64) throws {
        let rows = try Row.fetchAll(
            database, sql: "SELECT id, pendingEditJSON FROM event WHERE calendarId = ? AND pendingEditJSON IS NOT NULL",
            arguments: [calendar])
        for row in rows {
            guard let id = row["id"] as Int64?,
                CalendarRecords.decodeEdits(row["pendingEditJSON"] as String?).contains(.delete(scope: .event))
            else { continue }
            try database.execute(sql: "DELETE FROM event WHERE id = ?", arguments: [id])
        }
    }

    public func setDefaultCalendar(_ id: CalendarID) throws(StoreError) {
        try write { database in
            guard try Int64.fetchOne(database, sql: "SELECT id FROM calendar WHERE id = ?", arguments: [id.raw]) != nil
            else { throw StoreError.noSuchCalendar }
            try database.execute(sql: "UPDATE calendar SET isDefault = (id = ?)", arguments: [id.raw])
        }
    }

    /// The calendar the owner flagged, else the first writable calendar of the first account.
    public func defaultCalendar() throws(StoreError) -> CalendarInfo? {
        try read { database in
            let flagged = try Row.fetchOne(
                database, sql: "SELECT * FROM calendar WHERE isDefault = 1 AND gone = 0 AND isReadOnly = 0 LIMIT 1")
            if let flagged, let cal = CalendarRecords.calendar(flagged) { return cal }
            return try Row.fetchOne(
                database,
                sql: """
                    SELECT c.* FROM calendar c JOIN account a ON a.id = c.accountId
                    WHERE c.gone = 0 AND c.isReadOnly = 0 ORDER BY a.sortOrder, a.email, c.id LIMIT 1
                    """
            ).flatMap(CalendarRecords.calendar)
        }
    }

    public func syncToken(_ cal: CalendarID) throws(StoreError) -> String? {
        try read { database in
            try String.fetchOne(database, sql: "SELECT syncToken FROM calendar WHERE id = ?", arguments: [cal.raw])
        }
    }

    public func setSyncToken(_ token: String?, for cal: CalendarID) throws(StoreError) {
        try write { database in
            try database.execute(sql: "UPDATE calendar SET syncToken = ? WHERE id = ?", arguments: [token, cal.raw])
        }
    }

    /// The first day (yyyymmdd) the calendar's events have been listed from.
    public func windowListedFrom(_ cal: CalendarID) throws(StoreError) -> Int? {
        try read { database in
            try Int.fetchOne(database, sql: "SELECT windowListedFrom FROM calendar WHERE id = ?", arguments: [cal.raw])
        }
    }

    public func setWindowListedFrom(_ day: Int, for cal: CalendarID) throws(StoreError) {
        try write { database in
            try database.execute(
                sql: "UPDATE calendar SET windowListedFrom = ? WHERE id = ?", arguments: [day, cal.raw])
        }
    }

    // MARK: From the server

    /// href to ETag of every calendar object of the calendar that the server has (not one only created here).
    public func remoteETags(_ cal: CalendarID) throws(StoreError) -> [String: String] {
        try read { database in
            var result: [String: String] = [:]
            let rows = try Row.fetchAll(
                database, sql: "SELECT href, etag FROM event WHERE calendarId = ? AND href IS NOT NULL",
                arguments: [cal.raw])
            for row in rows {
                if let href = row["href"] as String? { result[href] = (row["etag"] as String?) ?? "" }
            }
            return result
        }
    }

    /// Stores a calendar object as the server has it, with its occurrences in the window, and the
    /// `Schedule-Tag` it came with (nil for none). One with no occurrence in the window is not kept.
    /// An event with a change queued is left alone: false. The app's own copy of the same invitation
    /// (same account and UID, another address) gives way to it (`mergeAppCopies`).
    @discardableResult
    // swiftlint:disable:next function_parameter_count
    public func upsertRemote(
        href: String, etag: String, ics: Data, series: EventSeries, in cal: CalendarID,
        window: ClosedRange<Date>, phoneZone: TimeZone, scheduleTag: String?
    ) throws(StoreError) -> Bool {
        try write { database in
            guard let calendar = try Row.fetchOne(
                database, sql: "SELECT accountId FROM calendar WHERE id = ?", arguments: [cal.raw])
            else { throw StoreError.noSuchCalendar }
            // None for a subscribed calendar, which belongs to no account.
            let account = calendar["accountId"] as String?
            let expansion = Expansion(from: window.lowerBound, to: window.upperBound, zone: phoneZone)
            try expansion.save(database)
            let existing = try Row.fetchOne(
                database,
                sql: """
                    SELECT id, pendingEditJSON, changeFailed, conflictJSON, appliedIcs, seriesJSON FROM event
                    WHERE calendarId = ? AND href = ?
                    """,
                arguments: [cal.raw, href])
            let id = existing?["id"] as Int64?
            if existing != nil {
                if (existing?["pendingEditJSON"] as String?) != nil { return false }
                if ((existing?["changeFailed"] as Int?) ?? 0) != 0 { return false }
                if (existing?["conflictJSON"] as String?) != nil { return false }
            }
            let inWindow = !Recurrence.occurrences(
                series, from: window.lowerBound, to: window.upperBound, phoneZone: phoneZone).isEmpty
            guard inWindow else {
                if let id { try database.execute(sql: "DELETE FROM event WHERE id = ?", arguments: [id]) }
                return true
            }
            if let id, let existing,
                try Self.keepsAppliedChange(
                    database, id, existing, server: (series, etag, ics, scheduleTag)) {
                return true
            }
            let eventID: Int64
            if let id {
                try database.execute(
                    sql: "UPDATE event SET etag = ?, ics = ?, scheduleTag = ? WHERE id = ?",
                    arguments: [etag, ics, scheduleTag, id])
                eventID = id
            } else {
                try database.execute(
                    sql: """
                        INSERT INTO event (accountId, calendarId, href, etag, ics, uid, seriesJSON, scheduleTag)
                        VALUES (?, ?, ?, ?, ?, ?, '{}', ?)
                        """, arguments: [account, cal.raw, href, etag, ics, series.uid, scheduleTag])
                eventID = database.lastInsertedRowID
            }
            try CalendarRecords.save(database, series, event: eventID)
            try CalendarRecords.expand(database, event: eventID, series: series, expansion)
            // The app's own copies are an account's; a subscribed calendar's events have none.
            if account != nil { try Self.mergeAppCopies(database, into: eventID) }
            return true
        }
    }

    /// Drops the calendar objects the server no longer has, except those with a change queued.
    public func removeRemote(hrefs: [String], in cal: CalendarID) throws(StoreError) {
        try write { database in
            for href in hrefs {
                try database.execute(
                    sql: "DELETE FROM event WHERE calendarId = ? AND href = ? AND NOT \(CalendarRecords.protected)",
                    arguments: [cal.raw, href])
            }
        }
    }

    // MARK: Reading

    /// The first value is now; another follows each change to the stored calendars, events or their
    /// occurrences (a sync, an edit, a new layout). Only the newest unseen change is kept. If the
    /// database can't be watched any more, the stream ends with that error.
    public func observeCalendars() -> AsyncThrowingStream<Void, any Error> {
        let observation = ValueObservation.tracking { database in
            [
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM calendar") ?? 0,
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM event") ?? 0,
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM occurrence") ?? 0
            ]
        }
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

    /// The occurrences overlapping [from, to), all-day ones first, then by start. An all-day
    /// occurrence is in the range when one of its days is a day of the range on the phone.
    public func occurrences(
        from: Date, to: Date, in calendars: Set<CalendarID>?
    ) throws(StoreError) -> [CalendarEvent] {
        if let calendars, calendars.isEmpty { return [] }
        return try read { database in
            let expansion = try Expansion.current(database)
            let first = expansion.dayKey(from)
            let last = expansion.dayKey(max(from, to.addingTimeInterval(-0.001)))
            var arguments: [any DatabaseValueConvertible] = [
                to.timeIntervalSince1970, from.timeIntervalSince1970, from.timeIntervalSince1970,
                to.timeIntervalSince1970, last, first
            ]
            var filter = ""
            if let calendars {
                filter = " AND e.calendarId IN (\(calendars.map { _ in "?" }.joined(separator: ", ")))"
                arguments += calendars.map { $0.raw }
            }
            let rows = try Row.fetchAll(
                database,
                sql: """
                    \(CalendarRecords.occurrenceSelect)
                    WHERE ((o.allDayStart IS NULL AND ((o.startUTC < ? AND o.endUTC > ?)
                        OR (o.endUTC <= o.startUTC AND o.startUTC >= ? AND o.startUTC < ?)))
                        OR (o.allDayStart IS NOT NULL AND o.allDayStart <= ? AND o.allDayEnd > ?))
                        AND e.hidden = 0\(filter)
                    ORDER BY (o.allDayStart IS NULL), o.startUTC, o.endUTC, o.eventId LIMIT 20000
                    """,
                arguments: StatementArguments(arguments))
            // An occurrence of an invitation the owner declined alone is not shown either.
            return rows.compactMap(CalendarRecords.event).filter { !($0.isInvitation && $0.ownResponse == .declined) }
        }
    }

    /// One occurrence of an event; the first when `occurrence` is nil. Nil when none is held.
    public func event(_ id: EventID, occurrence: EventTime?) throws(StoreError) -> CalendarEvent? {
        try read { database in
            try Self.find(database, where: "o.eventId = ?", [id.raw], occurrence)
        }
    }

    /// The event of the account with this UID in its own calendars, and its occurrence with this
    /// RECURRENCE-ID (the first when nil): how an invitation in mail finds its event.
    public func event(accountId: AccountID, uid: String, recurrenceID: EventTime?) throws(StoreError)
        -> CalendarEvent? {
        try read { database in
            try Self.find(
                database,
                where: CalendarRecords.ownByUID,
                [accountId.raw.uuidString, uid], recurrenceID)
        }
    }

    static func find(
        _ database: Database, where clause: String, _ arguments: [any DatabaseValueConvertible],
        _ occurrence: EventTime?
    ) throws -> CalendarEvent? {
        let rows = try Row.fetchAll(
            database,
            sql: "\(CalendarRecords.occurrenceSelect) WHERE \(clause) ORDER BY o.startUTC, o.eventId LIMIT 5000",
            arguments: StatementArguments(arguments))
        let events = rows.compactMap(CalendarRecords.event)
        guard let occurrence else { return events.first }
        return events.first { $0.occurrence.recurrenceID == occurrence }
    }

    public func series(_ id: EventID) throws(StoreError) -> EventSeries? {
        try read { database in
            CalendarRecords.decodeSeries(
                try String.fetchOne(database, sql: "SELECT seriesJSON FROM event WHERE id = ?", arguments: [id.raw]))
        }
    }

    // MARK: Accounts

    /// CalDAV was turned off for the account: its calendars and events go from this phone (the server
    /// keeps them), unsent changes with them.
    public func clearCalendars(of account: AccountID) throws(StoreError) {
        try write { database in
            try database.execute(
                sql: "DELETE FROM calendar WHERE accountId = ?", arguments: [account.raw.uuidString])
        }
    }

    /// How many of the account's event changes are not on the server yet.
    public func pendingEventChangeCount(_ account: AccountID) throws(StoreError) -> Int {
        try read { database in
            try Int.fetchOne(
                database, sql: "SELECT COUNT(*) FROM event WHERE accountId = ? AND pendingEditJSON IS NOT NULL",
                arguments: [account.raw.uuidString]) ?? 0
        }
    }

    /// The account has calendars: a CalDAV address, or Graph.
    static func hasCalDAV(_ database: Database, account: String) throws -> Bool {
        let row = try Row.fetchOne(
            database, sql: "SELECT calDAV, calendarVia FROM account WHERE id = ?", arguments: [account])
        return hasCalendarSource(row)
    }
}
// swiftlint:enable large_tuple
