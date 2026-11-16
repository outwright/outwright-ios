// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightDAV
import OutwrightModel
import OutwrightStore

/// What the server holds after a write.
struct Written {
    let href: String
    let etag: String?
    let ics: Data
    let scheduleTag: String?
}

/// The owner's answers among the edits a write sent: each is recorded at its own revision, and where
/// the copy leaves its replies to the client (`ReplyRoute.app`: `SCHEDULE-AGENT=CLIENT`) and the
/// owner asked for it, with its REPLY queued in the same store step, so it is sent once. One that was
/// to go without a response onto an object the server schedules is recorded as sent by the server.
extension CalendarSyncer {
    func done(
        _ change: QueuedEventChange, _ written: Written, calendar: ICalComponent, series: EventSeries,
        replies: Bool = true
    ) throws(SyncError) {
        // The revision of the edit before the first one sent.
        let before = change.revision - change.edits.count
        let schedules = try stored { try store.serverSchedules(account.id) }
        let route = ReplyRoute.route(calendar, serverSchedules: schedules)
        var recordedUpTo: Int?
        for (index, edit) in change.edits.enumerated() {
            guard case let .respond(response, scope, sendReply) = edit else { continue }
            let revision = before + index + 1
            var reply: (row: MessageRow, body: Data)?
            if replies, sendReply, route == .app {
                reply = replyDraft(calendar, response, scope)
            }
            try stored {
                try store.respondDone(
                    change.event, revision: revision, href: written.href, etag: written.etag, ics: written.ics,
                    series: series, reply: reply, scheduleTag: written.scheduleTag, builtOn: change.object,
                    repliedByServer: !sendReply && route == .server)
            }
            recordedUpTo = revision
        }
        guard recordedUpTo != change.revision else { return }
        let mails = try meetingMails(change, now: calendar)
        try stored {
            try store.meetingChangeDone(
                change.event, revision: change.revision, href: written.href, etag: written.etag, ics: written.ics,
                series: series, scheduleTag: written.scheduleTag, builtOn: change.object, mails: mails)
        }
    }

    /// For an answer that is to go without a response: the object's `Schedule-Tag` as the server holds
    /// it now (the card offered the choice on the last one held, and the server may have scheduled the
    /// copy since). Nil when there is none, or nothing to ask.
    func scheduleTagSince(
        _ change: QueuedEventChange, _ href: URL, _ client: CalDAVClient
    ) async throws(SyncError) -> String? {
        let withheld = change.edits.contains { edit in
            if case .respond(_, _, false) = edit { return true }
            return false
        }
        guard withheld, try stored({ try store.scheduleTag(change.event) }) == nil,
            case let .found(server) = try await fetch(href, client)
        else { return nil }
        return server.scheduleTag
    }

    /// The REPLY mail for one answer, as a draft; nil when the object has nothing to reply to.
    private func replyDraft(
        _ calendar: ICalComponent, _ response: Attendee.Response, _ scope: EditScope
    ) -> (row: MessageRow, body: Data)? {
        var recurrenceID: EventTime?
        if case let .occurrence(time) = scope { recurrenceID = time }
        guard
            let message = InvitationReply.message(
                calendar: calendar, response: response, recurrenceID: recurrenceID, account: account,
                wording: meetingWording, now: now())
        else { return nil }
        return InvitationReply.draft(message, account: account)
    }

    /// The server's object already says what the change writes, so a write whose answer was lost
    /// landed: answers and the own reminder written onto it change nothing the app reads, and
    /// the owner's other edits written onto what they were sent over give what it holds.
    func holdsAlready(_ change: QueuedEventChange, _ server: RemoteResource) -> Bool {
        guard let calendar = Self.parse(server.data), let uid = EventMapping.series(calendar).first?.uid
        else { return false }
        let invitee = change.edits.allSatisfy { edit in
            switch edit {
            case .respond, .ownReminder, .guestAnswer: true
            case .create, .update, .delete, .organiserChange: false
            }
        }
        if invitee {
            return EventMapping.series(written(change.edits, onto: calendar, uid: uid))
                == EventMapping.series(calendar)
        }
        guard !change.isDelete, let sentOver = (change.object ?? change.ics).flatMap(Self.parse) else { return false }
        return EventMapping.series(written(change.edits, onto: sentOver, uid: uid)) == EventMapping.series(calendar)
    }

    /// The ETag a write landed with: the answer's, else the object's as the server holds it now; nil
    /// when neither is known.
    func landedETag(_ answer: PutAnswer, _ href: URL, _ client: CalDAVClient) async throws(SyncError) -> String? {
        if let etag = answer.etag { return etag }
        guard case let .found(server)? = try? await fetch(href, client) else { return nil }
        return server.etag
    }

    static func isAnswer(_ edit: EventEdit) -> Bool {
        if case .respond = edit { return true }
        return false
    }

    /// What a create starts from, and whether an answer to be sent follows it as a second write. An
    /// answer to be sent never rides in the create: RFC 6638 leaves a REPLY for a new object unsaid
    /// (› 3.2.2.2), so the invitation goes as it came and the answer as a change to it (› 3.2.2.3).
    /// When any answer queued with it is to go without a response, the copy is made the client's to
    /// answer from (› 7.1): the server then sends none of them, and the app mails those to be sent.
    /// With a server that does not schedule, the answers ride in the create and the app mails them.
    static func createStart(
        _ later: [EventEdit], _ calendar: ICalComponent, serverSchedules: Bool
    ) -> (start: ICalComponent, sendsAnswer: Bool) {
        let start = withholdsAny(later) ? ITIP.settingScheduleAgentClient(calendar) : calendar
        let route = ReplyRoute.route(start, serverSchedules: serverSchedules)
        return (start, route == .server && later.contains(where: isAnswer))
    }

    /// An answer among `edits` is one to go without a response.
    static func withholdsAny(_ edits: [EventEdit]) -> Bool {
        edits.contains { edit in
            if case .respond(_, _, false) = edit { return true }
            return false
        }
    }
}
