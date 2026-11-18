// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import GRDB
public import OutwrightModel

/// An event row with what an owner's edit needs to know.
struct EventRow {
    var id: Int64
    var account: String
    var href: String?
    var newHref: String?
    var calendarReadOnly: Bool
    var email: String
    var hasCalDAV: Bool
    var series: EventSeries?
    /// The queued edits, in order.
    var pending: [EventEdit]
    var pendingJSON: String?
    var revision: Int

    static func fetch(_ database: Database, _ id: EventID) throws -> EventRow {
        guard
            let row = try Row.fetchOne(
                database,
                sql: """
                    SELECT e.id, e.accountId, e.href, e.newHref, e.seriesJSON, e.pendingEditJSON,
                        e.revision, c.isReadOnly, a.email, a.calDAV, a.calendarVia
                    FROM event e JOIN calendar c ON c.id = e.calendarId JOIN account a ON a.id = e.accountId
                    WHERE e.id = ?
                    """, arguments: [id.raw])
        else { throw StoreError.noSuchEvent }
        return EventRow(
            id: id.raw, account: (row["accountId"] as String?) ?? "", href: row["href"] as String?,
            newHref: row["newHref"] as String?,
            calendarReadOnly: ((row["isReadOnly"] as Int?) ?? 1) != 0, email: (row["email"] as String?) ?? "",
            hasCalDAV: MailStore.hasCalendarSource(row),
            series: CalendarRecords.decodeSeries(row["seriesJSON"] as String?),
            pending: CalendarRecords.decodeEdits(row["pendingEditJSON"] as String?),
            pendingJSON: row["pendingEditJSON"] as String?, revision: (row["revision"] as Int?) ?? 0)
    }

    /// True when the owner's delete of the whole event is queued: the event is gone from the views.
    var isDeleted: Bool { pending.contains(.delete(scope: .event)) }
}

/// The edits of the owner, applied to a series.
enum EventEditing {
    /// Splitting a range only compares instants of one series, so any fixed zone serves; the sync's
    /// writer uses the same one.
    private static let splitZone = TimeZone(identifier: "UTC") ?? .gmt

    /// The series after the edit; nil when the edit deletes the whole event. `.create` is not an edit
    /// of a series that exists and leaves it as it is. `email` is the account's: whose answer
    /// `.respond` sets.
    static func apply(_ edit: EventEdit, to series: EventSeries, email: String) -> EventSeries? {
        switch edit {
        case let .respond(response, scope, _, _):
            return changing(series, scope, everyOverride: true) {
                EventOwnership.answering($0, response, accountEmail: email)
            }
        case let .guestAnswer(guest, response, scope):
            // A series answer holds for the occurrences the guest has not answered on their own.
            var next = changing(series, scope, everyOverride: false) {
                EventOwnership.answering($0, response, accountEmail: guest)
            }
            if scope == .event {
                for index in next.overrides.indices
                where next.overrides[index].details.attendees.contains(where: {
                    $0.email.lowercased() == guest.lowercased() && $0.response == .needsAction
                }) {
                    next.overrides[index].details = EventOwnership.answering(
                        next.overrides[index].details, response, accountEmail: guest)
                }
            }
            return next
        case let .ownReminder(minutes, scope):
            return changing(series, scope, everyOverride: false) { details in
                var details = details
                details.reminder = minutes
                return details
            }
        case .create, .organiserChange:
            return series
        case let .update(details, rule, scope):
            return updating(series, details, rule: rule, scope: scope)
        case let .delete(scope):
            guard case let .occurrence(time) = scope else { return nil }
            var next = alone(series, at: time, as: nil)
            if !next.exdates.contains(time) { next.exdates.append(time) }
            return next
        }
    }

    private static func updating(
        _ series: EventSeries, _ details: EventDetails, rule: RecurrenceRule?, scope: EditScope
    ) -> EventSeries {
        if case let .occurrence(time) = scope {
            return alone(series, at: time, as: EventOverride(recurrenceID: time, details: details))
        }
        return changed(series, to: details, rule: rule)
    }

    /// The series with `change` made to the series event, or to one occurrence alone. For the whole
    /// event the overrides change too when `everyOverride` (an answer holds for every occurrence), or
    /// when there is no series event (an invitation to some occurrences only). An occurrence the
    /// series has no event to lay out from is left as it is.
    private static func changing(
        _ series: EventSeries, _ scope: EditScope, everyOverride: Bool, _ change: (EventDetails) -> EventDetails
    ) -> EventSeries {
        var next = series
        switch scope {
        case .event:
            if let base = series.base { next.base = change(base) }
            if series.base == nil || everyOverride {
                for index in next.overrides.indices {
                    next.overrides[index].details = change(next.overrides[index].details)
                }
            }
        case let .occurrence(time):
            guard var own = Recurrence.ownOverride(at: time, in: series, phoneZone: splitZone) else { return series }
            own.details = change(own.details)
            next = alone(series, at: time, as: own)
        }
        return next
    }

    /// The whole series changed. A new time or rule makes every exception meaningless; a new title does
    /// not, and a range keeps what it changed on purpose and follows the series in the rest.
    private static func changed(_ series: EventSeries, to details: EventDetails, rule: RecurrenceRule?)
        -> EventSeries {
        var next = series
        next.base = details
        next.rule = rule
        let moved = series.base?.start != details.start || series.base?.end != details.end || series.rule != rule
        if moved {
            next.overrides = []
            next.exdates = []
        } else if let old = series.base {
            next.overrides = series.overrides.map { override in
                guard override.thisAndFuture else { return override }
                var followed = override
                followed.details = override.details.following(seriesFrom: old, to: details)
                return followed
            }
        }
        return next
    }

    /// The series with `override` (or none) in place of the override at `time`, so that occurrence
    /// changes or goes alone: a range it started carries on from the next occurrence.
    private static func alone(_ series: EventSeries, at time: EventTime, as override: EventOverride?)
        -> EventSeries {
        var next = series
        let carried = Recurrence.rangeAfter(time, in: series, phoneZone: splitZone)
        next.overrides.removeAll { $0.recurrenceID == time }
        if let override { next.overrides.append(override) }
        if let carried { next.overrides.append(carried) }
        return next
    }
}

extension MailStore {
    // MARK: The owner's edits

    public func createEvent(
        _ details: EventDetails, rule: RecurrenceRule?, in cal: CalendarID
    ) throws(StoreError) -> EventID {
        let (id, account): (EventID, String) = try write { database in
            guard
                let row = try Row.fetchOne(
                    database,
                    sql: """
                        SELECT c.accountId, c.isReadOnly, a.calDAV, a.calendarVia FROM calendar c
                        JOIN account a ON a.id = c.accountId WHERE c.id = ?
                        """, arguments: [cal.raw]),
                let account = row["accountId"] as String?
            else { throw StoreError.noSuchCalendar }
            if !Self.hasCalendarSource(row) {
                throw StoreError.noCalDAV
            }
            if ((row["isReadOnly"] as Int?) ?? 1) != 0 { throw StoreError.readOnly }
            let series = EventSeries(uid: UUID().uuidString.lowercased(), base: details, rule: rule)
            try database.execute(
                sql: """
                    INSERT INTO event (accountId, calendarId, uid, seriesJSON, pendingEditJSON, revision)
                    VALUES (?, ?, ?, '{}', ?, 1)
                    """,
                arguments: [
                    account, cal.raw, series.uid, CalendarRecords.encode([.create(details, rule: rule)])
                ])
            let id = database.lastInsertedRowID
            try CalendarRecords.save(database, series, event: id)
            try CalendarRecords.expand(database, event: id, series: series, try Expansion.current(database))
            return (EventID(raw: id), account)
        }
        announce(account: account)
        return id
    }

    /// Changes the whole series (or the single event), or one occurrence of it.
    public func updateEvent(
        _ id: EventID, _ details: EventDetails, rule: RecurrenceRule?, scope: EditScope
    ) throws(StoreError) {
        try edit(id, .update(details, rule: rule, scope: scope))
    }

    /// The event is hidden until the delete is sent; an occurrence deleted is left out of the series.
    public func deleteEvent(_ id: EventID, scope: EditScope) throws(StoreError) {
        try edit(id, .delete(scope: scope))
    }

    func edit(_ id: EventID, _ edit: EventEdit) throws(StoreError) {
        let account: String = try write { database in
            let row = try EventRow.fetch(database, id)
            if row.isDeleted { throw StoreError.noSuchEvent }
            if !row.hasCalDAV { throw StoreError.noCalDAV }
            guard let series = row.series else { throw StoreError.unreadableEvent }
            guard
                CalendarRecords.allows(
                    edit, calendarReadOnly: row.calendarReadOnly, series: series, email: row.email)
            else { throw StoreError.readOnly }
            try Self.queue(database, row, series: series, edit)
            return row.account
        }
        announce(account: account)
    }

    /// Applies the edit to the series at once and queues it after the edits already queued, in order,
    /// so that the sync can send each one. The one fold: a delete of the whole event replaces what was
    /// queued (an event the server never had stays a queued delete without an address, which the
    /// sync drops without a request while no create target was chosen).
    /// `settles`: the edit is the owner's, and settles a held conflict or failed change; a guest's
    /// answer from mail leaves them for the owner.
    static func queue(
        _ database: Database, _ row: EventRow, series: EventSeries, _ edit: EventEdit, settles: Bool = true
    ) throws {
        // A newer answer (or the event going) replaces an older one whose reply could not be queued.
        switch edit {
        case let .respond(_, scope, _, _):
            try clearFailedReply(database, row.id, coveredBy: scope)
            try clearServerReplied(database, row.id, coveredBy: scope)
        case .delete(scope: .event): try clearFailedReply(database, row.id, coveredBy: nil)
        default: break
        }
        guard let next = EventEditing.apply(edit, to: series, email: row.email) else {
            try database.execute(
                sql: """
                    UPDATE event SET pendingEditJSON = ?, changeFailed = 0, conflictJSON = NULL, attempts = 0,
                        revision = revision + 1 WHERE id = ?
                    """, arguments: [CalendarRecords.encode([.delete(scope: .event)]), row.id])
            try database.execute(sql: "DELETE FROM occurrence WHERE eventId = ?", arguments: [row.id])
            return
        }
        try database.execute(
            sql: settles
                ? """
                    UPDATE event SET pendingEditJSON = ?, changeFailed = 0, conflictJSON = NULL, attempts = 0,
                        revision = revision + 1 WHERE id = ?
                    """
                : "UPDATE event SET pendingEditJSON = ?, attempts = 0, revision = revision + 1 WHERE id = ?",
            arguments: [CalendarRecords.encode(row.pending + [edit]), row.id])
        try CalendarRecords.save(database, next, event: row.id)
        try CalendarRecords.expand(database, event: row.id, series: next, try Expansion.current(database))
    }

    func announce(account: String) {
        if let uuid = UUID(uuidString: account) { announceQueued(AccountID(raw: uuid)) }
    }
}
