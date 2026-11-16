// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
import GRDB
public import OutwrightModel

// swiftlint:disable large_tuple function_parameter_count
extension MailStore {
    // MARK: The queue

    /// One entry per event with changes not yet sent, the edits in the order the owner made them (see
    /// `queue`). `revision` counts the owner's edits of the event: hand it back with the outcome of
    /// the send.
    public func pendingEventChanges(_ account: AccountID) throws(StoreError) -> [(
        event: EventID, edits: [EventEdit], href: String?, etag: String?, ics: Data?, calendar: CalendarID,
        revision: Int
    )] {
        try read { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT id, calendarId, href, etag, ics, pendingEditJSON, revision FROM event
                    WHERE accountId = ? AND pendingEditJSON IS NOT NULL ORDER BY id
                    """, arguments: [account.raw.uuidString])
            return rows.compactMap { row in
                guard let id = row["id"] as Int64?, let calendar = row["calendarId"] as Int64?,
                    case let edits = CalendarRecords.decodeEdits(row["pendingEditJSON"] as String?), !edits.isEmpty
                else { return nil }
                return (
                    EventID(raw: id), edits, row["href"] as String?, row["etag"] as String?, row["ics"] as Data?,
                    CalendarID(raw: calendar), (row["revision"] as Int?) ?? 0
                )
            }
        }
    }

    /// Where a create goes and the object it starts from, chosen at its first send and kept, so a
    /// send whose answer was lost is sent again to the same place with the same UID.
    public func eventCreateTarget(_ id: EventID) throws(StoreError) -> (href: String, ics: Data)? {
        try read { database in
            guard
                let row = try Row.fetchOne(
                    database, sql: "SELECT newHref, newIcs FROM event WHERE id = ?", arguments: [id.raw]),
                let href = row["newHref"] as String?, let ics = row["newIcs"] as Data?
            else { return nil }
            return (href, ics)
        }
    }

    public func setEventCreateTarget(_ id: EventID, href: String, ics: Data) throws(StoreError) {
        try write { database in
            // Only a create that is still queued has a place to go.
            guard case .create? = try EventRow.fetch(database, id).pending.first else { throw StoreError.noSuchEvent }
            try database.execute(
                sql: "UPDATE event SET newHref = ?, newIcs = ? WHERE id = ?", arguments: [href, ics, id.raw])
        }
    }

    /// The server took the change that was `revision` of the event: the object is now as sent (a
    /// delete of the event removes it). If the owner has edited since, the server's result is recorded
    /// (the object has an address and a tag now) and the newer change stays queued against it.
    /// `scheduleTag` is the `Schedule-Tag` the server answered with, nil for none. `builtOn` is the
    /// object the write was made from (`eventObject`): when it is the organiser's change from mail
    /// held apart, that is dropped, as the server now holds it.
    public func eventChangeDone(
        _ id: EventID, revision: Int, href: String, etag: String?, ics: Data, series: EventSeries,
        scheduleTag: String?, builtOn: Data? = nil
    ) throws(StoreError) {
        try write { database in
            _ = try Self.changeDone(
                database, id, revision: revision, href: href, etag: etag, ics: ics, series: series,
                scheduleTag: scheduleTag, builtOn: builtOn)
        }
    }

    /// `eventChangeDone` inside a write; returns the event as it was before, nil when it is gone.
    static func changeDone(
        _ database: Database, _ id: EventID, revision: Int, href: String, etag: String?, ics: Data,
        series: EventSeries, scheduleTag: String?, builtOn: Data?
    ) throws -> EventRow? {
        guard let row = try? EventRow.fetch(database, id) else { return nil }
        if let builtOn {
            try database.execute(
                sql: "UPDATE event SET appliedIcs = NULL WHERE id = ? AND appliedIcs = ?", arguments: [id.raw, builtOn])
        }
        if row.revision == revision {
            if row.isDeleted {
                try database.execute(sql: "DELETE FROM event WHERE id = ?", arguments: [id.raw])
                return row
            }
            try database.execute(
                sql: """
                    UPDATE event SET href = ?, etag = ?, ics = ?, pendingEditJSON = NULL, newHref = NULL,
                        newIcs = NULL, changeFailed = 0, attempts = 0, scheduleTag = ? WHERE id = ?
                    """, arguments: [href, etag, ics, scheduleTag, id.raw])
            try CalendarRecords.save(database, series, event: id.raw)
            try CalendarRecords.expand(database, event: id.raw, series: series, try Expansion.current(database))
            return row
        }
        // The edits up to `revision` were sent: the ones after them stay queued.
        let count = row.pending.count
        let sent = min(max(revision - (row.revision - count), 0), count)
        let left = Array(row.pending.dropFirst(sent))
        let pending = left.isEmpty ? nil : CalendarRecords.encode(left)
        try database.execute(
            sql: """
                UPDATE event SET href = ?, etag = ?, ics = ?, attempts = 0, newHref = NULL, newIcs = NULL,
                    pendingEditJSON = ?, scheduleTag = ? WHERE id = ?
                """, arguments: [href, etag, ics, pending, scheduleTag, id.raw])
        return row
    }

    /// The server held a newer version (a 412): it becomes the event, and the owner's edits go to
    /// `conflict`, any made while the send was in flight among them, so none is sent over the
    /// server's change. A queued delete is not sent: the event comes back as the server's version,
    /// marked as a failed change. With nothing queued (the owner discarded the change during the
    /// send) the server's version is simply taken.
    /// `scheduleTag` is the server copy's `Schedule-Tag`, nil for none.
    public func eventChangeConflicted(
        _ id: EventID, server: (etag: String, ics: Data, series: EventSeries), scheduleTag: String? = nil
    ) throws(StoreError) {
        try write { database in
            let row = try EventRow.fetch(database, id)
            // The server's version stands: an answer whose reply was owed is the owner's to give again.
            try Self.clearFailedReply(database, id.raw, coveredBy: nil)
            if !row.pending.isEmpty {
                try database.execute(
                    sql: "UPDATE event SET conflictJSON = ? WHERE id = ?",
                    arguments: [row.isDeleted ? nil : row.pendingJSON, id.raw])
            }
            try database.execute(
                sql: """
                    UPDATE event SET etag = ?, ics = ?, pendingEditJSON = NULL, changeFailed = ?, attempts = 0,
                        scheduleTag = ? WHERE id = ?
                    """, arguments: [server.etag, server.ics, row.isDeleted, scheduleTag, id.raw])
            try CalendarRecords.save(database, server.series, event: id.raw)
            try CalendarRecords.expand(
                database, event: id.raw, series: server.series, try Expansion.current(database))
        }
    }

    /// The change cannot be sent: it is dropped from the queue and the event marked. A newer edit
    /// than the one sent stays queued.
    public func eventChangeFailed(_ id: EventID, revision: Int) throws(StoreError) {
        try write { database in
            guard let row = try? EventRow.fetch(database, id), row.revision == revision else { return }
            try database.execute(
                sql: "UPDATE event SET pendingEditJSON = NULL, changeFailed = 1 WHERE id = ?", arguments: [id.raw])
            // A refused delete brings the event back.
            if row.isDeleted, let series = row.series {
                try CalendarRecords.expand(database, event: id.raw, series: series, try Expansion.current(database))
            }
        }
    }

    /// The server could not take the change that is `revision` of the event this time (its own
    /// trouble, not the connection's): counts the try and returns how many there have been.
    public func eventChangeAttempted(_ id: EventID, revision: Int) throws(StoreError) -> Int {
        try write { database in
            try database.execute(
                sql: "UPDATE event SET attempts = attempts + 1 WHERE id = ? AND revision = ?",
                arguments: [id.raw, revision])
            return try Int.fetchOne(database, sql: "SELECT attempts FROM event WHERE id = ?", arguments: [id.raw]) ?? 0
        }
    }

    // MARK: Conflicts

    /// Queues the owner's edits over the server's version, which is now the one held, in order. If the
    /// owner has edited since the conflict, those edits are kept and the conflict copy dropped. Refused
    /// when the server's version is no longer the owner's to change.
    public func applyEventConflictAgain(_ id: EventID) throws(StoreError) {
        let account: String? = try write { database in
            let row = try EventRow.fetch(database, id)
            let held = try String.fetchOne(
                database, sql: "SELECT conflictJSON FROM event WHERE id = ?", arguments: [id.raw])
            let own = CalendarRecords.decodeEdits(held)
            guard !own.isEmpty else { return nil }
            if !row.pending.isEmpty {
                try database.execute(
                    sql: "UPDATE event SET conflictJSON = NULL, changeFailed = 0 WHERE id = ?", arguments: [id.raw])
                return nil
            }
            guard let series = row.series else { throw StoreError.unreadableEvent }
            guard
                own.allSatisfy({
                    CalendarRecords.allows($0, calendarReadOnly: row.calendarReadOnly, series: series, email: row.email)
                })
            else { throw StoreError.readOnly }
            try database.execute(
                sql: "UPDATE event SET conflictJSON = NULL, changeFailed = 0 WHERE id = ?", arguments: [id.raw])
            for var edit in own {
                if case let .create(details, rule) = edit { edit = .update(details, rule: rule, scope: .event) }
                let current = try EventRow.fetch(database, id)
                guard let now = current.series else { break }
                try Self.queue(database, current, series: now, edit)
            }
            return row.account
        }
        if let account { announce(account: account) }
    }

    public func discardEventConflict(_ id: EventID) throws(StoreError) {
        try write { database in
            try database.execute(sql: "UPDATE event SET conflictJSON = NULL WHERE id = ?", arguments: [id.raw])
            try Self.clearFailedReply(database, id.raw, coveredBy: nil)
        }
    }
}
// swiftlint:enable large_tuple function_parameter_count
