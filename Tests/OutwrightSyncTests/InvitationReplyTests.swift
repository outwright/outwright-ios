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

private let organizer = "org@example.org"
private let own = FakeIMAPServer.user

/// A synthetic invitation from `organizer` to the account, a day after the tests' clock, as a
/// calendar object (no METHOD) or, with `method`, as the iTIP object a mail carries.
private func invitation(
    uid: String = "inv1@example.org", title: String = "Planning", sequence: Int = 0, method: String? = nil,
    rule: String? = nil, agent: String? = nil
) -> String {
    let at = fixedNow.addingTimeInterval(24 * 3_600)
    var lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Example//EN"]
    if let method { lines.append("METHOD:\(method)") }
    lines += [
        "BEGIN:VEVENT", "UID:\(uid)", "DTSTAMP:20261101T080000Z", "SEQUENCE:\(sequence)",
        "DTSTART:\(utcText(at))", "DTEND:\(utcText(at.addingTimeInterval(3_600)))", "SUMMARY:\(title)",
        "ORGANIZER;CN=Org\(agent.map { ";SCHEDULE-AGENT=\($0)" } ?? ""):mailto:\(organizer)",
        "ATTENDEE;CN=Org;PARTSTAT=ACCEPTED:mailto:\(organizer)", "ATTENDEE;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:\(own)",
    ]
    if let rule { lines.append("RRULE:\(rule)") }
    lines += ["END:VEVENT", "END:VCALENDAR"]
    return icsText(lines)
}

/// A mail carrying `ics` as its calendar alternative, as iMIP (RFC 6047) sends it.
private func invitationMail(_ ics: String) -> Data {
    let lines = [
        "From: Org <\(organizer)>", "To: \(own)", "Subject: Invitation: Planning",
        "Date: Thu, 05 Nov 2026 10:00:00 +0000", "Message-ID: <\(UUID().uuidString)@example.org>",
        "MIME-Version: 1.0", "Content-Type: multipart/alternative; boundary=\"b1\"", "",
        "--b1", "Content-Type: text/plain; charset=utf-8", "", "You are invited.", "",
        "--b1", "Content-Type: text/calendar; charset=utf-8; method=REQUEST", "", ics, "--b1--", "",
    ]
    return Data(lines.joined(separator: "\r\n").utf8)
}

private struct ReplyHarness {
    let mail: Harness
    let caldav: FakeCalDAVServer
    let work: URL
    let path: URL?
    let wording: MeetingWording

    var store: MailStore { mail.store }
    var account: Account { mail.account }

    func calendarSyncer(_ account: Account? = nil) -> CalendarSyncer {
        CalendarSyncer(
            account: account ?? self.account, store: store, secrets: mail.secrets,
            session: URLSession(configuration: .ephemeral), now: { fixedNow }, phoneZone: { stockholm },
            meetingWording: wording)
    }

    func mailSyncer(_ account: Account? = nil) -> AccountSyncer {
        AccountSyncer(
            account: account ?? self.account, store: store, secrets: mail.secrets, now: { fixedNow },
            phoneZone: { stockholm })
    }

    /// One round: the calendar synced (its queue first), then the mail queue run.
    func round(_ account: Account? = nil) async throws {
        try await calendarSyncer(account).sync()
        try await mailSyncer(account).runActions()
    }

    /// The same harness on the store opened anew from its file.
    func reopened() throws -> ReplyHarness {
        let path = try #require(path)
        let store = try MailStore(path: path)
        return ReplyHarness(
            mail: Harness(
                imap: mail.imap, smtp: mail.smtp, imapPort: mail.imapPort, store: store, secrets: mail.secrets,
                account: account),
            caldav: caldav, work: work, path: path, wording: wording)
    }

    /// The account as it is with its servers unreachable.
    var offline: Account {
        var account = account
        account.calDAV = "http://127.0.0.1:1/"
        account.smtp = MailEndpoint(host: "127.0.0.1", port: 1, security: "plainLoopbackOnly")
        return account
    }

    /// An invitation the server holds (scheduled by it when `scheduled`), synced: its event.
    func serverInvitation(
        _ ics: String = invitation(), uid: String = "inv1", scheduled: Bool = false
    ) async throws -> EventID {
        await caldav.putEvent(ics, uid: uid, in: work)
        if scheduled {
            await caldav.markScheduled(uid: uid, in: work)
        }
        try await calendarSyncer().sync()
        let series = try #require(EventMapping.series(try ICalendarReader.calendar(Data(ics.utf8))).first)
        return try #require(try store.invitationEvent(accountId: account.id, uid: series.uid))
    }

    func event(_ id: EventID) throws -> CalendarEvent {
        try #require(try events().first { $0.id == id })
    }

    func events() throws -> [CalendarEvent] {
        var seen: Set<EventID> = []
        return try store.occurrences(
            from: fixedNow.addingTimeInterval(-400 * 86_400), to: fixedNow.addingTimeInterval(800 * 86_400), in: nil
        ).filter { seen.insert($0.id).inserted }
    }

    /// The account's PARTSTATs in the server's only object, one per VEVENT.
    func serverPartstats() async -> [String] {
        let objects = await caldav.events(in: work)
        return objects.values.first.map { FakeCalDAVServer.ownPartstats($0, own) } ?? []
    }

    /// The mail the fake SMTP server took, read.
    func sent() async throws -> [MIMEMessage] {
        try await mail.smtp.received.map { try MIMEParser.parse($0.data) }
    }
}

/// The fake IMAP, SMTP and CalDAV servers, the account on all three with a calendar "Work" and its
/// folders listed in the store (on disk at `storePath` when given).
private func withReplies(
    imap: FakeIMAPServer? = nil, storePath: URL? = nil, wording: MeetingWording = .english,
    _ body: (ReplyHarness) async throws -> Void
) async throws {
    try await withHarness(imap) { mailHarness in
        let caldav = FakeCalDAVServer(user: FakeIMAPServer.user, password: FakeIMAPServer.password)
        let port = try await caldav.start()
        do {
            let store = try storePath.map { try MailStore(path: $0) } ?? mailHarness.store
            var account = mailHarness.account
            account.calDAV = "http://127.0.0.1:\(port)/"
            try store.save(account)
            let work = await caldav.addCalendar("Work")
            let h = ReplyHarness(
                mail: Harness(
                    imap: mailHarness.imap, smtp: mailHarness.smtp, imapPort: mailHarness.imapPort, store: store,
                    secrets: mailHarness.secrets, account: account),
                caldav: caldav, work: work, path: storePath, wording: wording)
            let syncer = h.mailSyncer()
            try await syncer.syncFolders()
            try await syncer.sync(try h.mail.folder(.inbox).id)
            try await h.calendarSyncer().sync()
            try await body(h)
        } catch {
            await caldav.stop()
            throw error
        }
        await caldav.stop()
    }
}

/// The REPLY's own VEVENT lines: the ATTENDEEs, with their PARTSTAT.
private func replyAttendees(_ message: MIMEMessage) throws -> [(email: String, partstat: String?)] {
    let part = try #require(message.calendar)
    let calendar = try ICalendarReader.calendar(part.data)
    let event = try #require(calendar.components.first { $0.name == "VEVENT" })
    return event.all("ATTENDEE").map { (EventMapping.address($0.value), $0.parameter("PARTSTAT")) }
}

@Suite struct InvitationReplyTests {
    /// The app's own copy of the invitation, from its mail: queued as a create, not sent yet.
    fileprivate func appCopy(_ h: ReplyHarness) async throws -> EventID {
        await h.mail.imap.deliver(invitationMail(invitation(method: "REQUEST")), to: "INBOX")
        let syncer = h.mailSyncer()
        try await syncer.sync(try h.mail.folder(.inbox).id)
        let row = try #require(try h.mail.rows(.inbox).first)
        try await syncer.fetchBody(row.id)
        let event = try #require(try h.events().first)
        #expect(event.origin == .app)
        return event.id
    }

    /// The app's own copy, on the server as the client's to answer from: its first answer, tentative,
    /// went without a response (RFC 6638 › 7.1, `SCHEDULE-AGENT=CLIENT`).
    fileprivate func clientAppCopy(_ h: ReplyHarness) async throws -> EventID {
        let id = try await appCopy(h)
        try h.store.respond(id, .tentative, scope: .event, sendReply: false)
        try await h.round()
        return id
    }

    @Test func anAnswerOnTheAppsCopyIsSentByTheServer() async throws {
        try await withReplies { h in
            let id = try await appCopy(h)
            try h.store.respond(id, .accepted, scope: .event, sendReply: true)
            try await h.round()

            // RFC 6638 › 3.2.2.3: the server replies to a changed PARTSTAT; the app mails nothing.
            #expect(await h.caldav.serverReplies.map(\.partstat) == ["ACCEPTED"])
            #expect(await h.mail.smtp.received.isEmpty)
            #expect(try h.mail.rows(.drafts).isEmpty)
            #expect(await h.serverPartstats() == ["ACCEPTED"])
            // The create held the invitation as it came; the answer was a change to it.
            let created = try #require(await h.caldav.created.first?.ics)
            #expect(FakeCalDAVServer.ownPartstats(created, own) == ["NEEDS-ACTION"])
            // A calendar object resource carries no iTIP METHOD (RFC 4791 › 4.1).
            let object = try #require(await h.caldav.events(in: h.work).values.first)
            #expect(!object.contains("METHOD:"))
        }
    }

    @Test func aSentAnswerThenAWithheldOneBeforeTheCreateMailsOnlyTheSentOne() async throws {
        try await withReplies { h in
            let id = try await appCopy(h)
            // Both given before the create leaves: the server must not send the one kept back.
            try h.store.respond(id, .accepted, scope: .event, sendReply: true)
            try h.store.respond(id, .tentative, scope: .event, sendReply: false)
            try await h.round()
            try await h.round()

            #expect(await h.caldav.serverReplies.isEmpty)
            #expect(try await h.sent().map(\.subject) == ["Accepted: Planning"])
            #expect(await h.serverPartstats() == ["TENTATIVE"])
            let object = try #require(await h.caldav.events(in: h.work).values.first)
            #expect(object.contains("SCHEDULE-AGENT=CLIENT"))
        }
    }

    @Test func anAnswerRefusedAfterItsCreateLandedIsWrittenNextRound() async throws {
        try await withReplies { h in
            try h.store.respond(try await appCopy(h), .accepted, scope: .event, sendReply: true)
            // The server changes the object as it stores the create: the answer's If-Match misses.
            await h.caldav.changeTheNextCreateOnStore()
            try await h.round()
            try await h.round()

            #expect(await h.serverPartstats() == ["ACCEPTED"])
            #expect(await h.caldav.serverReplies.map(\.partstat) == ["ACCEPTED"])
            // The sync may have taken the landed create as the server's copy: one event, answered.
            let events = try h.events()
            #expect(events.count == 1)
            #expect(events.allSatisfy { $0.conflict == nil && !$0.changeFailed && $0.ownResponse == .accepted })
            #expect(try h.store.pendingEventChanges(h.account.id).isEmpty)
        }
    }

    @Test func onAServerThatDoesNotScheduleTheAppMailsEveryAnswerOnce() async throws {
        try await withReplies { h in
            // RFC 6638 › 2: no `calendar-auto-schedule`, so no REPLY comes from the server.
            await h.caldav.stopAutoScheduling()
            let mine = try await appCopy(h)
            let server = try await h.serverInvitation(
                invitation(uid: "inv2@example.org", title: "Review"), uid: "inv2")
            try h.store.respond(server, .accepted, scope: .event, sendReply: true)
            try h.store.respond(mine, .declined, scope: .event, sendReply: true)
            try await h.round()
            try await h.round()

            #expect(await h.caldav.serverReplies.isEmpty)
            #expect(Set(try await h.sent().compactMap(\.subject)) == ["Accepted: Review", "Declined: Planning"])
            #expect(try await h.sent().count == 2)
            #expect(ReplyRoute.canWithholdReply(
                copy: try h.store.eventObject(server), onServer: true, serverSchedules: false))
        }
    }

    @Test func anAnswerOnAServerCopyWithoutAScheduleTagIsSentByTheServer() async throws {
        try await withReplies { h in
            let id = try await h.serverInvitation()
            #expect(try h.store.scheduleTag(id) == nil)
            try h.store.respond(id, .accepted, scope: .event, sendReply: true)
            try await h.round()

            #expect(await h.caldav.serverReplies.map(\.partstat) == ["ACCEPTED"])
            #expect(await h.mail.smtp.received.isEmpty)
        }
    }

    @Test func aWithheldFirstAnswerMakesTheAppsCopyTheAppsToAnswer() async throws {
        try await withReplies { h in
            let id = try await appCopy(h)
            try h.store.respond(id, .accepted, scope: .event, sendReply: false)
            try await h.round()

            let object = try #require(await h.caldav.events(in: h.work).values.first)
            #expect(object.contains("SCHEDULE-AGENT=CLIENT"))
            #expect(await h.serverPartstats() == ["ACCEPTED"])
            #expect(await h.caldav.serverReplies.isEmpty)
            #expect(await h.mail.smtp.received.isEmpty)

            // The copy says the client handles its replies (RFC 6638 › 7.1): a later answer is mailed.
            try h.store.respond(id, .declined, scope: .event, sendReply: true)
            try await h.round()
            try await h.round()
            #expect(try await h.sent().map(\.subject) == ["Declined: Planning"])
            #expect(await h.caldav.serverReplies.isEmpty)
            #expect(await h.serverPartstats() == ["DECLINED"])
        }
    }

    @Test func acceptOnServerCopySendsNoMail() async throws {
        try await withReplies { h in
            let id = try await h.serverInvitation(scheduled: true)
            #expect(try h.store.scheduleTag(id) != nil)
            try h.store.respond(id, .accepted, scope: .event, sendReply: true)
            try await h.round()

            #expect(await h.mail.smtp.received.isEmpty)
            #expect(try h.mail.rows(.drafts).isEmpty)
            #expect(await h.serverPartstats() == ["ACCEPTED"])
            // The one REPLY is the server's.
            #expect(await h.caldav.serverReplies.map(\.partstat) == ["ACCEPTED"])
        }
    }

    @Test func offlineAnswerSendsOneReply() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try await withReplies(storePath: folder.appendingPathComponent("store.sqlite")) { h in
            let id = try await h.serverInvitation(invitation(agent: "CLIENT"))
            try h.store.respond(id, .accepted, scope: .event, sendReply: true)
            // Both servers out of reach: nothing leaves.
            try? await h.round(h.offline)
            // The app killed and opened again; the calendar back but not the mail server.
            var reopened = try h.reopened()
            var calendarOnly = reopened.account
            calendarOnly.smtp = h.offline.smtp
            try? await reopened.round(calendarOnly)
            #expect(await h.serverPartstats() == ["ACCEPTED"])
            #expect(await h.mail.smtp.received.isEmpty)
            // Killed again, then both servers back: two rounds, one REPLY.
            reopened = try reopened.reopened()
            try await reopened.round()
            try await reopened.round()

            let sent = try await h.sent()
            #expect(sent.map(\.subject) == ["Accepted: Planning"])
        }
    }

    @Test func changingTheAnswerSendsANewReply() async throws {
        try await withReplies { h in
            let id = try await h.serverInvitation(invitation(agent: "CLIENT"))
            try h.store.respond(id, .accepted, scope: .event, sendReply: true)
            try await h.round()
            try h.store.respond(id, .declined, scope: .event, sendReply: true)
            try await h.round()

            let sent = try await h.sent()
            #expect(sent.map(\.subject) == ["Accepted: Planning", "Declined: Planning"])
            #expect(try sent.last.map(replyAttendees)?.first?.partstat == "DECLINED")
            #expect(await h.serverPartstats() == ["DECLINED"])
        }
    }

    @Test func twoAnswersSentTogetherEachGetTheirReply() async throws {
        try await withReplies { h in
            let id = try await h.serverInvitation(invitation(agent: "CLIENT"))
            try h.store.respond(id, .accepted, scope: .event, sendReply: true)
            try h.store.respond(id, .tentative, scope: .event, sendReply: true)
            try await h.round()
            try await h.round()

            let sent = try await h.sent()
            #expect(sent.map(\.subject) == ["Accepted: Planning", "Tentative: Planning"])
            #expect(await h.serverPartstats() == ["TENTATIVE"])
        }
    }

    @Test func noResponseSendsNothing() async throws {
        try await withReplies { h in
            let id = try await h.serverInvitation(invitation(agent: "CLIENT"))
            #expect(ReplyRoute.canWithholdReply(
                copy: try h.store.eventObject(id), onServer: try h.store.isOnServer(id), serverSchedules: true))
            try h.store.respond(id, .accepted, scope: .event, sendReply: false)
            try await h.round()

            #expect(await h.serverPartstats() == ["ACCEPTED"])
            #expect(await h.caldav.serverReplies.isEmpty)
            #expect(await h.mail.smtp.received.isEmpty)
            #expect(try h.mail.rows(.drafts).isEmpty)
        }
    }

    @Test func replyIsFiledInSent() async throws {
        try await withReplies { h in
            let id = try await h.serverInvitation(invitation(agent: "CLIENT"))
            try h.store.respond(id, .accepted, scope: .event, sendReply: true)
            try await h.round()
            try await h.mailSyncer().runActions()

            #expect(await h.mail.smtp.received.count == 1)
            let filed = await h.mail.imap.messages(in: "Sent")
            #expect(filed.count == 1)
            #expect(try h.mail.rows(.sent).map(\.subject) == ["Accepted: Planning"])
            #expect(await h.mail.imap.messages(in: "Drafts").isEmpty)
        }
    }

    @Test func ownReminderChangeSendsNoReply() async throws {
        try await withReplies { h in
            let id = try await h.serverInvitation(scheduled: true)
            try h.store.setOwnReminder(id, minutes: 15, scope: .event)
            try await h.round()

            let object = try #require(await h.caldav.events(in: h.work).values.first)
            let series = try #require(EventMapping.series(try ICalendarReader.calendar(Data(object.utf8))).first)
            #expect(series.base?.reminder == 15)
            #expect(await h.serverPartstats() == ["NEEDS-ACTION"])
            #expect(await h.mail.smtp.received.isEmpty)
            #expect(await h.caldav.serverReplies.isEmpty)
            // The server's Schedule-Tag is still the one held.
            #expect(try h.store.scheduleTag(id) != nil)
        }
    }

    @Test func conflictOnRespondKeepsTheAnswer() async throws {
        try await withReplies { h in
            let id = try await h.serverInvitation(invitation(agent: "CLIENT"))
            // Another client changes the object: its ETag moves.
            await h.caldav.putEvent(invitation(title: "Planning (room)", agent: "CLIENT"), uid: "inv1", in: h.work)
            try h.store.respond(id, .accepted, scope: .event, sendReply: true)
            try await h.round()

            #expect(await h.mail.smtp.received.isEmpty)
            #expect(await h.serverPartstats() == ["NEEDS-ACTION"])
            let conflicted = try #require(try h.events().first)
            #expect(conflicted.conflict == .respond(.accepted, scope: .event, sendReply: true))

            try h.store.applyEventConflictAgain(id)
            try await h.round()
            let sent = try await h.sent()
            #expect(sent.map(\.subject) == ["Accepted: Planning (room)"])
            #expect(await h.serverPartstats() == ["ACCEPTED"])
        }
    }

    @Test func answerToOneOccurrenceRepliesForIt() async throws {
        try await withReplies { h in
            let id = try await h.serverInvitation(invitation(rule: "FREQ=WEEKLY;COUNT=4", agent: "CLIENT"))
            let occurrences = try h.store.occurrences(
                from: fixedNow, to: fixedNow.addingTimeInterval(40 * 86_400), in: nil)
            let second = try #require(occurrences.dropFirst().first)
            let recurrence = try #require(second.occurrence.recurrenceID)
            try h.store.respond(id, .declined, scope: .occurrence(recurrence), sendReply: true)
            try await h.round()

            let reply = try #require(try await h.sent().first)
            let calendar = try ICalendarReader.calendar(try #require(reply.calendar?.data))
            let event = try #require(calendar.components.first { $0.name == "VEVENT" })
            #expect(event.first("RECURRENCE-ID") != nil)
            #expect(try replyAttendees(reply).first?.partstat == "DECLINED")
            // The series stays unanswered; only that occurrence is declined.
            #expect(await h.serverPartstats() == ["NEEDS-ACTION", "DECLINED"])
        }
    }

    @Test func aWholeSeriesAnswerRepliesForTheSeriesAndEachOverride() async throws {
        // A weekly series whose second and third occurrences the organiser moved, each answered apart.
        let at = fixedNow.addingTimeInterval(24 * 3_600)
        var lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Example//EN"]
        lines += [
            "BEGIN:VEVENT", "UID:inv1@example.org", "DTSTAMP:20261101T080000Z", "SEQUENCE:0",
            "DTSTART:\(utcText(at))", "DTEND:\(utcText(at.addingTimeInterval(3_600)))", "SUMMARY:Planning",
            "RRULE:FREQ=WEEKLY;COUNT=4", "ORGANIZER;CN=Org;SCHEDULE-AGENT=CLIENT:mailto:\(organizer)",
            "ATTENDEE;CN=Org;PARTSTAT=ACCEPTED:mailto:\(organizer)",
            "ATTENDEE;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:\(own)",
            "ATTENDEE;PARTSTAT=NEEDS-ACTION:mailto:other@example.org", "END:VEVENT",
        ]
        for (week, partstat) in [(1, "DECLINED"), (2, "TENTATIVE")] {
            let start = at.addingTimeInterval(Double(week) * 7 * 86_400)
            lines += [
                "BEGIN:VEVENT", "UID:inv1@example.org", "RECURRENCE-ID:\(utcText(start))",
                "DTSTAMP:20261101T080000Z", "SEQUENCE:0", "DTSTART:\(utcText(start.addingTimeInterval(1_800)))",
                "DTEND:\(utcText(start.addingTimeInterval(5_400)))", "SUMMARY:Planning",
                "ORGANIZER;CN=Org;SCHEDULE-AGENT=CLIENT:mailto:\(organizer)", "ATTENDEE;CN=Org;PARTSTAT=ACCEPTED:mailto:\(organizer)",
                "ATTENDEE;PARTSTAT=\(partstat):mailto:\(own)", "ATTENDEE;PARTSTAT=NEEDS-ACTION:mailto:other@example.org",
                "END:VEVENT",
            ]
        }
        lines.append("END:VCALENDAR")
        try await withReplies { h in
            let id = try await h.serverInvitation(icsText(lines))
            try h.store.respond(id, .accepted, scope: .event, sendReply: true)
            try await h.round()

            let sent = try await h.sent()
            #expect(sent.count == 1)
            let reply = try #require(sent.first)
            let calendar = try ICalendarReader.calendar(try #require(reply.calendar?.data))
            let events = calendar.components.filter { $0.name == "VEVENT" }
            #expect(events.count == 3)
            #expect(events.allSatisfy { $0.first("UID")?.value == "inv1@example.org" })
            #expect(events.compactMap { $0.first("RECURRENCE-ID") }.count == 2)
            for event in events {
                let attendees = event.all("ATTENDEE")
                #expect(attendees.map { EventMapping.address($0.value) } == [own])
                #expect(attendees.first?.parameter("PARTSTAT") == "ACCEPTED")
            }
            #expect(await h.serverPartstats() == ["ACCEPTED", "ACCEPTED", "ACCEPTED"])
        }
    }

    @Test func aWithheldAnswerOnACopyScheduledSinceIsSentByTheServerAndSaysSo() async throws {
        try await withReplies { h in
            // A copy the server schedules: an answer kept back there is sent by the server anyway.
            let id = try await h.serverInvitation()
            try h.store.respond(id, .accepted, scope: .event, sendReply: false)
            #expect(try h.event(id).replySentByServer == false)
            // The server schedules the copy before the answer leaves, and says so only when asked.
            await h.caldav.markScheduled(uid: "inv1", in: h.work)
            await h.caldav.answerPutsWithoutScheduleTag()
            try await h.round()
            try await h.round()

            #expect(await h.caldav.serverReplies.map(\.partstat) == ["ACCEPTED"])
            #expect(await h.mail.smtp.received.isEmpty)
            #expect(try h.event(id).replySentByServer)
            #expect(try h.store.scheduleTag(id) != nil)
            #expect(try h.store.pendingEventChanges(h.account.id).isEmpty)
        }
    }

    @Test func aWithheldOccurrenceAnswerTheServerSentIsShownOnThatOccurrenceOnly() async throws {
        try await withReplies { h in
            let id = try await h.serverInvitation(invitation(rule: "FREQ=WEEKLY;COUNT=4"))
            let occurrences = try h.store.occurrences(from: fixedNow, to: fixedNow.addingTimeInterval(40 * 86_400), in: nil)
            let held = try #require(occurrences.dropFirst().first)
            let second = try #require(held.occurrence.recurrenceID)
            try h.store.respond(id, .tentative, scope: .occurrence(second), sendReply: false)
            await h.caldav.markScheduled(uid: "inv1", in: h.work)
            try await h.round()

            func flags() throws -> [Bool] {
                try h.store.occurrences(from: fixedNow, to: fixedNow.addingTimeInterval(40 * 86_400), in: nil)
                    .filter { $0.id == id }.map(\.replySentByServer)
            }
            #expect(try flags() == [false, true, false, false])
            // A newer answer for that occurrence clears it the moment it is given.
            try h.store.respond(id, .accepted, scope: .occurrence(second), sendReply: true)
            #expect(try flags() == [false, false, false, false])
        }
    }

    @Test func answerOverAnUpdateFromMailWritesTheUpdate() async throws {
        try await withReplies { h in
            let id = try await h.serverInvitation()
            let update = invitation(title: "Planning moved", sequence: 1)
            let series = try #require(EventMapping.series(try ICalendarReader.calendar(Data(update.utf8))).first)
            try h.store.applyInvitationChange(
                id, ics: Data(update.utf8), series: series,
                window: CalendarWindow.window(now: fixedNow, zone: stockholm), phoneZone: stockholm)
            try h.store.respond(id, .accepted, scope: .event, sendReply: true)
            try await h.calendarSyncer().runChanges()

            let object = try #require(await h.caldav.events(in: h.work).values.first)
            #expect(object.contains("SUMMARY:Planning moved"))
            #expect(await h.serverPartstats() == ["ACCEPTED"])
            // What the server holds now is the event: the change from mail is no longer kept apart.
            #expect(try h.store.eventObject(id) == Data(object.utf8))
        }
    }

    @Test func theReplyIsWordedAsGiven() async throws {
        let wording = MeetingWording(
            accepted: "Accepterat:", tentative: "Preliminärt:", declined: "Avböjt:", line: "%@ har svarat.",
            invited: "%@ bjuder in.", cancelled: "Inställt:", cancelledLine: "%@ ställer in.")
        try await withReplies(wording: wording) { h in
            let id = try await h.serverInvitation(invitation(agent: "CLIENT"))
            try h.store.respond(id, .accepted, scope: .event, sendReply: true)
            try await h.round()

            let reply = try #require(try await h.sent().first)
            #expect(reply.subject == "Accepterat: Planning")
            #expect(reply.textBody?.contains(h.account.displayName) == true)
        }
    }
}

/// An account whose Drafts folder is missing: the answer still reaches the server, the reply is
/// owed and shown as failed, and the rest of the calendar goes on.
@Suite struct InvitationReplyRecoveryTests {
    @Test func anAnswerWithoutDraftsIsShownFailedAndRetriedOnce() async throws {
        try await withReplies { h in
            // The account's folders not listed yet: no Drafts folder to keep the reply in.
            try h.store.replaceFolders(try h.store.folders(h.account.id).filter { $0.kind != .drafts }, for: h.account.id)
            let first = try await h.serverInvitation(invitation(agent: "CLIENT"))
            let second = try await h.serverInvitation(invitation(uid: "inv2@example.org", title: "Review", agent: "CLIENT"), uid: "inv2")
            try h.store.respond(first, .accepted, scope: .event, sendReply: true)
            try h.store.setOwnReminder(second, minutes: 10, scope: .event)
            try await h.round()

            // The other change reached the server; the answer did too, its reply is owed.
            let review = try #require(await h.caldav.events(in: h.work)["inv2"])
            #expect(review.contains("TRIGGER:-PT10M"))
            #expect(FakeCalDAVServer.ownPartstats(try #require(await h.caldav.events(in: h.work)["inv1"]), own) == ["ACCEPTED"])
            #expect(try h.event(first).changeFailed)
            #expect(try h.store.pendingEventChanges(h.account.id).isEmpty)
            // Another round: no conflict, nothing sent.
            try await h.round()
            #expect(try h.event(first).conflict == nil)
            #expect(await h.mail.smtp.received.isEmpty)
            #expect(throws: StoreError.noSuchFolder) { try h.store.retryEventReply(first) }

            try await h.mailSyncer().syncFolders()
            try h.store.retryEventReply(first)
            #expect(try h.event(first).changeFailed == false)
            try await h.round()
            try await h.round()
            #expect(try await h.sent().map(\.subject) == ["Accepted: Planning"])
            #expect(try h.event(first).changeFailed == false)
        }
    }

    @Test func aNewerAnswerReplacesTheHeldOneAndRetryIsANoOp() async throws {
        try await withReplies { h in
            try h.store.replaceFolders(try h.store.folders(h.account.id).filter { $0.kind != .drafts }, for: h.account.id)
            let id = try await h.serverInvitation(invitation(agent: "CLIENT"))
            try h.store.respond(id, .accepted, scope: .event, sendReply: true)
            try await h.round()
            #expect(try h.event(id).changeFailed)

            try await h.mailSyncer().syncFolders()
            try h.store.respond(id, .tentative, scope: .event, sendReply: true)
            try await h.round()
            #expect(try h.event(id).changeFailed == false)
            try h.store.retryEventReply(id)
            #expect(try h.store.pendingEventChanges(h.account.id).isEmpty)
            try await h.round()

            #expect(try await h.sent().map(\.subject) == ["Tentative: Planning"])
            #expect(await h.serverPartstats() == ["TENTATIVE"])
        }
    }

    @Test func anAnswerWhileDraftsIsMissingReplacesTheHeldOne() async throws {
        try await withReplies { h in
            try h.store.replaceFolders(try h.store.folders(h.account.id).filter { $0.kind != .drafts }, for: h.account.id)
            let id = try await h.serverInvitation(invitation(agent: "CLIENT"))
            try h.store.respond(id, .accepted, scope: .event, sendReply: true)
            try await h.round()
            try h.store.respond(id, .tentative, scope: .event, sendReply: true)
            try await h.round()
            #expect(try h.event(id).changeFailed)

            try await h.mailSyncer().syncFolders()
            try h.store.retryEventReply(id)
            try await h.round()
            try await h.round()

            #expect(try await h.sent().map(\.subject) == ["Tentative: Planning"])
            #expect(await h.serverPartstats() == ["TENTATIVE"])
            #expect(try h.event(id).changeFailed == false)
        }
    }

    @Test func aLostAnswerToTheWriteIsNoConflict() async throws {
        try await withReplies { h in
            let id = try await h.serverInvitation(invitation(agent: "CLIENT"))
            try h.store.respond(id, .accepted, scope: .event, sendReply: true)
            await h.caldav.dropNextPutAnswer()
            try? await h.round()
            #expect(await h.serverPartstats() == ["ACCEPTED"])
            try await h.round()
            try await h.round()

            #expect(try await h.sent().map(\.subject) == ["Accepted: Planning"])
            let event = try h.event(id)
            #expect(event.conflict == nil && !event.changeFailed)
            #expect(try h.store.pendingEventChanges(h.account.id).isEmpty)
        }
    }

    @Test func aLostAnswerOnAScheduledCopyLeavesTheReplyToTheServer() async throws {
        try await withReplies { h in
            let id = try await h.serverInvitation(scheduled: true)
            try h.store.respond(id, .accepted, scope: .event, sendReply: true)
            await h.caldav.dropNextPutAnswer()
            try? await h.round()
            try await h.round()

            #expect(await h.mail.smtp.received.isEmpty)
            #expect(await h.caldav.serverReplies.map(\.partstat) == ["ACCEPTED"])
            #expect(try h.event(id).conflict == nil)
        }
    }
}

@Suite struct ReplyRouteTests {
    @Test func theAppAnswersOnlyForACopyThatLeavesItToTheClient() throws {
        let plain = try ICalendarReader.calendar(Data(invitation().utf8))
        #expect(ReplyRoute.route(plain, serverSchedules: true) == .server)
        #expect(ReplyRoute.route(plain, serverSchedules: false) == .app)
        let client = try ICalendarReader.calendar(Data(invitation(agent: "CLIENT").utf8))
        #expect(ReplyRoute.route(client, serverSchedules: true) == .app)
    }

    @Test func aResponseCanBeKeptBackOnlyWhereTheServerWillNotSendIt() {
        let plain = Data(invitation().utf8)
        let client = Data(invitation(agent: "CLIENT").utf8)
        // The app's create still to go: it can say CLIENT (RFC 6638 › 7.1).
        #expect(ReplyRoute.canWithholdReply(copy: plain, onServer: false, serverSchedules: true))
        // A copy the client answers from.
        #expect(ReplyRoute.canWithholdReply(copy: client, onServer: true, serverSchedules: true))
        // A copy on the server that it schedules, with or without a Schedule-Tag held: never (› 3.2.2.1).
        #expect(!ReplyRoute.canWithholdReply(copy: plain, onServer: true, serverSchedules: true))
        #expect(!ReplyRoute.canWithholdReply(copy: nil, onServer: true, serverSchedules: true))
        #expect(!ReplyRoute.canWithholdReply(copy: Data("not a calendar".utf8), onServer: true, serverSchedules: true))
        // A server that does not schedule sends nothing: the app always can keep its answer back.
        #expect(ReplyRoute.canWithholdReply(copy: plain, onServer: true, serverSchedules: false))
    }
}

@Suite struct InvitationReplyMessageTests {
    @Test func headerValuesOfTheReplyAreStripped() throws {
        // A line break in the title, as an escaped TEXT value carries it.
        let ics = invitation(title: "Plan\\nning")
        let calendar = try ICalendarReader.calendar(Data(ics.utf8))
        let message = try #require(
            InvitationReply.message(
                calendar: calendar, response: .accepted, recurrenceID: nil,
                account: Harness.account(imapPort: 1, smtpPort: 1), wording: .english, now: fixedNow))
        #expect(!message.subject.contains("\r") && !message.subject.contains("\n"))
        #expect(message.subject == "Accepted: Planning")
        #expect(message.to.map(\.email) == [organizer])
        #expect(message.calendar?.method == "REPLY")
    }

    @Test func noReplyWithoutAnOrganizer() throws {
        let ics = invitation().replacingOccurrences(of: "ORGANIZER;CN=Org:mailto:\(organizer)\r\n", with: "")
        let calendar = try ICalendarReader.calendar(Data(ics.utf8))
        #expect(
            InvitationReply.message(
                calendar: calendar, response: .accepted, recurrenceID: nil,
                account: Harness.account(imapPort: 1, smtpPort: 1), wording: .english, now: fixedNow) == nil)
    }
}

// MARK: Never two copies of one meeting

extension InvitationReplyTests {
    @Test func aServerCopyHeldBeforeTheCreateIsTakenInstead() async throws {
        try await withReplies { h in
            let home = await h.caldav.addCalendar("Home")
            try await h.calendarSyncer().sync()
            let id = try await appCopy(h)
            try h.store.respond(id, .accepted, scope: .event, sendReply: true)
            // The server put its own scheduled copy in another calendar before the app's create left.
            await h.caldav.putEvent(invitation(), uid: "server-copy", in: home)
            await h.caldav.markScheduled(uid: "server-copy", in: home)
            try await h.round()
            try await h.round()

            #expect(await h.caldav.events(in: h.work).isEmpty)
            #expect(await h.caldav.requests.filter { $0.method == "PUT" && $0.path.hasPrefix(h.work.path) }.isEmpty)
            #expect(await h.caldav.events(in: home).count == 1)
            let events = try h.events()
            #expect(events.count == 1)
            let event = try #require(events.first)
            #expect(event.origin == .server)
            #expect(try h.store.scheduleTag(event.id) != nil)
            // The owner's answer is on the server's copy, and the server alone answers the organiser.
            #expect(await h.caldav.serverReplies.map(\.partstat) == ["ACCEPTED"])
            #expect(await h.mail.smtp.received.isEmpty)
            #expect(try h.store.pendingEventChanges(h.account.id).isEmpty)
        }
    }

    @Test func aCopyInAReadOnlyCalendarIsNeverTakenForTheAppsOwn() async throws {
        try await withReplies { h in
            let shared = await h.caldav.addCalendar("Shared", readOnly: true)
            try await h.calendarSyncer().sync()
            let id = try await appCopy(h)
            try h.store.respond(id, .accepted, scope: .event, sendReply: true)
            // The organiser's copy of the same meeting, in a calendar shared read-only.
            await h.caldav.putEvent(invitation(), uid: "organiser-copy", in: shared)
            try await h.round()
            try await h.round()

            #expect(await h.caldav.events(in: h.work).count == 1)
            #expect(await h.caldav.events(in: shared).count == 1)
            #expect(await h.serverPartstats() == ["ACCEPTED"])
            #expect(await h.caldav.serverReplies.map(\.partstat) == ["ACCEPTED"])
            #expect(await h.mail.smtp.received.isEmpty)
            #expect(try h.store.pendingEventChanges(h.account.id).isEmpty)
        }
    }

    @Test func aScheduledServerCopyAfterTheAppRepliedReplacesTheAppCopyQuietly() async throws {
        try await withReplies { h in
            let id = try await appCopy(h)
            try h.store.respond(id, .accepted, scope: .event, sendReply: true)
            try await h.round()
            #expect(await h.caldav.serverReplies.map(\.partstat) == ["ACCEPTED"])
            let mine = try #require(await h.caldav.events(in: h.work).keys.first)
            // The server schedules the app's copy too, and adds a copy of its own.
            await h.caldav.markScheduled(uid: mine, in: h.work)
            await h.caldav.putEvent(invitation(), uid: "server-copy", in: h.work)
            await h.caldav.markScheduled(uid: "server-copy", in: h.work)
            try await h.round()
            try await h.round()

            #expect(try h.events().count == 1)
            #expect(Array(await h.caldav.events(in: h.work).keys) == ["server-copy"])
            // The app copy's delete told the server not to answer for it: no DECLINED.
            #expect(await !h.caldav.serverReplies.contains { $0.partstat == "DECLINED" })
            #expect(await h.mail.smtp.received.isEmpty)
            #expect(try h.store.pendingEventChanges(h.account.id).isEmpty)
        }
    }

    @Test func anAnswerOnTheAppCopyGoesToAScheduledServerCopyFoundBeforeTheReply() async throws {
        try await withReplies { h in
            let home = await h.caldav.addCalendar("Home")
            try await h.calendarSyncer().sync()
            let id = try await clientAppCopy(h)
            #expect(await h.caldav.events(in: h.work).count == 1)
            // The server has scheduled a copy of its own since; the owner answers the app's copy.
            await h.caldav.putEvent(invitation(), uid: "server-copy", in: home)
            await h.caldav.markScheduled(uid: "server-copy", in: home)
            try h.store.respond(id, .accepted, scope: .event, sendReply: true)
            try await h.round()
            try await h.round()

            // The server alone answers the organiser, on its own copy; the app mails nothing.
            #expect(await h.mail.smtp.received.isEmpty)
            #expect(try h.mail.rows(.drafts).isEmpty)
            #expect(await h.caldav.serverReplies.map(\.partstat) == ["ACCEPTED"])
            #expect(await h.caldav.events(in: h.work).isEmpty)
            let events = try h.events()
            #expect(events.count == 1)
            let event = try #require(events.first)
            #expect(try h.store.scheduleTag(event.id) != nil)
            #expect(event.ownResponse == .accepted)
            #expect(try h.store.pendingEventChanges(h.account.id).isEmpty)
        }
    }

    @Test func aFreshAnswerGoesOverToAScheduledCopyThatHoldsAnotherOne() async throws {
        try await withReplies { h in
            let home = await h.caldav.addCalendar("Home")
            try await h.calendarSyncer().sync()
            let id = try await clientAppCopy(h)
            let copy = invitation().replacingOccurrences(
                of: "PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:\(own)", with: "PARTSTAT=TENTATIVE:mailto:\(own)")
            await h.caldav.putEvent(copy, uid: "server-copy", in: home)
            await h.caldav.markScheduled(uid: "server-copy", in: home)
            try h.store.respond(id, .declined, scope: .event, sendReply: true)
            try await h.round()
            try await h.round()

            #expect(await h.caldav.serverReplies.map(\.partstat) == ["DECLINED"])
            #expect(await h.mail.smtp.received.isEmpty)
            let object = try #require(await h.caldav.events(in: home)["server-copy"])
            #expect(FakeCalDAVServer.ownPartstats(object, own) == ["DECLINED"])
        }
    }

    @Test func aFailedLookupAfterTheAnswerLandedStillRecordsItAndMailsTheReply() async throws {
        try await withReplies { h in
            let id = try await clientAppCopy(h)
            try h.store.respond(id, .accepted, scope: .event, sendReply: true)
            await h.caldav.refuseNextUIDLookup()
            try await h.round()
            try await h.round()

            #expect(await h.mail.smtp.received.count == 1)
            #expect(await h.serverPartstats() == ["ACCEPTED"])
            let event = try h.event(id)
            #expect(event.conflict == nil && !event.changeFailed)
            #expect(try h.store.pendingEventChanges(h.account.id).isEmpty)
        }
    }

    @Test func aScheduledCopyAfterTheAppRepliedGetsTheAnswerOnlyWhenItSaysOtherwise() async throws {
        for (held, carried) in [("ACCEPTED", false), ("TENTATIVE", true)] {
            try await withReplies { h in
                let id = try await clientAppCopy(h)
                try h.store.respond(id, .accepted, scope: .event, sendReply: true)
                try await h.round()
                #expect(await h.mail.smtp.received.count == 1)
                let copy = invitation().replacingOccurrences(
                    of: "PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:\(own)", with: "PARTSTAT=\(held):mailto:\(own)")
                await h.caldav.putEvent(copy, uid: "server-copy", in: h.work)
                await h.caldav.markScheduled(uid: "server-copy", in: h.work)
                try await h.round()
                try await h.round()

                let object = try #require(await h.caldav.events(in: h.work)["server-copy"])
                #expect(FakeCalDAVServer.ownPartstats(object, own) == [carried ? "ACCEPTED" : held])
                #expect(await h.caldav.serverReplies.map(\.partstat) == (carried ? ["ACCEPTED"] : []))
                #expect(await h.mail.smtp.received.count == 1)
                #expect(try h.events().count == 1)
            }
        }
    }

    @Test func anAppCreateThatLandedIsTheServersCopy() async throws {
        try await withReplies { h in
            let id = try await appCopy(h)
            await h.caldav.dropNextPutAnswer()
            try? await h.calendarSyncer().sync()
            let mine = try #require(await h.caldav.events(in: h.work).keys.first)
            await h.caldav.markScheduled(uid: mine, in: h.work)
            try h.store.respond(id, .accepted, scope: .event, sendReply: true)
            try await h.round()
            try await h.round()

            #expect(try h.events().count == 1)
            #expect(Array(await h.caldav.events(in: h.work).keys) == [mine])
            #expect(await h.caldav.requests.filter { $0.method == "DELETE" }.isEmpty)
            #expect(await h.serverPartstats() == ["ACCEPTED"])
            #expect(await !h.caldav.serverReplies.contains { $0.partstat == "DECLINED" })
            #expect(try h.store.pendingEventChanges(h.account.id).isEmpty)
        }
    }
}
