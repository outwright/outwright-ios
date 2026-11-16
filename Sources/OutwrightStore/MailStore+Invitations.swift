// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
import GRDB
import OutwrightMIME
public import OutwrightModel

// swiftlint:disable function_parameter_count
extension MailStore {
    // MARK: The owner's answers

    /// Queues the owner's answer to an invitation, shown at once; two answers are two edits, each
    /// owed its own reply. Declining the whole event hides it (it stays in the store); one occurrence
    /// declined is not shown either. `StoreError.readOnly` unless the event is an invitation
    /// (`EventOwnership.isInvitation`) in a writable calendar.
    public func respond(
        _ id: EventID, _ response: Attendee.Response, scope: EditScope, sendReply: Bool
    ) throws(StoreError) {
        try edit(id, .respond(response, scope: scope, sendReply: sendReply))
    }

    /// The owner's own reminder on an invitation, in minutes before the start (at most a year); nil
    /// for none. Refused as `respond` is.
    public func setOwnReminder(_ id: EventID, minutes: Int?, scope: EditScope) throws(StoreError) {
        try edit(id, .ownReminder(minutes.map { min(max($0, 0), 525_600) }, scope: scope))
    }

    /// Delete on an invitation: a decline, with a reply to the organiser.
    public func declineByDeleting(_ id: EventID, scope: EditScope) throws(StoreError) {
        try respond(id, .declined, scope: scope, sendReply: true)
    }

    /// Queues the delete of an event its organiser called off. `StoreError.readOnly` when it is not
    /// cancelled, or its calendar is read-only.
    public func removeCancelled(_ id: EventID) throws(StoreError) {
        let account: String = try write { database in
            let row = try EventRow.fetch(database, id)
            if row.isDeleted { throw StoreError.noSuchEvent }
            if !row.hasCalDAV { throw StoreError.noCalDAV }
            guard let series = row.series else { throw StoreError.unreadableEvent }
            guard !row.calendarReadOnly, Self.isCancelled(series) else { throw StoreError.readOnly }
            try Self.queue(database, row, series: series, .delete(scope: .event))
            return row.account
        }
        announce(account: account)
    }

    /// The series event is cancelled; with none, every override is.
    static func isCancelled(_ series: EventSeries) -> Bool {
        if let base = series.base { return base.status == .cancelled }
        return !series.overrides.isEmpty && series.overrides.allSatisfy { $0.details.status == .cancelled }
    }

    /// The server took the answer that was `revision` of the event (as `eventChangeDone`, with the
    /// `Schedule-Tag` it answered with and the object the write was `builtOn`). In the same
    /// transaction, when `reply` is given, the server gave no `Schedule-Tag` (with one the server
    /// answers the organiser itself) and no reply was queued yet for this answer (`replySent` is the
    /// revision the last reply was queued for; an answer at or before it never gets another, however
    /// often its done is retried): the reply is kept in the account's Drafts with its body and queued
    /// to be sent. Without a Drafts folder the change is still done, and the answer is kept as one
    /// whose reply failed (the event shows a failed change) until `retryEventReply`. `repliedByServer`:
    /// the answer was to go without a response and the server sent one anyway (`replySentByServer` on
    /// the answer's scope, until a newer answer for it is queued).
    public func respondDone(
        _ id: EventID, revision: Int, href: String, etag: String?, ics: Data, series: EventSeries,
        reply: (row: MessageRow, body: Data)?, scheduleTag: String?, builtOn: Data? = nil,
        repliedByServer: Bool = false
    ) throws(StoreError) {
        // The reply is read before the write, as `setBody` does.
        let text = reply.map { open($0.body).map { Records.indexText($0.message) } ?? "" }
        let queuedFor: String? = try write { database in
            guard
                let before = try Self.changeDone(
                    database, id, revision: revision, href: href, etag: etag, ics: ics, series: series,
                    scheduleTag: scheduleTag, builtOn: builtOn)
            else { return nil }
            if repliedByServer {
                let index = revision - (before.revision - before.pending.count) - 1
                if before.pending.indices.contains(index), case let .respond(_, scope, _) = before.pending[index] {
                    try Self.markServerReplied(database, id.raw, scope)
                }
            }
            guard let reply, scheduleTag == nil,
                let sentUpTo = try Int.fetchOne(
                    database, sql: "SELECT replySent FROM event WHERE id = ?", arguments: [id.raw]),
                sentUpTo < revision
            else { return nil }
            guard try Self.queueDrafts(database, account: before.account, [reply], texts: [text ?? ""]) else {
                // The answer is on the server; only its mail is owed: kept, to be retried.
                // The answer's scope from the edit; when that edit is no longer held (the owner gave
                // up the change while it was in flight) the whole event's, as written.
                let index = revision - (before.revision - before.pending.count) - 1
                var held = EventEdit.respond(
                    CalendarRecords.lead(series).flatMap {
                        EventOwnership.ownAttendee($0, accountEmail: before.email)?.response
                    } ?? .needsAction, scope: .event, sendReply: true)
                if before.pending.indices.contains(index), case .respond = before.pending[index] {
                    held = before.pending[index]
                }
                try database.execute(
                    sql: "UPDATE event SET failedReplyJSON = ?, replySent = ? WHERE id = ?",
                    arguments: [CalendarRecords.encode([held]), revision, id.raw])
                return nil
            }
            try database.execute(sql: "UPDATE event SET replySent = ? WHERE id = ?", arguments: [revision, id.raw])
            return before.account
        }
        if let queuedFor { announce(account: queuedFor) }
    }

    // MARK: Schedule-Tag

    /// The last `Schedule-Tag` the server gave for the event's calendar object; nil for none.
    public func scheduleTag(_ id: EventID) throws(StoreError) -> String? {
        try read { database in
            try String.fetchOne(database, sql: "SELECT scheduleTag FROM event WHERE id = ?", arguments: [id.raw])
        }
    }

    public func setScheduleTag(_ tag: String?, for id: EventID) throws(StoreError) {
        try write { database in
            try database.execute(sql: "UPDATE event SET scheduleTag = ? WHERE id = ?", arguments: [tag, id.raw])
        }
    }

    // MARK: Invitations from mail

    /// Puts the app's own copy of an invitation (`ics`, read as `series`) in the calendar, shown at
    /// once and queued as a create (`If-None-Match: *`) to the place chosen now. `StoreError.readOnly`
    /// when it is not an invitation to the account (no own attendee, or the account organizes it). An event of the
    /// account with the same UID is already the invitation's: its id is returned, nothing written.
    public func insertInvitation(
        ics: Data, series: EventSeries, uid: String, in cal: CalendarID, window: ClosedRange<Date>,
        phoneZone: TimeZone
    ) throws(StoreError) -> EventID {
        let (id, queued): (EventID, String?) = try write { database in
            guard
                let row = try Row.fetchOne(
                    database,
                    sql: """
                        SELECT c.accountId, c.href, c.isReadOnly, a.calDAV, a.email FROM calendar c
                        JOIN account a ON a.id = c.accountId WHERE c.id = ?
                        """, arguments: [cal.raw]),
                let account = row["accountId"] as String?, let folder = row["href"] as String?
            else { throw StoreError.noSuchCalendar }
            if (row["calDAV"] as String?) == nil { throw StoreError.noCalDAV }
            if ((row["isReadOnly"] as Int?) ?? 1) != 0 { throw StoreError.readOnly }
            guard uid == series.uid, let lead = CalendarRecords.lead(series) else { throw StoreError.unreadableEvent }
            // Only an invitation to this account goes in as one: not the owner's own, not a forwarded one.
            guard EventOwnership.isInvitation(lead, accountEmail: (row["email"] as String?) ?? "")
            else { throw StoreError.readOnly }
            if let existing = try Self.liveEvent(database, account: account, uid: uid) {
                return (EventID(raw: existing), nil)
            }
            let expansion = Expansion(from: window.lowerBound, to: window.upperBound, zone: phoneZone)
            try expansion.save(database)
            let href = (folder.hasSuffix("/") ? folder : folder + "/") + Self.resourceName(uid) + ".ics"
            try database.execute(
                sql: """
                    INSERT INTO event (accountId, calendarId, uid, seriesJSON, pendingEditJSON, revision, newHref,
                        newIcs, origin)
                    VALUES (?, ?, ?, '{}', ?, 1, ?, ?, ?)
                    """,
                arguments: [
                    account, cal.raw, uid, CalendarRecords.encode([.create(lead, rule: series.rule)]), href, ics,
                    CopyOrigin.app.rawValue
                ])
            let id = database.lastInsertedRowID
            try CalendarRecords.save(database, series, event: id)
            try CalendarRecords.expand(database, event: id, series: series, expansion)
            return (EventID(raw: id), account)
        }
        if let queued { announce(account: queued) }
        return id
    }

    /// The organiser's update or cancellation (`ics`, read as `series`), shown at once with the
    /// owner's queued answers still on it. An app copy whose create is not on the server yet sends
    /// the new object in its place. Any copy the server has is held as `appliedIcs` (what the next
    /// change from mail is applied to, and what the owner's edits are written onto) and queued as
    /// `organiserChange`, written to the server (RFC 6638 › 3.2.2.2: the client stores what reached it
    /// by mail) until the server's version has caught up with it (`upsertRemote`).
    /// `StoreError.readOnly` for an event that is not an invitation.
    public func applyInvitationChange(
        _ id: EventID, ics: Data, series: EventSeries, window: ClosedRange<Date>, phoneZone: TimeZone
    ) throws(StoreError) {
        let queuedFor: String? = try write { database in
            let row = try EventRow.fetch(database, id)
            if row.isDeleted { throw StoreError.noSuchEvent }
            guard let held = row.series.flatMap(CalendarRecords.lead),
                EventOwnership.isInvitation(held, accountEmail: row.email)
            else { throw StoreError.readOnly }
            let expansion = Expansion(from: window.lowerBound, to: window.upperBound, zone: phoneZone)
            try expansion.save(database)
            var later = row.pending
            var queued: String?
            if row.href == nil, case .create? = row.pending.first, let lead = CalendarRecords.lead(series) {
                later.removeFirst()
                try database.execute(
                    sql: """
                        UPDATE event SET pendingEditJSON = ?, newIcs = CASE WHEN newHref IS NULL THEN NULL ELSE ? END
                        WHERE id = ?
                        """,
                    arguments: [CalendarRecords.encode([.create(lead, rule: series.rule)] + later), ics, id.raw])
            } else if row.href != nil, row.hasCalDAV, !row.calendarReadOnly {
                // Each change from mail is its own revision: one written while the next came stays
                // queued after it (`changeDone`).
                later.append(.organiserChange)
                try database.execute(
                    sql: """
                        UPDATE event SET appliedIcs = ?, pendingEditJSON = ?, attempts = 0, revision = revision + 1
                        WHERE id = ?
                        """,
                    arguments: [ics, CalendarRecords.encode(later), id.raw])
                queued = row.account
            } else {
                try database.execute(sql: "UPDATE event SET appliedIcs = ? WHERE id = ?", arguments: [ics, id.raw])
            }
            var shown = series
            for edit in later {
                guard let next = EventEditing.apply(edit, to: shown, email: row.email) else { break }
                shown = next
            }
            try CalendarRecords.save(database, shown, event: id.raw)
            try CalendarRecords.expand(database, event: id.raw, series: shown, expansion)
            return queued
        }
        // The cue to write it now, not at the next calendar sync.
        if let queuedFor { announce(account: queuedFor) }
    }

    /// Remembers what a message's invitation was and did, once per message. `reply` is who answered,
    /// and how, for a REPLY. `awaitingCalendar`: not applied because the account has no calendar to
    /// put it in yet; such a message is not counted as recorded and is taken again. `isUpdate`: the
    /// message is a later version of a meeting the calendar held (applied here or by the server
    /// first); `timeMoved`: for one the phone applied, whether its time moved (nil when unknown).
    /// `title`: the meeting's SUMMARY, for a card whose event is gone. `invitation(for:)` also reads a
    /// REQUEST as an update when the account had an earlier version of the meeting by mail.
    public func recordInvitation(
        message: MessageID, method: InvitationMethod, uid: String, recurrenceID: EventTime?, sequence: Int,
        event: EventID?, applied: Bool, reply: (email: String, response: Attendee.Response)? = nil,
        awaitingCalendar: Bool = false, isUpdate: Bool = false, timeMoved: Bool? = nil, title: String? = nil
    ) throws(StoreError) {
        try write { database in
            try Self.require(database, message)
            try database.execute(
                sql: """
                    INSERT OR REPLACE INTO invitation_message (messageId, method, uid, recurrenceIdJSON, sequence,
                        eventId, applied, replyEmail, replyResponse, awaitingCalendar, isUpdate, timeMoved, title)
                    VALUES (?, ?, ?, ?, ?, (SELECT id FROM event WHERE id = ?), ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    message.raw, method.rawValue, uid, recurrenceID.map(CalendarRecords.encode), sequence,
                    event?.raw, applied, reply?.email, reply.map { Self.name($0.response) }, awaitingCalendar,
                    isUpdate || timeMoved != nil, timeMoved, title.map { String($0.prefix(1_000)) }
                ])
        }
    }

    /// What the message's invitation is, and the event it is about (by the event it changed, else
    /// by the account and UID). Nil for a message not read as an invitation.
    public func invitation(for message: MessageID) throws(StoreError) -> InvitationState? {
        try read { database in
            guard
                let row = try Row.fetchOne(
                    database,
                    sql: """
                        SELECT i.*, m.accountId FROM invitation_message i JOIN message m ON m.id = i.messageId
                        WHERE i.messageId = ?
                        """, arguments: [message.raw]),
                let method = (row["method"] as String?).flatMap(InvitationMethod.init(rawValue:)),
                let uid = row["uid"] as String?, let account = row["accountId"] as String?
            else { return nil }
            let recurrenceJSON = row["recurrenceIdJSON"] as String?
            let recurrence = CalendarRecords.decodeTime(recurrenceJSON)
            let sequence = (row["sequence"] as Int?) ?? 0
            var event: CalendarEvent?
            if let linked = row["eventId"] as Int64? {
                event = try Self.find(database, where: "o.eventId = ?", [linked], recurrence)
                    ?? Self.find(database, where: "o.eventId = ?", [linked], nil)
            }
            if event == nil {
                let clause = CalendarRecords.ownByUID
                event = try Self.find(database, where: clause, [account, uid], recurrence)
                    ?? Self.find(database, where: clause, [account, uid], nil)
            }
            let isRequest = method == .request || method == .add
            let update = try ((row["isUpdate"] as Int?) ?? 0) != 0
                || (isRequest && Self.hadEarlierVersion(database, account: account, uid: uid, below: sequence))
            let outdated = try method != .reply && Self.isOutdated(
                database, meeting: (account, uid), sequence: sequence, recurrenceJSON: recurrenceJSON, event: event)
            let reply = (row["replyEmail"] as String?).flatMap { email in
                Self.response(named: row["replyResponse"] as String?).map { (email: email, response: $0) }
            }
            return InvitationState(
                method: method, event: event, sequence: sequence, isOutdated: outdated,
                wasApplied: ((row["applied"] as Int?) ?? 0) != 0, reply: reply, recurrenceID: recurrence,
                isUpdate: update, timeMoved: (row["timeMoved"] as Int?).map { $0 != 0 },
                title: row["title"] as String?)
        }
    }

    // MARK: One event per invitation

    /// The server's object `id` and an app copy of the same invitation (same account and UID, another
    /// address) are one invitation: the server's is kept, the app's own answer and reminder are queued
    /// on it while the server's still says NEEDS-ACTION (an answer not sent yet still owes its reply),
    /// and the app copy becomes a queued delete of its address. An app create that landed at the
    /// server's address is that object: it is dropped without a request.
    static func mergeAppCopies(_ database: Database, into id: Int64) throws {
        let server = try EventRow.fetch(database, EventID(raw: id))
        guard let held = server.series, let href = server.href else { return }
        // A copy in a read-only calendar is someone else's: nothing can be answered on it.
        if server.calendarReadOnly { return }
        let copies = try Int64.fetchAll(
            database, sql: "SELECT id FROM event WHERE accountId = ? AND uid = ? AND id != ? AND origin = ?",
            arguments: [server.account, held.uid, id, CopyOrigin.app.rawValue])
        for copy in copies {
            let app = try EventRow.fetch(database, EventID(raw: copy))
            if app.isDeleted || app.href == href { continue }
            try carryOver(database, from: app, to: id, held: held)
            if app.href == nil, app.newHref == href {
                try database.execute(sql: "DELETE FROM event WHERE id = ?", arguments: [copy])
                try database.execute(
                    sql: "UPDATE event SET origin = ? WHERE id = ?", arguments: [CopyOrigin.app.rawValue, id])
                continue
            }
            try queue(database, app, series: app.series ?? held, .delete(scope: .event))
        }
    }

    /// The app copy's answer and reminder onto the server's copy. While the server's copy says
    /// NEEDS-ACTION; once the app has mailed its REPLY and owes none, only when the server's copy says
    /// another answer than that one: the server answers the organiser for what it is written, and the
    /// organiser has this answer already.
    private static func carryOver(_ database: Database, from app: EventRow, to id: Int64, held: EventSeries) throws {
        guard let mine = app.series.flatMap(CalendarRecords.lead), let theirs = CalendarRecords.lead(held),
            let theirAnswer = EventOwnership.ownAttendee(theirs, accountEmail: app.email)?.response
        else { return }
        let unsent = app.pending.last {
            if case .respond = $0 { return true }
            return false
        }
        var sendReply = false
        if case let .respond(_, _, owed)? = unsent { sendReply = owed }
        let mailed = try !sendReply
            && (Int.fetchOne(database, sql: "SELECT replySent FROM event WHERE id = ?", arguments: [app.id]) ?? 0) > 0
        guard mailed || theirAnswer == .needsAction else { return }
        var edits: [EventEdit] = []
        if let answer = EventOwnership.ownAttendee(mine, accountEmail: app.email)?.response, answer != .needsAction,
            answer != theirAnswer {
            edits.append(.respond(answer, scope: .event, sendReply: sendReply))
        }
        if mine.reminder != theirs.reminder { edits.append(.ownReminder(mine.reminder, scope: .event)) }
        for edit in edits {
            let current = try EventRow.fetch(database, EventID(raw: id))
            guard let series = current.series else { return }
            try queue(database, current, series: series, edit)
        }
    }

    /// The object's name in its calendar: the UUID of a `urn:uuid:` UID, else the UID's letters,
    /// digits and hyphens, at most 64; a fresh UUID when none are left.
    public static func resourceName(_ uid: String) -> String {
        let bare = uid.lowercased().hasPrefix("urn:uuid:") ? String(uid.dropFirst("urn:uuid:".count)) : uid
        let kept = bare.unicodeScalars.filter { ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == "-" }
        let name = String(String.UnicodeScalarView(kept.prefix(64)))
        return name.isEmpty ? UUID().uuidString.lowercased() : name
    }

    private static func name(_ response: Attendee.Response) -> String {
        switch response {
        case .needsAction: "NEEDS-ACTION"
        case .accepted: "ACCEPTED"
        case .tentative: "TENTATIVE"
        case .declined: "DECLINED"
        case .delegated: "DELEGATED"
        }
    }

    private static func response(named text: String?) -> Attendee.Response? {
        switch text {
        case "NEEDS-ACTION": .needsAction
        case "ACCEPTED": .accepted
        case "TENTATIVE": .tentative
        case "DECLINED": .declined
        case "DELEGATED": .delegated
        default: nil
        }
    }
}
// swiftlint:enable function_parameter_count
