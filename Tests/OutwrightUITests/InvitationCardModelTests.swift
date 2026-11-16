// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightDAV
import OutwrightMIME
import OutwrightModel
import OutwrightStore
@testable import OutwrightSync
import Testing

@testable import OutwrightUI

private let organizer = "maja.ek@example.org"

/// The calendar fixture (anna@example.org, calendar "Work") with invitations from Maja Ek to Anna and
/// the messages that carried them.
@MainActor private struct InviteBench {
    let fixture: CalendarFixture
    var store: MailStore { fixture.store }
    var anna: Account { fixture.box.accounts[0] }

    init() throws {
        fixture = try CalendarFixture()
    }

    /// The server's copy of an invitation to Anna, an hour long from `hour` on November `day`.
    @discardableResult
    func invited(
        _ title: String = "Planning", day: Int = 10, hour: Int = 9, response: Attendee.Response = .needsAction,
        status: EventStatus = .confirmed, rule: RecurrenceRule? = nil, uid: String = "inv1@example.org",
        clientReplies: Bool = false
    ) throws -> EventID {
        let start = fixture.at(day: day, hour)
        // The copy as the server holds it; with `clientReplies` its ORGANIZER leaves replies to the app.
        let agent = clientReplies ? ";SCHEDULE-AGENT=CLIENT" : ""
        let ics = Data(
            ["BEGIN:VCALENDAR", "BEGIN:VEVENT", "UID:\(uid)", "ORGANIZER\(agent):mailto:\(organizer)",
             "ATTENDEE:mailto:anna@example.org", "END:VEVENT", "END:VCALENDAR", ""].joined(separator: "\r\n").utf8)
        return try fixture.add(
            EventDetails(
                title: title, place: "Room 4", start: .utc(start), end: .utc(start.addingTimeInterval(3_600)),
                attendees: [
                    Attendee(email: organizer, name: "Maja Ek", response: .accepted),
                    Attendee(email: "anna@example.org", name: "Anna", response: response)
                ],
                organizer: organizer, status: status),
            rule: rule, uid: uid, ics: ics)
    }

    /// A message read as an invitation about `uid`.
    @discardableResult
    func message(
        _ number: UInt32, _ method: InvitationMethod = .request, uid: String = "inv1@example.org", sequence: Int = 0,
        event: EventID?, applied: Bool = true, recurrenceID: EventTime? = nil, timeMoved: Bool? = nil,
        reply: (email: String, response: Attendee.Response)? = nil, title: String? = "Planning"
    ) throws -> MessageID {
        let id = try fixture.box.add(anna, uid: number, from: organizer, subject: "Invitation: Planning")
        try store.recordInvitation(
            message: id, method: method, uid: uid, recurrenceID: recurrenceID, sequence: sequence, event: event,
            applied: applied, reply: reply, timeMoved: timeMoved, title: title)
        return id
    }

    /// An iTIP object of Maja's meeting with Anna on November 10, an hour from `start` (UTC).
    static func ics(
        method: String? = "REQUEST", sequence: Int, start: String = "080000", title: String = "Planning",
        partstat: String = "NEEDS-ACTION"
    ) -> Data {
        let end = String(format: "%02d", (Int(start.prefix(2)) ?? 8) + 1) + "0000"
        let lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Example//EN"] + (method.map { ["METHOD:\($0)"] } ?? [])
            + [
                "BEGIN:VEVENT", "UID:inv1@example.org", "DTSTAMP:2026110\(sequence + 1)T080000Z", "SEQUENCE:\(sequence)",
                "DTSTART:20261110T\(start)Z", "DTEND:20261110T\(end)Z", "SUMMARY:\(title)",
                "ORGANIZER;CN=Maja Ek:mailto:\(organizer)", "ATTENDEE;CN=Maja Ek;PARTSTAT=ACCEPTED:mailto:\(organizer)",
                "ATTENDEE;CN=Anna;PARTSTAT=\(partstat):mailto:anna@example.org", "END:VEVENT", "END:VCALENDAR", ""
            ]
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    /// The server's own copy of the meeting, as a calendar sync stores it.
    @discardableResult
    func serverCopy(_ data: Data) throws -> EventID {
        let series = try #require(EventMapping.series(try ICalendarReader.calendar(data)).first)
        try store.upsertRemote(
            href: "/cal/work/inv1.ics", etag: "e\(data.hashValue)", ics: data, series: series, in: try fixture.calendar("Work").id,
            window: CalendarWindow.window(now: calendarNow, zone: stockholm), phoneZone: stockholm, scheduleTag: nil)
        return try #require(try store.invitationEvent(accountId: anna.id, uid: "inv1@example.org"))
    }

    /// Delivers a message carrying `ics` from Maja and takes it through the intake, as a fetched body is.
    @discardableResult
    func receive(_ ics: Data, _ number: UInt32) throws -> MessageID {
        let body = try MIMEWriter.write(
            OutgoingMessage(
                from: Address(name: "Maja Ek", email: organizer), to: [Address(name: nil, email: anna.email)], cc: [],
                bcc: [], subject: "Planning", textBody: "Planning.", htmlBody: nil, attachments: [], inReplyTo: nil,
                references: [], date: calendarNow, messageID: "m\(number)@example.org",
                calendar: CalendarPart(method: "REQUEST", data: ics)),
            includeBcc: false)
        let id = try fixture.box.add(anna, uid: number, from: organizer, subject: "Planning", body: body)
        let row = try #require(try store.message(id))
        try InvitationIntake.process(
            row, parsed: try MIMEParser.parse(body), account: anna, folder: try fixture.box.folder(anna, .inbox),
            store: store, window: CalendarWindow.window(now: calendarNow, zone: stockholm), phoneZone: stockholm,
            now: calendarNow)
        return id
    }

    func card(_ message: MessageID) -> InvitationCardModel {
        InvitationCardModel(app: fixture.app, message: message, calendar: phoneCalendar())
    }

    func pending(_ id: EventID) throws -> [EventEdit] {
        try store.pendingEventChanges(anna.id).first { $0.event == id }?.edits ?? []
    }
}

@MainActor @Suite struct InvitationCardModelTests {
    @Test func invitedCardOffersTheThreeAnswers() throws {
        let bench = try InviteBench()
        let id = try bench.invited()
        let card = bench.card(try bench.message(1, event: id))
        #expect(card.isShown)
        #expect(card.headline == .invited)
        #expect(card.canAnswer)
        #expect(card.response == .needsAction)
        #expect(card.title == "Planning")
        #expect(card.place == "Room 4")
        #expect(card.organizer == "Maja Ek")
        #expect(!card.timeText.isEmpty)
        #expect(card.zoneNote == nil)
    }

    @Test func answeredCardShowsTheAnswer() throws {
        let bench = try InviteBench()
        let id = try bench.invited()
        let card = bench.card(try bench.message(1, event: id))
        try card.answer(.accepted, sendReply: true, scope: .event)
        #expect(card.response == .accepted)
        // The answer can be changed.
        #expect(card.canAnswer)
        #expect(try bench.pending(id) == [.respond(.accepted, scope: .event, sendReply: true)])
        #expect(try bench.store.event(id, occurrence: nil)?.isTentative == false)
    }

    @Test func timeMovedUpdateAsksAgain() throws {
        let bench = try InviteBench()
        // Anna accepted the first version; the server holds it so.
        try bench.serverCopy(InviteBench.ics(method: nil, sequence: 0, partstat: "ACCEPTED"))
        let first = try bench.receive(InviteBench.ics(sequence: 0), 1)
        #expect(bench.card(first).response == .accepted)
        // Maja moves it two hours later.
        let update = bench.card(try bench.receive(InviteBench.ics(sequence: 1, start: "100000"), 2))
        #expect(update.headline == .updated(timeMoved: true))
        #expect(update.response == .needsAction)
        #expect(update.canAnswer)
        #expect(bench.card(first).headline == .outdated)
        // Then renames it at the same time.
        let renamed = bench.card(try bench.receive(InviteBench.ics(sequence: 2, start: "100000", title: "Plans"), 3))
        #expect(renamed.headline == .updated(timeMoved: false))
    }

    @Test func anUpdateTheServerAppliedFirstReadsAsUpdated() throws {
        let bench = try InviteBench()
        try bench.serverCopy(InviteBench.ics(method: nil, sequence: 0, partstat: "ACCEPTED"))
        try bench.receive(InviteBench.ics(sequence: 0), 1)
        // The server applied Maja's second version before its mail came.
        try bench.serverCopy(InviteBench.ics(method: nil, sequence: 1, partstat: "ACCEPTED"))
        let card = bench.card(try bench.receive(InviteBench.ics(sequence: 1), 2))
        #expect(card.headline == .updated(timeMoved: false))
        #expect(card.response == .accepted)
        #expect(card.canAnswer)
    }

    @Test func cancelledCardOffersRemove() throws {
        let bench = try InviteBench()
        let id = try bench.invited(status: .cancelled)
        let card = bench.card(try bench.message(1, .cancel, sequence: 1, event: id))
        #expect(card.headline == .cancelled)
        #expect(!card.canAnswer)
        #expect(card.canRemove)
        try card.removeFromCalendar()
        #expect(try bench.pending(id) == [.delete(scope: .event)])
        #expect(!card.canRemove)
        // The card still says what was cancelled, and so it does when the message is opened again.
        #expect(card.title == "Planning")
        let reopened = bench.card(card.message)
        #expect(reopened.isShown)
        #expect(reopened.headline == .cancelled)
        #expect(reopened.title == "Planning")
        #expect(!reopened.canRemove)
        #expect(!reopened.canAnswer)
    }

    @Test func aFirstInvitationAfterTheOrganisersEditsReadsAsInvited() throws {
        let bench = try InviteBench()
        // Edited twice before it was sent: the server holds it at SEQUENCE 2, and so does the mail.
        try bench.serverCopy(InviteBench.ics(method: nil, sequence: 2))
        let card = bench.card(try bench.receive(InviteBench.ics(sequence: 2), 1))
        #expect(card.headline == .invited)
        #expect(card.canAnswer)
    }

    @Test func aReplyWithoutTitleNamesTheMeetingBySubject() throws {
        let bench = try InviteBench()
        let card = bench.card(
            try bench.message(
                1, .reply, uid: "gone@example.org", event: nil, applied: false, reply: (organizer, .accepted),
                title: nil))
        #expect(card.title == "Invitation: Planning")
    }

    @Test func aReplyForAMeetingNotHeldIsAnOrdinaryMessage() throws {
        let bench = try InviteBench()
        let card = bench.card(
            try bench.message(
                1, .reply, uid: "gone@example.org", event: nil, applied: false, reply: (organizer, .declined),
                title: "Review"))
        #expect(!card.isShown)
        #expect(!card.canAnswer)
        #expect(!card.canRemove)
    }

    @Test func aReplyForSomeoneElsesMeetingIsAnOrdinaryMessage() throws {
        let bench = try InviteBench()
        // Maja's meeting, which Anna is invited to: an answer to it is Maja's business.
        try bench.invited()
        let card = bench.card(try bench.message(1, .reply, event: nil, applied: false, reply: (organizer, .accepted)))
        #expect(!card.isShown)
    }

    @Test func aReplyFromSomeoneNotInvitedIsAnOrdinaryMessage() throws {
        let bench = try InviteBench()
        let start = bench.fixture.at(day: 10, 9)
        try bench.fixture.add(
            EventDetails(
                title: "Review", start: .utc(start), end: .utc(start.addingTimeInterval(3_600)),
                attendees: [
                    Attendee(email: "anna@example.org", name: "Anna", response: .accepted),
                    Attendee(email: organizer, name: "Maja Ek", response: .needsAction)
                ],
                organizer: "anna@example.org"),
            uid: "own1@example.org")
        let card = bench.card(
            try bench.message(
                1, .reply, uid: "own1@example.org", event: nil, applied: false,
                reply: ("eve@example.org", .accepted)))
        #expect(!card.isShown)
    }

    @Test func replyCardNamesWhoAnswered() throws {
        let bench = try InviteBench()
        let start = bench.fixture.at(day: 10, 9)
        let own = try bench.fixture.add(
            EventDetails(
                title: "Review", start: .utc(start), end: .utc(start.addingTimeInterval(3_600)),
                attendees: [
                    Attendee(email: "anna@example.org", name: "Anna", response: .accepted),
                    Attendee(email: organizer, name: "Maja Ek", response: .needsAction)
                ],
                organizer: "anna@example.org"),
            uid: "own1@example.org")
        let card = bench.card(
            try bench.message(
                1, .reply, uid: "own1@example.org", event: nil, applied: false, reply: (organizer, .tentative)))
        #expect(card.headline == .replied(name: "Maja Ek", response: .tentative))
        #expect(!card.canAnswer)
        #expect(!card.canRemove)
        #expect(card.event?.id == own)
        // A REPLY whose sender is not the attendee names no one and shows no card.
        let spoofed = bench.card(try bench.message(2, .reply, uid: "own1@example.org", event: nil, applied: false))
        #expect(!spoofed.isShown)
    }

    @Test func outdatedCardSaysSo() throws {
        let bench = try InviteBench()
        let id = try bench.invited()
        let old = try bench.message(1, event: id)
        try bench.message(2, sequence: 3, event: id, timeMoved: false)
        let card = bench.card(old)
        #expect(card.headline == .outdated)
        #expect(!card.canAnswer)
        #expect(!card.canRemove)
    }

    @Test func unappliedInvitationShowsNoButtons() throws {
        let bench = try InviteBench()
        try bench.invited()
        // The sender check failed: the message changed nothing, though the calendar has the UID. It is
        // an ordinary message.
        let card = bench.card(try bench.message(1, sequence: 4, event: nil, applied: false))
        #expect(!card.isShown)
        #expect(!card.canAnswer)
        #expect(!card.canRemove)
        // A cancellation that was not applied does not say the meeting is off.
        let cancel = bench.card(try bench.message(2, .cancel, sequence: 5, event: nil, applied: false))
        #expect(!cancel.isShown)
        #expect(!cancel.canRemove)
    }

    @Test func aroundShowsClashes() throws {
        let bench = try InviteBench()
        let id = try bench.invited()
        try bench.fixture.timed("Stand-up", day: 10, 9, 30, minutes: 30)
        try bench.fixture.timed("Coffee", day: 10, 7, 30, minutes: 20)
        try bench.fixture.timed("Lunch", day: 10, 12)
        try bench.fixture.timed("Early", day: 10, 8, 15, minutes: 30, in: "Home")
        let card = bench.card(try bench.message(1, event: id))
        #expect(Set(card.around.map(\.occurrence.details.title)) == ["Stand-up", "Early"])
        #expect(card.around.allSatisfy { $0.id != id })
    }

    @Test func seriesAnswerAsksScope() throws {
        let bench = try InviteBench()
        let id = try bench.invited(rule: RecurrenceRule(freq: .weekly, count: 4))
        let series = bench.card(try bench.message(1, event: id))
        #expect(series.occurrenceScope == nil)
        let second = EventTime.utc(bench.fixture.at(day: 17, 9))
        let one = bench.card(try bench.message(2, sequence: 1, event: id, recurrenceID: second))
        #expect(one.occurrenceScope == .occurrence(second))
        try one.answer(.declined, sendReply: true, scope: .occurrence(second))
        #expect(try bench.pending(id) == [.respond(.declined, scope: .occurrence(second), sendReply: true)])
    }

    @Test func cardFindsTheOccurrenceInAnotherTimeForm() throws {
        let bench = try InviteBench()
        let id = try bench.invited(rule: RecurrenceRule(freq: .weekly, count: 4))
        // The third occurrence, named by Stockholm wall time where the calendar holds UTC.
        let wall = DateComponents(year: 2026, month: 11, day: 24, hour: 9, minute: 0, second: 0)
        let card = bench.card(
            try bench.message(1, sequence: 1, event: id, recurrenceID: .zoned(wall, zone: "Europe/Stockholm")))
        #expect(card.event?.occurrence.start == bench.fixture.at(day: 24, 9))
        #expect(card.occurrenceScope == .occurrence(.utc(bench.fixture.at(day: 24, 9))))
    }

    @Test func theSendChoiceOnlyWhereTheAppSendsTheReply() throws {
        let bench = try InviteBench()
        let id = try bench.invited(clientReplies: true)
        let card = bench.card(try bench.message(1, event: id))
        #expect(card.canWithholdReply)
        try card.answer(.tentative, sendReply: false, scope: .event)
        #expect(try bench.pending(id) == [.respond(.tentative, scope: .event, sendReply: false)])

        // A copy the server schedules, with no Schedule-Tag held yet: the server still answers.
        let other = try bench.invited("Other", day: 11, uid: "inv2@example.org")
        let scheduled = bench.card(try bench.message(2, uid: "inv2@example.org", event: other))
        #expect(!scheduled.canWithholdReply)
        // The server answers such a copy whatever the app says: the answer goes as one that is sent.
        try scheduled.answer(.accepted, sendReply: false, scope: .event)
        #expect(try bench.pending(other) == [.respond(.accepted, scope: .event, sendReply: true)])
    }

    @Test func anAnswerTheServerSentAlthoughItWasKeptBackSaysSo() throws {
        let bench = try InviteBench()
        let id = try bench.invited(clientReplies: true)
        let card = bench.card(try bench.message(1, event: id))
        try card.answer(.accepted, sendReply: false, scope: .event)
        #expect(!card.replySentByServer)
        // The server had scheduled the copy by the time the answer reached it.
        let queued = try #require(try bench.store.pendingEventChanges(bench.anna.id).first { $0.event == id })
        let held = try #require(try bench.store.series(id))
        try bench.store.respondDone(
            id, revision: queued.revision, href: "/cal/inv1@example.org.ics", etag: "2", ics: Data(), series: held,
            reply: nil, scheduleTag: "s1", repliedByServer: true)
        card.reload()
        #expect(card.replySentByServer)
        #expect(!card.canWithholdReply)
        // A later answer, sent as asked, is an ordinary one again.
        try card.answer(.declined, sendReply: true, scope: .event)
        let next = try #require(try bench.store.pendingEventChanges(bench.anna.id).first { $0.event == id })
        try bench.store.respondDone(
            id, revision: next.revision, href: "/cal/inv1@example.org.ics", etag: "3", ics: Data(), series: held,
            reply: nil, scheduleTag: "s1")
        card.reload()
        #expect(!card.replySentByServer)
    }

    @Test func aFailedReplyIsRetried() throws {
        let bench = try InviteBench()
        let id = try bench.invited()
        let card = bench.card(try bench.message(1, event: id))
        try card.answer(.accepted, sendReply: true, scope: .event)
        // The server took the answer, and the account has no Drafts folder for its reply mail.
        let folders = try bench.store.folders(bench.anna.id).filter { $0.kind != .drafts }
        try bench.store.replaceFolders(folders, for: bench.anna.id)
        let queued = try #require(try bench.store.pendingEventChanges(bench.anna.id).first { $0.event == id })
        let held = try #require(try bench.store.series(id))
        try bench.store.respondDone(
            id, revision: queued.revision, href: "/cal/inv1@example.org.ics", etag: "2", ics: Data(), series: held,
            reply: (replyRow(bench.anna), try message(subject: "Accepted: Planning", text: "Anna has replied.")),
            scheduleTag: nil)
        card.reload()
        #expect(card.replyFailed)
        #expect(throws: InvitationError.noDraftsFolder) { try card.retryReply() }
        try bench.store.replaceFolders(folders + [drafts(bench.anna)], for: bench.anna.id)
        try card.retryReply()
        #expect(!card.replyFailed)
        #expect(try bench.pending(id) == [.respond(.accepted, scope: .event, sendReply: true)])
    }
}

/// A reply mail's row as Sync would hand it to the store.
func replyRow(_ account: Account) -> MessageRow {
    MessageRow(
        id: MessageID(raw: 0), accountID: account.id, folderID: FolderID(raw: 0), uid: 0,
        threadID: ThreadID(raw: "reply"), from: Address(name: nil, email: account.email),
        to: [Address(name: nil, email: "maja.ek@example.org")], cc: [], subject: "Accepted: Planning", preview: "",
        date: calendarNow, isRead: true, isFlagged: false, hasAttachment: false, isInvitation: true,
        inboxClass: .focused, hasBody: true, threadCount: 1, messageIDHeader: "<reply-\(UUID())@example.org>")
}

/// A Drafts folder for the account.
func drafts(_ account: Account) -> Folder {
    Folder(
        id: FolderID(raw: 0), accountID: account.id, path: "Drafts", name: "Drafts", kind: .drafts, uidValidity: 1,
        unread: 0, isFavorite: false)
}
