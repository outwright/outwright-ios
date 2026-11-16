// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
import GRDB
import OutwrightMIME
public import OutwrightModel

/// The invitation mails of the owner's own meetings (the REQUEST and CANCELs the app sends where the
/// CalDAV server does not schedule), queued in the same transaction as the change they follow, so
/// each change's mails go once. While the account has no Drafts to send from they are owed, and
/// queued by `queueOwedMeetingMails` once it has.
extension MailStore {
    // swiftlint:disable function_parameter_count
    /// `eventChangeDone`, and the change's `mails` kept in the account's Drafts and queued to be sent,
    /// unless mails were queued for this revision already (`replySent`): a done retried sends nothing
    /// twice. Without a Drafts folder they are owed.
    public func meetingChangeDone(
        _ id: EventID, revision: Int, href: String, etag: String?, ics: Data, series: EventSeries,
        scheduleTag: String?, builtOn: Data? = nil, mails: [(row: MessageRow, body: Data)]
    ) throws(StoreError) {
        let texts = mails.map { open($0.body).map { Records.indexText($0.message) } ?? "" }
        let queuedFor: String? = try write { database in
            guard
                let before = try Self.changeDone(
                    database, id, revision: revision, href: href, etag: etag, ics: ics, series: series,
                    scheduleTag: scheduleTag, builtOn: builtOn),
                !mails.isEmpty,
                let sentUpTo = try Int.fetchOne(
                    database, sql: "SELECT replySent FROM event WHERE id = ?", arguments: [id.raw]),
                sentUpTo < revision
            else { return nil }
            try database.execute(sql: "UPDATE event SET replySent = ? WHERE id = ?", arguments: [revision, id.raw])
            return try Self.queueOrOwe(database, account: before.account, mails, texts: texts) ? before.account : nil
        }
        if let queuedFor { announce(account: queuedFor) }
    }

    // swiftlint:enable function_parameter_count

    /// The server deleted the owner's meeting: it goes, as `dropEventChange` drops it, and its CANCEL
    /// `mails` are queued (or owed) with it. Nothing happens when the owner has edited it since `revision`.
    public func meetingDeleteDone(
        _ id: EventID, revision: Int, mails: [(row: MessageRow, body: Data)]
    ) throws(StoreError) {
        let texts = mails.map { open($0.body).map { Records.indexText($0.message) } ?? "" }
        let queuedFor: String? = try write { database in
            let row: EventRow
            do {
                row = try EventRow.fetch(database, id)
            } catch StoreError.noSuchEvent {
                return nil
            }
            guard row.revision == revision, row.isDeleted else { return nil }
            try database.execute(sql: "DELETE FROM event WHERE id = ?", arguments: [id.raw])
            return try Self.queueOrOwe(database, account: row.account, mails, texts: texts) ? row.account : nil
        }
        if let queuedFor { announce(account: queuedFor) }
    }

    /// The mails owed while the account had no Drafts, queued now that it has one.
    public func queueOwedMeetingMails(_ account: AccountID) throws(StoreError) {
        let key = account.raw.uuidString
        let owed = try read { database in
            try Row.fetchAll(
                database, sql: "SELECT id, body FROM meeting_mail_owed WHERE accountId = ? ORDER BY id",
                arguments: [key]
            ).compactMap { row -> (id: Int64, body: Data)? in
                guard let id = row["id"] as Int64?, let body = row["body"] as Data? else { return nil }
                return (id, body)
            }
        }
        guard !owed.isEmpty else { return }
        let parsed = owed.map { open($0.body)?.message }
        let queued: Bool = try write { database in
            guard try Self.draftsFolder(database, account: key) != nil else { return false }
            var mails: [(row: MessageRow, body: Data)] = []
            var texts: [String] = []
            for (index, mail) in owed.enumerated() {
                try database.execute(sql: "DELETE FROM meeting_mail_owed WHERE id = ?", arguments: [mail.id])
                guard let message = parsed[index], let row = Self.owedRow(message, account: account) else { continue }
                mails.append((row, mail.body))
                texts.append(Records.indexText(message))
            }
            return try Self.queueDrafts(database, account: key, mails, texts: texts)
        }
        if queued { announce(account: key) }
    }

    /// Queued from Drafts when the account has one, else owed. True when queued.
    static func queueOrOwe(
        _ database: Database, account: String, _ mails: [(row: MessageRow, body: Data)], texts: [String]
    ) throws -> Bool {
        if try queueDrafts(database, account: account, mails, texts: texts) { return true }
        for mail in mails {
            try database.execute(
                sql: "INSERT INTO meeting_mail_owed (accountId, body) VALUES (?, ?)", arguments: [account, mail.body])
        }
        return false
    }

    /// The draft row of an owed mail, read back from its message.
    static func owedRow(_ message: MIMEMessage, account: AccountID) -> MessageRow? {
        guard let from = message.from.first, let id = message.messageID else { return nil }
        return MessageRow(
            id: MessageID(raw: 0), accountID: account, folderID: FolderID(raw: 0), uid: 0,
            threadID: ThreadID(raw: id), from: from, to: message.to, cc: [], subject: message.subject,
            preview: String((message.textBody ?? "").prefix(200)), date: message.date ?? Date(), isRead: true,
            isFlagged: false, hasAttachment: false, isInvitation: false, inboxClass: .focused, hasBody: true,
            threadCount: 1, messageIDHeader: id)
    }

    /// Each mail kept in the account's Drafts with its body and queued to be sent. False when there
    /// is nothing to queue or no Drafts folder.
    static func queueDrafts(
        _ database: Database, account: String, _ mails: [(row: MessageRow, body: Data)], texts: [String]
    ) throws -> Bool {
        guard !mails.isEmpty, let drafts = try draftsFolder(database, account: account),
            let accountID = UUID(uuidString: account)
        else { return false }
        for (index, mail) in mails.enumerated() {
            var draft = mail.row
            draft.id = MessageID(raw: 0)
            draft.accountID = AccountID(raw: accountID)
            draft.folderID = FolderID(raw: drafts)
            draft.uid = 0
            let message = try store(database, draft)
            try database.execute(sql: "UPDATE message SET body = ? WHERE id = ?", arguments: [mail.body, message])
            try reindex(database, message, bodyText: texts.indices.contains(index) ? texts[index] : "")
            try keepReferences(database, message, draft)
            let draftID = MessageID(raw: message)
            try queue(database, .send(draftID: draftID), from: try source(database, draftID))
        }
        return true
    }

    // MARK: Guests' answers

    // swiftlint:disable function_parameter_count
    /// A guest's answer to the owner's meeting, from their REPLY by mail: queued as `guestAnswer`
    /// when the event is the owner's own, `scope` is the series or one of its occurrences, the guest is
    /// listed there, and the answer is not older than one taken before or than the meeting held there
    /// (RFC 5546 › 2.1.5: a lower SEQUENCE, or the same one with an earlier DTSTAMP, `stamp`, is
    /// stale). A held conflict or failed change of the owner's stays. False when it is not taken.
    public func takeGuestAnswer(
        _ id: EventID, guest: String, response: Attendee.Response, scope: EditScope, sequence: Int, stamp: Date?
    ) throws(StoreError) -> Bool {
        let guest = guest.lowercased()
        let edit = EventEdit.guestAnswer(email: guest, response: response, scope: scope)
        let account: String? = try write { database in
            let row = try EventRow.fetch(database, id)
            guard !row.isDeleted, row.hasCalDAV, let series = row.series,
                CalendarRecords.allows(edit, calendarReadOnly: row.calendarReadOnly, series: series, email: row.email)
            else { return nil }
            var recurrence: EventTime?
            if case let .occurrence(time) = scope {
                guard Self.isOccurrence(time, of: series) else { return nil }
                recurrence = time
            }
            let details = recurrence.flatMap { time in series.overrides.first { $0.recurrenceID == time }?.details }
                ?? series.base ?? series.overrides.first?.details
            guard let details, details.organizer?.lowercased() == row.email.lowercased(),
                details.attendees.contains(where: { $0.email.lowercased() == guest }),
                Self.sequence(of: series, at: recurrence) <= sequence
            else { return nil }
            let key = recurrence.map(CalendarRecords.encode) ?? ""
            if let taken = try Row.fetchOne(
                database,
                sql: "SELECT sequence, stamp FROM guest_answer WHERE eventId = ? AND guest = ? AND scope = ?",
                arguments: [row.id, guest, key]) {
                let heldSequence = (taken["sequence"] as Int?) ?? 0
                let heldStamp = (taken["stamp"] as Double?) ?? -.infinity
                let later = (stamp?.timeIntervalSince1970 ?? -.infinity) > heldStamp
                guard sequence > heldSequence || (sequence == heldSequence && later) else { return nil }
            }
            try database.execute(
                sql: """
                    INSERT OR REPLACE INTO guest_answer (eventId, guest, scope, sequence, stamp)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [row.id, guest, key, sequence, stamp?.timeIntervalSince1970])
            try Self.queue(database, row, series: series, edit, settles: false)
            return row.account
        }
        guard let account else { return false }
        announce(account: account)
        return true
    }

    // swiftlint:enable function_parameter_count

    /// `time` is an occurrence of the series: an override it holds, or one its rule lays out and no
    /// EXDATE removes.
    static func isOccurrence(_ time: EventTime, of series: EventSeries) -> Bool {
        if series.overrides.contains(where: { $0.recurrenceID == time && $0.details.status != .cancelled }) {
            return true
        }
        let utc = Calendar(identifier: .gregorian)
        let wallYear: Int? = switch time {
        case let .date(year, _, _): year
        case let .floating(wall), let .zoned(wall, _): wall.year
        case let .utc(date): utc.dateComponents(in: .gmt, from: date).year
        }
        guard let year = wallYear,
            let from = Calendar(identifier: .gregorian).date(from: DateComponents(timeZone: .gmt, year: year - 1)),
            let to = Calendar(identifier: .gregorian).date(from: DateComponents(timeZone: .gmt, year: year + 2))
        else { return false }
        return Recurrence.occurrences(series, from: from, to: to, phoneZone: .gmt).contains { $0.recurrenceID == time }
    }
}
