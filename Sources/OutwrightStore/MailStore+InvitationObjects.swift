// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
import GRDB
public import OutwrightModel

/// The calendar object an invitation from mail is applied to, and the organiser's last change from
/// mail kept until the server's copy has caught up with it.
extension MailStore {
    /// The calendar object the event is held as: its create while that is not on the server, else the
    /// organiser's last change from mail while the server's copy is older, else the server's. Nil for
    /// none.
    public func eventObject(_ id: EventID) throws(StoreError) -> Data? {
        try read { database in
            guard
                let row = try Row.fetchOne(
                    database, sql: "SELECT ics, newIcs, appliedIcs FROM event WHERE id = ?", arguments: [id.raw])
            else { return nil }
            return (row["newIcs"] as Data?) ?? (row["appliedIcs"] as Data?) ?? (row["ics"] as Data?)
        }
    }

    /// The account's CalDAV server schedules (RFC 6638 › 2), as it last said: it sends the owner's
    /// answers to invitations itself. True until it has been asked.
    public func serverSchedules(_ account: AccountID) throws(StoreError) -> Bool {
        try read { database in
            try Bool.fetchOne(
                database, sql: "SELECT schedules FROM caldav_scheduling WHERE accountId = ?",
                arguments: [account.raw.uuidString]) ?? true
        }
    }

    public func setServerSchedules(_ schedules: Bool, for account: AccountID) throws(StoreError) {
        try write { database in
            try database.execute(
                sql: """
                    INSERT INTO caldav_scheduling (accountId, schedules) VALUES (?, ?)
                    ON CONFLICT(accountId) DO UPDATE SET schedules = excluded.schedules
                    """, arguments: [account.raw.uuidString, schedules])
        }
    }

    /// The event's copy is on the server: false only while its create has not landed there (and for
    /// no such event).
    public func isOnServer(_ id: EventID) throws(StoreError) -> Bool {
        try read { database in
            try Bool.fetchOne(database, sql: "SELECT href IS NOT NULL FROM event WHERE id = ?", arguments: [id.raw])
                ?? false
        }
    }

    /// Where the event's copy came from: the server's, or the app's own from an invitation in mail.
    /// Nil for no such event.
    public func eventOrigin(_ id: EventID) throws(StoreError) -> CopyOrigin? {
        try read { database in
            try String.fetchOne(database, sql: "SELECT origin FROM event WHERE id = ?", arguments: [id.raw])
                .map { CopyOrigin(rawValue: $0) ?? .server }
        }
    }

    /// The account had mail calling off the whole meeting with this UID at `sequence` or later: an
    /// invitation to it taken after that (one moved out of Junk) does not bring it back.
    public func isCalledOff(accountId: AccountID, uid: String, sequence: Int) throws(StoreError) -> Bool {
        try read { database in
            try Bool.fetchOne(
                database,
                sql: """
                    SELECT 1 FROM invitation_message i JOIN message m ON m.id = i.messageId
                    WHERE m.accountId = ? AND i.uid = ? AND i.method = 'CANCEL' AND i.recurrenceIdJSON IS NULL
                        AND i.sequence >= ?
                    LIMIT 1
                    """, arguments: [accountId.raw.uuidString, uid, sequence]) ?? false
        }
    }

    /// The account's event with this UID that is not a queued delete, whether or not it has an
    /// occurrence in the window: the event an invitation in mail is about.
    public func invitationEvent(accountId: AccountID, uid: String) throws(StoreError) -> EventID? {
        try read { database in
            try Self.liveEvent(database, account: accountId.raw.uuidString, uid: uid).map(EventID.init(raw:))
        }
    }

    /// The message's invitation was taken, and does not wait for the account's calendars.
    public func isInvitationRecorded(_ message: MessageID) throws(StoreError) -> Bool {
        try read { database in
            try Int64.fetchOne(
                database, sql: "SELECT messageId FROM invitation_message WHERE messageId = ? AND awaitingCalendar = 0",
                arguments: [message.raw]
            ) != nil
        }
    }

    /// Whether the intake has run for the message at all: taken, unreadable, or waiting for a calendar
    /// sync (which takes it again, not anything else).
    public func hasInvitationRecord(_ message: MessageID) throws(StoreError) -> Bool {
        try read { database in
            try Int64.fetchOne(
                database, sql: "SELECT messageId FROM invitation_message WHERE messageId = ?", arguments: [message.raw]
            ) != nil
        }
    }

    /// The message is marked as an invitation but its calendar part does not read as iTIP: it is
    /// kept as taken (no method, so `invitation(for:)` gives nil) and is never read again.
    public func recordUnreadableInvitation(_ message: MessageID) throws(StoreError) {
        try write { database in
            try Self.require(database, message)
            try database.execute(
                sql: """
                    INSERT OR REPLACE INTO invitation_message (messageId, method, uid, sequence, applied)
                    VALUES (?, '', '', 0, 0)
                    """, arguments: [message.raw])
        }
    }

    /// The account's messages held with their body that are invitations not yet taken (the intake
    /// failed, was moved out of Junk, or waits for the account's calendars), newest first, at most
    /// `limit`. Without `waitingForCalendars`, only those with no record.
    public func invitationsAwaitingIntake(
        _ account: AccountID, limit: Int, waitingForCalendars: Bool = true
    ) throws(StoreError) -> [MessageID] {
        try read { database in
            try Int64.fetchAll(
                database,
                sql: """
                    SELECT m.id FROM message m LEFT JOIN invitation_message i ON i.messageId = m.id
                    WHERE m.accountId = ? AND m.isInvitation = 1 AND m.body IS NOT NULL
                        AND (i.messageId IS NULL OR (? AND i.awaitingCalendar = 1))
                    ORDER BY m.date DESC, m.id DESC LIMIT ?
                    """, arguments: [account.raw.uuidString, waitingForCalendars, max(0, min(limit, 1_000))]
            ).map(MessageID.init(raw:))
        }
    }

    /// The folder's invitations held without their body, newest first, at most `limit`.
    public func invitationsWithoutBody(in folder: FolderID, limit: Int) throws(StoreError) -> [MessageID] {
        try read { database in
            try Int64.fetchAll(
                database,
                sql: """
                    SELECT id FROM message
                    WHERE folderId = ? AND isInvitation = 1 AND body IS NULL AND uid > 0
                    ORDER BY date DESC, id DESC LIMIT ?
                    """, arguments: [folder.raw, max(0, min(limit, 1_000))]
            ).map(MessageID.init(raw:))
        }
    }

    /// An organiser's change from mail is shown (and held as `appliedIcs`) while the server's copy
    /// is older: the server's object is kept under it and true is returned. A server copy as new or
    /// newer clears it and is stored as usual.
    static func keepsAppliedChange(
        _ database: Database, _ id: Int64, _ existing: Row,
        // swiftlint:disable:next large_tuple
        server: (series: EventSeries, etag: String, ics: Data, scheduleTag: String?)
    ) throws -> Bool {
        guard (existing["appliedIcs"] as Data?) != nil else { return false }
        if let held = CalendarRecords.decodeSeries(existing["seriesJSON"] as String?),
            CalendarRecords.topSequence(server.series) < CalendarRecords.topSequence(held) {
            try database.execute(
                sql: "UPDATE event SET etag = ?, ics = ?, scheduleTag = ? WHERE id = ?",
                arguments: [server.etag, server.ics, server.scheduleTag, id])
            return true
        }
        try database.execute(sql: "UPDATE event SET appliedIcs = NULL WHERE id = ?", arguments: [id])
        return false
    }

    /// The queued change of `revision`, whose organiser's change from mail the server applied itself
    /// or refused to take (RFC 6638 › 3.2.2.1), is settled without a write: `appliedIcs` stays and is
    /// shown until the server's copy catches up. A change queued since is left to be sent.
    public func settleOrganiserChange(_ id: EventID, revision: Int) throws(StoreError) {
        try write { database in
            try database.execute(
                sql: """
                    UPDATE event SET pendingEditJSON = NULL, changeFailed = 0, attempts = 0
                    WHERE id = ? AND revision = ?
                    """, arguments: [id.raw, revision])
        }
    }

    /// After the owner's edits were written onto the server's copy because the server refused the
    /// organiser's change: the organiser's change with those edits on it (`ics`, read as `series`) is
    /// held and shown again, with any edit queued since on top. Nothing when a later change from mail
    /// is queued: that one is shown already, and written next.
    public func holdOrganiserChange(_ id: EventID, ics: Data, series: EventSeries) throws(StoreError) {
        try write { database in
            let row = try EventRow.fetch(database, id)
            if row.pending.contains(.organiserChange) { return }
            var shown = series
            for edit in row.pending {
                guard let next = EventEditing.apply(edit, to: shown, email: row.email) else { break }
                shown = next
            }
            try database.execute(sql: "UPDATE event SET appliedIcs = ? WHERE id = ?", arguments: [ics, id.raw])
            try CalendarRecords.save(database, shown, event: id.raw)
            try CalendarRecords.expand(database, event: id.raw, series: shown, try Expansion.current(database))
        }
    }

    // MARK: A reply that could not be queued

    /// The owner's current answer, for the part of the event whose reply mail could not be queued,
    /// is queued again (sent to the server once more, which then queues its reply), and the event no
    /// longer shows as failed. Never an older answer than the one shown: with no answer there now
    /// the held failure just goes. `StoreError.noSuchFolder` while the account still has no Drafts
    /// folder; nothing happens for an event without such a failure.
    public func retryEventReply(_ id: EventID) throws(StoreError) {
        let account: String? = try write { database in
            let row = try EventRow.fetch(database, id)
            let held = try String.fetchOne(
                database, sql: "SELECT failedReplyJSON FROM event WHERE id = ?", arguments: [id.raw])
            guard case let .respond(_, scope, _, _)? = CalendarRecords.decodeEdits(held).first, let series = row.series
            else { return nil }
            guard try Self.draftsFolder(database, account: row.account) != nil else { throw StoreError.noSuchFolder }
            try Self.clearFailedReply(database, id.raw, coveredBy: nil)
            guard let current = Self.ownAnswer(series, scope, email: row.email), current != .needsAction else {
                return nil
            }
            try Self.queue(database, row, series: series, .respond(current, scope: scope, sendReply: true))
            return row.account
        }
        if let account { announce(account: account) }
    }

    /// The owner's answer shown for the whole event (its series event, else first override), or one occurrence.
    static func ownAnswer(_ series: EventSeries, _ scope: EditScope, email: String) -> Attendee.Response? {
        let details: EventDetails?
        switch scope {
        case .event:
            details = CalendarRecords.lead(series)
        case let .occurrence(time):
            details = Recurrence.ownOverride(at: time, in: series, phoneZone: TimeZone(identifier: "UTC") ?? .gmt)?
                .details
        }
        return details.flatMap { EventOwnership.ownAttendee($0, accountEmail: email)?.response }
    }

    /// The held failed reply goes: always (`scope` nil), or when an answer for `scope` covers it
    /// (the whole event covers every part; an occurrence only itself).
    static func clearFailedReply(_ database: Database, _ id: Int64, coveredBy scope: EditScope?) throws {
        if let scope, case let .occurrence(time) = scope {
            let held = try String.fetchOne(
                database, sql: "SELECT failedReplyJSON FROM event WHERE id = ?", arguments: [id])
            guard case .respond(_, .occurrence(time), _, _)? = CalendarRecords.decodeEdits(held).first else { return }
        }
        try database.execute(sql: "UPDATE event SET failedReplyJSON = NULL WHERE id = ?", arguments: [id])
    }

    /// The most scopes kept as answered by the server; past it the oldest go.
    static let serverRepliedScopes = 1_000

    /// The answer for `scope` was sent by the server although it was to go without a response.
    static func markServerReplied(_ database: Database, _ id: Int64, _ scope: EditScope) throws {
        var scopes = try serverReplied(database, id).filter { $0 != scope }
        scopes = scope == .event ? [.event] : Array((scopes + [scope]).suffix(serverRepliedScopes))
        try database.execute(
            sql: "UPDATE event SET serverRepliedJSON = ? WHERE id = ?",
            arguments: [CalendarRecords.encode(scopes), id])
    }

    /// A newer answer for `scope` is queued: what the server sent for it before no longer stands. The
    /// whole event covers every part; an occurrence only itself and the whole event's mark.
    static func clearServerReplied(_ database: Database, _ id: Int64, coveredBy scope: EditScope) throws {
        let kept = scope == .event ? [] : try serverReplied(database, id).filter { $0 != scope && $0 != .event }
        try database.execute(
            sql: "UPDATE event SET serverRepliedJSON = ? WHERE id = ?",
            arguments: [kept.isEmpty ? nil : CalendarRecords.encode(kept), id])
    }

    private static func serverReplied(_ database: Database, _ id: Int64) throws -> [EditScope] {
        CalendarRecords.decodeScopes(
            try String.fetchOne(database, sql: "SELECT serverRepliedJSON FROM event WHERE id = ?", arguments: [id]))
    }

    /// The account's event with this UID, in its own calendars, that is not a queued delete.
    static func liveEvent(_ database: Database, account: String, uid: String) throws -> Int64? {
        let rows = try Row.fetchAll(
            database,
            sql: """
                SELECT id, pendingEditJSON FROM event
                WHERE accountId = ? AND uid = ? ORDER BY id
                """,
            arguments: [account, uid])
        return rows.first {
            !CalendarRecords.decodeEdits($0["pendingEditJSON"] as String?).contains(.delete(scope: .event))
        }?["id"]
    }

    static func draftsFolder(_ database: Database, account: String) throws -> Int64? {
        try Int64.fetchOne(
            database, sql: "SELECT id FROM folder WHERE accountId = ? AND kind = ? ORDER BY id LIMIT 1",
            arguments: [account, FolderKind.drafts.rawValue])
    }

    // MARK: What a message's invitation is

    /// The account had an earlier version of the meeting by mail (a REQUEST or ADD with a lower
    /// SEQUENCE, one that was applied: a spoofed or refused one never counts): this one is an update,
    /// though the server may have applied it before its mail came.
    static func hadEarlierVersion(_ database: Database, account: String, uid: String, below sequence: Int) throws
        -> Bool {
        let count = try Int.fetchOne(
            database,
            sql: """
                SELECT COUNT(*) FROM invitation_message i JOIN message m ON m.id = i.messageId
                WHERE m.accountId = ? AND i.uid = ? AND i.method IN ('REQUEST', 'ADD') AND i.applied = 1
                    AND i.sequence < ?
                """, arguments: [account, uid, sequence])
        return (count ?? 0) > 0
    }

    /// A newer SEQUENCE for the message's occurrence is applied already: by a later message of the
    /// account, or in the event the calendar holds.
    static func isOutdated(
        _ database: Database, meeting: (account: String, uid: String), sequence: Int, recurrenceJSON: String?,
        event: CalendarEvent?
    ) throws -> Bool {
        let newer = try Int.fetchOne(
            database,
            sql: """
                SELECT COUNT(*) FROM invitation_message i JOIN message m ON m.id = i.messageId
                WHERE m.accountId = ? AND i.uid = ? AND i.applied = 1 AND i.method != 'REPLY'
                    AND i.sequence > ? AND IFNULL(i.recurrenceIdJSON, '') = IFNULL(?, '')
                """, arguments: [meeting.account, meeting.uid, sequence, recurrenceJSON]) ?? 0
        let held = try event.map { found in
            CalendarRecords.decodeSeries(
                try String.fetchOne(
                    database, sql: "SELECT seriesJSON FROM event WHERE id = ?", arguments: [found.id.raw]))
        } ?? nil
        let recurrence = CalendarRecords.decodeTime(recurrenceJSON)
        return newer > 0 || (held.map { Self.sequence(of: $0, at: recurrence) } ?? 0) > sequence
    }

    /// The SEQUENCE the calendar holds for the occurrence (its override's), else for the series.
    static func sequence(of series: EventSeries, at recurrence: EventTime?) -> Int {
        if let recurrence, let own = series.overrides.first(where: { $0.recurrenceID == recurrence }) {
            return own.details.sequence
        }
        return (series.base ?? series.overrides.first?.details)?.sequence ?? 0
    }
}
