// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightDAV
import OutwrightFakes
import OutwrightMIME
import OutwrightModel
import OutwrightStore
@testable import OutwrightSync
import Testing

/// The owner's own meetings: where the CalDAV server does not schedule (RFC 6638 › 2), the app mails
/// the guests the REQUEST and CANCEL (iMIP, RFC 6047) once each write has landed.
struct MeetingHarness {
    let mail: Harness
    let caldav: FakeCalDAVServer
    let work: URL

    var store: MailStore { mail.store }
    var account: Account { mail.account }

    /// One round: the calendar synced (its queue first), then the mail queue run.
    func round() async throws {
        try await CalendarSyncer(
            account: account, store: store, secrets: mail.secrets, session: URLSession(configuration: .ephemeral),
            now: { fixedNow }, phoneZone: { stockholm }
        ).sync()
        try await AccountSyncer(
            account: account, store: store, secrets: mail.secrets, now: { fixedNow }, phoneZone: { stockholm }
        ).runActions()
    }

    func calendar() throws -> CalendarID {
        try #require(try store.calendars(account.id).first { !$0.isReadOnly }).id
    }

    /// The owner's meeting tomorrow with `guests`, its organiser the account.
    func details(_ guests: [String], title: String = "Planning") -> EventDetails {
        let start = fixedNow.addingTimeInterval(86_400)
        return EventDetails(
            title: title, start: .utc(start), end: .utc(start.addingTimeInterval(3_600)),
            attendees: guests.map { Attendee(email: $0, rsvp: true) }, organizer: account.email)
    }

    /// The meeting as the server holds it: its UID and each guest's PARTSTAT on the series.
    func serverMeeting() async throws -> (uid: String, partstats: [String: String]) {
        let ics = try #require(await caldav.events(in: work).values.first)
        let calendar = try ICalendarReader.calendar(Data(ics.utf8))
        let event = try #require(calendar.components.first { $0.name == "VEVENT" && $0.first("RECURRENCE-ID") == nil })
        var partstats: [String: String] = [:]
        for attendee in event.all("ATTENDEE") {
            partstats[EventMapping.address(attendee.value).lowercased()] = attendee.parameter("PARTSTAT") ?? "NEEDS-ACTION"
        }
        return (try #require(event.first("UID")?.value), partstats)
    }

    /// A guest's iMIP REPLY (RFC 6047) to the meeting `uid`, from `from`, delivered to the Inbox and read.
    /// `occurrence`: the REPLY answers that occurrence alone (its RECURRENCE-ID); `stamp` its DTSTAMP.
    func replyArrives(
        uid: String, from guest: String, partstat: String, sequence: Int = 0, sender: String? = nil,
        occurrence: Date? = nil, stamp: String = "20261101T090000Z"
    ) async throws {
        let start = occurrence ?? fixedNow.addingTimeInterval(86_400)
        var event = ["BEGIN:VEVENT", "UID:\(uid)", "SEQUENCE:\(sequence)", "DTSTAMP:\(stamp)"]
        if let occurrence { event.append("RECURRENCE-ID:\(utcText(occurrence))") }
        event += [
            "DTSTART:\(utcText(start))", "ORGANIZER:mailto:\(account.email)",
            "ATTENDEE;PARTSTAT=\(partstat):mailto:\(guest)", "END:VEVENT",
        ]
        let ics = icsText(
            ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Example//EN", "METHOD:REPLY"] + event + ["END:VCALENDAR"])
        let lines = [
            "From: <\(sender ?? guest)>", "To: \(account.email)", "Subject: Accepted: Planning",
            "Date: Thu, 05 Nov 2026 10:00:00 +0000", "Message-ID: <\(UUID().uuidString)@example.org>",
            "MIME-Version: 1.0", "Content-Type: text/calendar; charset=utf-8; method=REPLY", "", ics,
        ]
        await mail.imap.deliver(Data(lines.joined(separator: "\r\n").utf8), to: "INBOX")
        let syncer = AccountSyncer(
            account: account, store: store, secrets: mail.secrets, now: { fixedNow }, phoneZone: { stockholm })
        let inbox = try mail.folder(.inbox).id
        try await syncer.sync(inbox)
        for row in try mail.rows(.inbox) where !row.hasBody {
            try await syncer.fetchBody(row.id)
        }
    }

    /// `guest`'s PARTSTAT on each VEVENT of the meeting the server holds, by RECURRENCE-ID ("" for the series).
    func serverAnswers(of guest: String) async throws -> [String: String] {
        let ics = try #require(await caldav.events(in: work).values.first)
        let calendar = try ICalendarReader.calendar(Data(ics.utf8))
        var answers: [String: String] = [:]
        for event in calendar.components where event.name == "VEVENT" {
            let line = event.all("ATTENDEE").first { EventMapping.address($0.value).lowercased() == guest }
            answers[event.first("RECURRENCE-ID")?.value ?? ""] = line.map { $0.parameter("PARTSTAT") ?? "NEEDS-ACTION" }
        }
        return answers
    }

    func event() throws -> EventID {
        try #require(try store.occurrences(
            from: fixedNow, to: fixedNow.addingTimeInterval(7 * 86_400), in: nil
        ).first).id
    }

    /// The mail the fake SMTP server took: each one's method, recipients and calendar part, read.
    func sent() async throws -> [(method: String?, to: [String], calendar: ICalComponent?)] {
        try await mail.smtp.received.map { received in
            let message = try MIMEParser.parse(received.data)
            let calendar = try message.calendar.map { try ICalendarReader.calendar($0.data) }
            return (calendar?.first("METHOD")?.value, message.to.map(\.email).sorted(), calendar)
        }
    }
}

/// `foldersListed` false: the account's folders are not in the store yet (no Drafts to send from).
func withMeetings(
    schedules: Bool, foldersListed: Bool = true, _ body: (MeetingHarness) async throws -> Void
) async throws {
    try await withHarness { mailHarness in
        let caldav = FakeCalDAVServer(user: FakeIMAPServer.user, password: FakeIMAPServer.password)
        let port = try await caldav.start()
        do {
            if !schedules { await caldav.stopAutoScheduling() }
            var account = mailHarness.account
            account.calDAV = "http://127.0.0.1:\(port)/"
            try mailHarness.store.save(account)
            let work = await caldav.addCalendar("Work")
            let h = MeetingHarness(
                mail: Harness(
                    imap: mailHarness.imap, smtp: mailHarness.smtp, imapPort: mailHarness.imapPort,
                    store: mailHarness.store, secrets: mailHarness.secrets, account: account),
                caldav: caldav, work: work)
            let syncer = AccountSyncer(
                account: account, store: h.store, secrets: h.mail.secrets, now: { fixedNow }, phoneZone: { stockholm })
            if foldersListed {
                try await syncer.syncFolders()
                try await h.round()
            }
            try await body(h)
        } catch {
            await caldav.stop()
            throw error
        }
        await caldav.stop()
    }
}

@Suite struct MeetingInvitationTests {
    @Test func aNewMeetingIsMailedToItsGuestsOnceWhereTheServerDoesNotSchedule() async throws {
        try await withMeetings(schedules: false) { h in
            _ = try h.store.createEvent(
                h.details(["bo@example.org", "cy@example.org"]), rule: nil, in: try h.calendar())
            try await h.round()
            try await h.round()

            let sent = try await h.sent()
            #expect(sent.map(\.method) == ["REQUEST"])
            #expect(sent.first?.to == ["bo@example.org", "cy@example.org"])
            let event = try #require(sent.first?.calendar?.components.first { $0.name == "VEVENT" })
            #expect(event.first("SUMMARY")?.value == "Planning")
            #expect(EventMapping.address(event.first("ORGANIZER")?.value ?? "") == h.account.email)
            // Sent from Drafts like any mail: it leaves no draft behind.
            #expect(try h.mail.rows(.drafts).isEmpty)
        }
    }

    @Test func aGuestIsAddressedByTheNameTheMeetingGivesThem() async throws {
        try await withMeetings(schedules: false) { h in
            var details = h.details([])
            details.attendees = [Attendee(email: "Bo@Example.org", name: "Bo Berg", rsvp: true)]
            _ = try h.store.createEvent(details, rule: nil, in: try h.calendar())
            try await h.round()
            try await h.round()

            let received = try #require(await h.mail.smtp.received.first)
            let to = try MIMEParser.parse(received.data).to
            #expect(to.map(\.email) == ["bo@example.org"])
            #expect(to.map(\.name) == ["Bo Berg"])
        }
    }

    @Test func aServerThatSchedulesSendsTheInvitationsItselfSoTheAppMailsNone() async throws {
        try await withMeetings(schedules: true) { h in
            _ = try h.store.createEvent(h.details(["bo@example.org"]), rule: nil, in: try h.calendar())
            try await h.round()
            try await h.round()

            #expect(await h.mail.smtp.received.isEmpty)
        }
    }

    @Test func aMeetingWithoutGuestsMailsNobody() async throws {
        try await withMeetings(schedules: false) { h in
            _ = try h.store.createEvent(h.details([]), rule: nil, in: try h.calendar())
            try await h.round()

            #expect(await h.mail.smtp.received.isEmpty)
        }
    }

    @Test func aChangeIsMailedToTheGuestsAndAGuestTakenOffGetsACancel() async throws {
        try await withMeetings(schedules: false) { h in
            _ = try h.store.createEvent(
                h.details(["bo@example.org", "cy@example.org"]), rule: nil, in: try h.calendar())
            try await h.round()
            let id = try h.event()
            try h.store.updateEvent(
                id, h.details(["bo@example.org"], title: "Planning, moved"), rule: nil, scope: .event)
            try await h.round()
            try await h.round()

            let sent = try await h.sent()
            #expect(sent.map(\.method) == ["REQUEST", "REQUEST", "CANCEL"])
            #expect(sent.dropFirst().first?.to == ["bo@example.org"])
            let update = try #require(sent.dropFirst().first?.calendar?.components.first { $0.name == "VEVENT" })
            #expect(update.first("SUMMARY")?.text == "Planning, moved")
            #expect(update.first("SEQUENCE")?.value == "1")
            #expect(sent.last?.to == ["cy@example.org"])
        }
    }

    @Test func aDeletedMeetingIsCancelledForItsGuests() async throws {
        try await withMeetings(schedules: false) { h in
            _ = try h.store.createEvent(
                h.details(["bo@example.org", "cy@example.org"]), rule: nil, in: try h.calendar())
            try await h.round()
            try h.store.deleteEvent(try h.event(), scope: .event)
            try await h.round()
            try await h.round()

            let sent = try await h.sent()
            #expect(sent.map(\.method) == ["REQUEST", "CANCEL"])
            #expect(sent.last?.to == ["bo@example.org", "cy@example.org"])
            let cancel = try #require(sent.last?.calendar?.components.first { $0.name == "VEVENT" })
            #expect(cancel.first("STATUS")?.value == "CANCELLED")
        }
    }

    @Test func aChangeWhoseAnswerWasLostIsStillMailedOnce() async throws {
        try await withMeetings(schedules: false) { h in
            _ = try h.store.createEvent(
                h.details(["bo@example.org", "cy@example.org"]), rule: nil, in: try h.calendar())
            try await h.round()
            await h.caldav.dropNextPutAnswer()
            try h.store.updateEvent(try h.event(), h.details(["bo@example.org"], title: "Moved"), rule: nil, scope: .event)
            try? await h.round()
            try await h.round()
            try await h.round()

            #expect(try await h.sent().map(\.method) == ["REQUEST", "REQUEST", "CANCEL"])
            #expect(try h.store.pendingEventChanges(h.account.id).isEmpty)
            let shown = try h.store.occurrences(from: fixedNow, to: fixedNow.addingTimeInterval(7 * 86_400), in: nil)
            #expect(shown.allSatisfy { $0.conflict == nil && !$0.changeFailed })
        }
    }

    @Test func aDeleteWhoseAnswerWasLostStillCancels() async throws {
        try await withMeetings(schedules: false) { h in
            _ = try h.store.createEvent(h.details(["bo@example.org"]), rule: nil, in: try h.calendar())
            try await h.round()
            await h.caldav.dropNextDeleteAnswer()
            try h.store.deleteEvent(try h.event(), scope: .event)
            try? await h.round()
            try await h.round()
            try await h.round()

            #expect(try await h.sent().map(\.method) == ["REQUEST", "CANCEL"])
            #expect(try h.store.pendingEventChanges(h.account.id).isEmpty)
        }
    }

    @Test func aMeetingMadeBeforeTheFoldersAreListedIsMailedOnceThereIsADrafts() async throws {
        try await withMeetings(schedules: false, foldersListed: false) { h in
            let calendars = CalendarSyncer(
                account: h.account, store: h.store, secrets: h.mail.secrets,
                session: URLSession(configuration: .ephemeral), now: { fixedNow }, phoneZone: { stockholm })
            try await calendars.sync()
            _ = try h.store.createEvent(h.details(["bo@example.org"]), rule: nil, in: try h.calendar())
            try await calendars.sync()
            #expect(try h.store.pendingEventChanges(h.account.id).isEmpty)

            try await AccountSyncer(
                account: h.account, store: h.store, secrets: h.mail.secrets, now: { fixedNow },
                phoneZone: { stockholm }
            ).syncFolders()
            try await h.round()
            try await h.round()

            #expect(try await h.sent().map(\.method) == ["REQUEST"])
        }
    }
}
