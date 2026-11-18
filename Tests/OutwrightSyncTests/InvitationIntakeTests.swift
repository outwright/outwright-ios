// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import GRDB
import OutwrightDAV
import OutwrightFakes
import OutwrightMIME
import OutwrightModel
import OutwrightNet
import OutwrightStore
@testable import OutwrightSync
import Testing

private let organizer = "org@example.org"

/// A synthetic iTIP object: one VEVENT `hours` after the tests' clock, an hour long.
private func invite(
    uid: String = "inv1@example.org", method: String = "REQUEST", sequence: Int = 0, hours: Double = 24,
    stamp: String = "20261101T080000Z", title: String = "Planning", from organizerAddress: String = organizer,
    attendees: [String] = ["jk@example.org"], partstat: String = "NEEDS-ACTION", recurrenceID: String? = nil,
    rule: String? = nil, start: String? = nil, end: String? = nil, status: String? = nil
) -> String {
    let at = fixedNow.addingTimeInterval(hours * 3_600)
    var lines = [
        "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Example//EN", "METHOD:\(method)", "BEGIN:VEVENT", "UID:\(uid)",
        "DTSTAMP:\(stamp)", "SEQUENCE:\(sequence)",
        start ?? "DTSTART:\(utcText(at))", end ?? "DTEND:\(utcText(at.addingTimeInterval(3_600)))",
        "SUMMARY:\(title)", "ORGANIZER;CN=Org:mailto:\(organizerAddress)",
    ]
    if let recurrenceID { lines.append(recurrenceID) }
    if let rule { lines.append("RRULE:\(rule)") }
    if let status { lines.append("STATUS:\(status)") }
    lines += attendees.map { "ATTENDEE;PARTSTAT=\(partstat);RSVP=TRUE:mailto:\($0)" }
    lines += ["END:VEVENT", "END:VCALENDAR"]
    return icsText(lines)
}

/// A mail carrying `ics` as its calendar alternative, as iMIP (RFC 6047) sends it.
private func invitationMail(
    _ ics: String, method: String = "REQUEST", from: String = organizer, subject: String = "Invitation: Planning",
    id: String = UUID().uuidString + "@example.org", date: String = "Thu, 05 Nov 2026 10:00:00 +0000"
) -> Data {
    let lines = [
        "From: Org <\(from)>", "To: jk@example.org", "Subject: \(subject)", "Date: \(date)",
        "Message-ID: <\(id)>", "MIME-Version: 1.0", "Content-Type: multipart/alternative; boundary=\"b1\"", "",
        "--b1", "Content-Type: text/plain; charset=utf-8", "", "You are invited.", "",
        "--b1", "Content-Type: text/calendar; charset=utf-8; method=\(method)", "", ics,
        "--b1--", "",
    ]
    return Data(lines.joined(separator: "\r\n").utf8)
}

private struct IntakeHarness {
    let mail: Harness
    let cal: CalendarHarness

    var store: MailStore { mail.store }
    var account: Account { mail.account }

    func syncer() -> AccountSyncer {
        AccountSyncer(account: account, store: store, secrets: mail.secrets, now: { fixedNow }, phoneZone: { stockholm })
    }

    /// Delivers the mail, brings in its folder and fetches its body: the row.
    @discardableResult
    func receive(_ data: Data, in path: String = "INBOX") async throws -> MessageRow {
        await mail.imap.deliver(data, to: path)
        let syncer = syncer()
        try await syncer.syncFolders()
        let folder = try #require(try store.folders(account.id).first { $0.path == path })
        try await syncer.sync(folder.id)
        let index = try store.folderIndex(folder.id)
        let row = try #require(try index.keys.max().flatMap { index[$0] }.flatMap { try store.message($0) })
        try await syncer.fetchBody(row.id)
        return row
    }

    /// The events held, one per event.
    func events() throws -> [CalendarEvent] {
        var seen: Set<EventID> = []
        return try cal.occurrences().filter { seen.insert($0.id).inserted }
    }
}

/// The fake IMAP and CalDAV servers, the account on both, with a calendar "Work" listed in the store.
private func withIntake(
    imap: FakeIMAPServer? = nil, calendars: [(String, Bool)] = [("Work", false)], calDAVOff: Bool = false,
    storePath: URL? = nil, _ body: (IntakeHarness, [URL]) async throws -> Void
) async throws {
    let server: FakeIMAPServer
    if let imap {
        server = imap
    } else {
        server = await standardServer()
    }
    await server.addFolder("Junk", specialUse: "\\Junk")
    await server.addFolder("Archive", specialUse: "\\Archive")
    try await withHarness(server) { mailHarness in
        let caldav = FakeCalDAVServer(user: FakeIMAPServer.user, password: FakeIMAPServer.password)
        let port = try await caldav.start()
        do {
            let store = try storePath.map { try MailStore(path: $0) } ?? mailHarness.store
            var account = mailHarness.account
            account.calDAV = "http://127.0.0.1:\(port)/"
            try store.save(account)
            var urls: [URL] = []
            for (name, readOnly) in calendars {
                urls.append(await caldav.addCalendar(name, readOnly: readOnly))
            }
            let cal = CalendarHarness(
                server: caldav, store: store, secrets: mailHarness.secrets, account: account,
                clock: CalendarClock())
            try await cal.syncer().sync()
            if calDAVOff {
                account.calDAV = nil
                account.calDAVOff = true
                try store.save(account)
            }
            let mail = Harness(
                imap: mailHarness.imap, smtp: mailHarness.smtp, imapPort: mailHarness.imapPort,
                store: store, secrets: mailHarness.secrets, account: account)
            try await body(IntakeHarness(mail: mail, cal: cal), urls)
        } catch {
            await caldav.stop()
            throw error
        }
        await caldav.stop()
    }
}

@Suite struct InvitationIntakeTests {
    @Test func outsideInvitationAppearsTentativeAtOnce() async throws {
        try await withIntake { h, urls in
            let work = try #require(urls.first)
            await h.mail.imap.deliver(invitationMail(invite()), to: "INBOX")
            let coordinator = offlineCoordinator(
                store: h.store, secrets: h.mail.secrets, phoneZone: { stockholm }, actionDelay: .milliseconds(10))
            await coordinator.refreshAll()
            let row = try #require(try h.mail.rows(.inbox).first)
            try await coordinator.fetchBody(row.id)
            // In the calendar at once, striped, before the server has it.
            let events = try h.events()
            #expect(events.count == 1)
            #expect(events.first?.isTentative == true)
            #expect(events.first?.occurrence.details.title == "Planning")
            #expect(try h.store.invitation(for: row.id)?.wasApplied == true)
            // The coordinator sends it to the account's calendar.
            #expect(await eventually { (try? await h.cal.serverSeries(work).map(\.uid)) == ["inv1@example.org"] })
            #expect(try h.events().count == 1)
        }
    }

    @Test func serverCopyAndMailGiveOneEvent() async throws {
        try await withIntake { h, urls in
            let work = try #require(urls.first)
            var held = invite()
            held = held.replacingOccurrences(of: "METHOD:REQUEST\r\n", with: "")
            await h.cal.server.putEvent(held, uid: "inv1@example.org", in: work)
            try await h.cal.syncer().sync()
            try await h.receive(invitationMail(invite()))
            #expect(try h.events().count == 1)
            #expect(try h.store.pendingEventChangeCount(h.account.id) == 0)
            let puts = await h.cal.server.requests.filter { $0.method == "PUT" }
            try await h.cal.syncer().runChanges()
            #expect(await h.cal.server.requests.filter { $0.method == "PUT" }.count == puts.count)
        }
    }

    @Test func sameMailTwiceIsAppliedOnce() async throws {
        try await withIntake { h, _ in
            let first = try await h.receive(invitationMail(invite()))
            let second = try await h.receive(invitationMail(invite()), in: "Archive")
            #expect(try h.events().count == 1)
            let pending = try h.store.pendingEventChanges(h.account.id)
            #expect(pending.count == 1)
            #expect(pending.first?.edits.count == 1)
            #expect(try h.store.invitation(for: first.id)?.wasApplied == true)
            #expect(try h.store.invitation(for: second.id)?.wasApplied == true)
        }
    }

    @Test func updateMovesTheMeeting() async throws {
        try await withIntake { h, _ in
            try await h.receive(invitationMail(invite()))
            try await h.cal.syncer().runChanges()
            try await h.receive(invitationMail(invite(sequence: 1, hours: 48, stamp: "20261102T080000Z")))
            let events = try h.events()
            #expect(events.count == 1)
            #expect(events.first?.occurrence.start == fixedNow.addingTimeInterval(48 * 3_600))
            #expect(events.first?.isTentative == true)
        }
    }

    @Test func anUpdateThatArrivesWithASyncOfTheInboxIsTakenInUnopened() async throws {
        try await withIntake { h, _ in
            try await h.receive(invitationMail(invite()))
            try await h.cal.syncer().runChanges()
            await h.mail.imap.deliver(
                invitationMail(invite(sequence: 1, hours: 48, stamp: "20261102T080000Z")), to: "INBOX")
            let inbox = try #require(try h.store.folders(h.account.id).first { $0.kind == .inbox })
            try await h.syncer().sync(inbox.id)
            let events = try h.events()
            #expect(events.count == 1)
            #expect(events.first?.occurrence.start == fixedNow.addingTimeInterval(48 * 3_600), "the meeting moved")
        }
    }

    // An invitation whose body the server never sends holds back neither the older ones nor the
    // sync: the update behind it still reaches the calendar, and the sync of the Inbox succeeds.
    @Test func anInvitationWhoseBodyNeverComesHoldsBackNeitherTheOthersNorTheSync() async throws {
        try await withIntake { h, _ in
            try await h.receive(invitationMail(invite()))
            try await h.cal.syncer().runChanges()
            await h.mail.imap.deliver(
                invitationMail(invite(sequence: 1, hours: 48, stamp: "20261102T080000Z")), to: "INBOX")
            let broken = await h.mail.imap.deliver(
                invitationMail(invite(sequence: 2, hours: 72, stamp: "20261103T080000Z")), to: "INBOX")
            await h.mail.imap.withholdBody(of: broken, in: "INBOX")
            let inbox = try #require(try h.store.folders(h.account.id).first { $0.kind == .inbox })
            try await h.syncer().sync(inbox.id)
            let events = try h.events()
            #expect(events.first?.occurrence.start == fixedNow.addingTimeInterval(48 * 3_600), "the meeting moved")
        }
    }

    @Test func anUpdateRecordsWhetherTheTimeMoved() async throws {
        try await withIntake { h, _ in
            let first = try await h.receive(invitationMail(invite()))
            try await h.cal.syncer().runChanges()
            let moved = try await h.receive(invitationMail(invite(sequence: 1, hours: 48, stamp: "20261102T080000Z")))
            let renamed = try await h.receive(
                invitationMail(invite(sequence: 2, hours: 48, stamp: "20261103T080000Z", title: "Planning 2")))
            #expect(try h.store.invitation(for: first.id)?.timeMoved == nil)
            #expect(try h.store.invitation(for: moved.id)?.timeMoved == true)
            #expect(try h.store.invitation(for: renamed.id)?.timeMoved == false)
        }
    }

    @Test func anUpdateTheServerAppliedFirstIsStillAnUpdate() async throws {
        try await withIntake { h, urls in
            let work = try #require(urls.first)
            func serverHas(_ text: String) async throws {
                let held = text.replacingOccurrences(of: "METHOD:REQUEST\r\n", with: "")
                await h.cal.server.putEvent(held, uid: "inv1@example.org", in: work)
                try await h.cal.syncer().sync()
            }
            try await serverHas(invite())
            let first = try await h.receive(invitationMail(invite()))
            #expect(try h.store.invitation(for: first.id)?.isUpdate == false)
            // The server put the organiser's second version in the calendar before its mail came.
            try await serverHas(invite(sequence: 1, hours: 48, stamp: "20261102T080000Z"))
            let update = try await h.receive(invitationMail(invite(sequence: 1, hours: 48, stamp: "20261102T080000Z")))
            let state = try #require(try h.store.invitation(for: update.id))
            #expect(state.isUpdate)
            #expect(state.timeMoved == nil)
            #expect(state.title == "Planning")
        }
    }

    @Test func aFirstInvitationAfterTheOrganisersEditsIsNoUpdate() async throws {
        try await withIntake { h, urls in
            let work = try #require(urls.first)
            // Edited twice before it was sent: the server holds it at SEQUENCE 2, the mail says the same.
            let held = invite(sequence: 2).replacingOccurrences(of: "METHOD:REQUEST\r\n", with: "")
            await h.cal.server.putEvent(held, uid: "inv1@example.org", in: work)
            try await h.cal.syncer().sync()
            let first = try await h.receive(invitationMail(invite(sequence: 2)))
            #expect(try h.store.invitation(for: first.id)?.isUpdate == false)
        }
    }

    /// A weekly series held in UTC, half an hour each Tuesday at 08:00Z from November 10.
    private static let weeklyHeld = icsText([
        "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Example//EN", "BEGIN:VEVENT", "UID:w1@example.org",
        "DTSTAMP:20261101T080000Z", "SEQUENCE:0", "DTSTART:20261110T080000Z", "DTEND:20261110T083000Z",
        "RRULE:FREQ=WEEKLY", "SUMMARY:Weekly", "ORGANIZER:mailto:\(organizer)",
        "ATTENDEE;PARTSTAT=ACCEPTED:mailto:jk@example.org", "END:VEVENT", "END:VCALENDAR",
    ])

    /// The organiser's REQUEST for the November 17 occurrence alone, named in UTC, its times in Stockholm.
    private static func occurrence(end: String) -> String {
        icsText([
            "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Example//EN", "METHOD:REQUEST", "BEGIN:VEVENT",
            "UID:w1@example.org", "DTSTAMP:20261105T080000Z", "SEQUENCE:1", "RECURRENCE-ID:20261117T080000Z",
            "DTSTART;TZID=Europe/Stockholm:20261117T090000", "DTEND;TZID=Europe/Stockholm:\(end)",
            "SUMMARY:Weekly", "ORGANIZER:mailto:\(organizer)", "ATTENDEE;PARTSTAT=NEEDS-ACTION:mailto:jk@example.org",
            "END:VEVENT", "END:VCALENDAR",
        ])
    }

    @Test func aNewOccurrenceIsComparedByInstantAndLength() throws {
        let held = try ICalendarReader.calendar(Data(Self.weeklyHeld.utf8))
        func message(_ text: String) throws -> ITIPMessage {
            try #require(ITIP.read(Data(text.utf8), method: "REQUEST"))
        }
        // The same instant written another way, and the series' half hour: not moved.
        #expect(!InvitationIntake.movesTime(try message(Self.occurrence(end: "20261117T093000")), of: held))
        // The same start, an hour long: moved.
        #expect(InvitationIntake.movesTime(try message(Self.occurrence(end: "20261117T100000")), of: held))
    }

    @Test func olderUpdateIsIgnored() async throws {
        try await withIntake { h, _ in
            try await h.receive(invitationMail(invite()))
            // On the server; an older update after a newer one changes nothing.
            try await h.cal.syncer().runChanges()
            try await h.receive(invitationMail(invite(sequence: 2, hours: 48, stamp: "20261103T080000Z")))
            try await h.receive(invitationMail(invite(sequence: 1, hours: 72, stamp: "20261102T080000Z")))
            let events = try h.events()
            #expect(events.count == 1)
            #expect(events.first?.occurrence.start == fixedNow.addingTimeInterval(48 * 3_600))
        }
    }

    @Test func cancelMarksCancelled() async throws {
        try await withIntake { h, _ in
            try await h.receive(invitationMail(invite()))
            let cancel = try await h.receive(
                invitationMail(invite(method: "CANCEL", sequence: 1, status: "CANCELLED"), method: "CANCEL"))
            let events = try h.events()
            #expect(events.count == 1)
            #expect(events.first?.isCancelled == true)
            #expect(try h.store.invitation(for: cancel.id)?.wasApplied == true)
        }
    }

    @Test func cancelFromOtherSenderChangesNothing() async throws {
        try await withIntake { h, _ in
            try await h.receive(invitationMail(invite()))
            let cancel = try await h.receive(
                invitationMail(
                    invite(method: "CANCEL", sequence: 1, status: "CANCELLED"), method: "CANCEL",
                    from: "eve@example.org"))
            let events = try h.events()
            #expect(events.count == 1)
            #expect(events.first?.isCancelled == false)
            #expect(try h.store.invitation(for: cancel.id)?.wasApplied == false)
        }
    }

    @Test func junkInvitationIsNotAdded() async throws {
        try await withIntake { h, _ in
            let row = try await h.receive(invitationMail(invite()), in: "Junk")
            #expect(try h.events().isEmpty)
            #expect(try h.store.pendingEventChangeCount(h.account.id) == 0)
            #expect(try h.store.invitation(for: row.id)?.wasApplied == false)
        }
    }

    /// Not junk: the owner moves it to the Inbox, and the meeting goes in the calendar with the move.
    @Test func junkInvitationMovedOutIsAdded() async throws {
        try await withIntake { h, urls in
            let work = try #require(urls.first)
            let coordinator = offlineCoordinator(
                store: h.store, secrets: h.mail.secrets, phoneZone: { stockholm }, actionDelay: .milliseconds(10))
            let row = try await h.receive(invitationMail(invite()), in: "Junk")
            await coordinator.refreshAll()
            #expect(try h.events().isEmpty)
            try h.store.apply(.move(row.id, to: .inbox))
            #expect(await eventually { (try? h.store.invitation(for: row.id)?.wasApplied) == true })
            #expect(try h.events().count == 1)
            #expect(await eventually { (try? await h.cal.serverSeries(work).map(\.uid)) == ["inv1@example.org"] })
        }
    }

    /// The meeting was called off while its invitation sat in Junk: Not junk does not bring it back.
    @Test func junkInvitationMovedOutAfterItsCancellationStaysOut() async throws {
        try await withIntake { h, urls in
            let work = try #require(urls.first)
            let coordinator = offlineCoordinator(
                store: h.store, secrets: h.mail.secrets, phoneZone: { stockholm }, actionDelay: .milliseconds(10))
            let row = try await h.receive(invitationMail(invite()), in: "Junk")
            let cancel = invite(method: "CANCEL", sequence: 1, stamp: "20261102T080000Z", status: "CANCELLED")
            try await h.receive(invitationMail(cancel, method: "CANCEL", date: "Fri, 06 Nov 2026 10:00:00 +0000"))
            await coordinator.refreshAll()
            try h.store.apply(.move(row.id, to: .inbox))
            #expect(await eventually { (try? h.store.isInvitationRecorded(row.id)) == true })
            try await h.cal.syncer().runChanges()
            #expect(try h.events().isEmpty)
            #expect(try h.store.invitation(for: row.id)?.wasApplied == false)
            #expect(try await h.cal.serverSeries(work).isEmpty)
        }
    }

    @Test func forwardedInvitationWithoutOwnAttendeeIsNotAdded() async throws {
        try await withIntake { h, _ in
            let row = try await h.receive(invitationMail(invite(attendees: ["bo@example.org"])))
            #expect(try h.events().isEmpty)
            #expect(try h.store.invitation(for: row.id)?.wasApplied == false)
        }
    }

    @Test func occurrenceInvitationAddsOneOccurrence() async throws {
        try await withIntake { h, _ in
            let start = fixedNow.addingTimeInterval(7 * 86_400)
            let occurrence = invite(
                uid: "weekly@example.org", recurrenceID: "RECURRENCE-ID:\(utcText(start))",
                start: "DTSTART:\(utcText(start))", end: "DTEND:\(utcText(start.addingTimeInterval(3_600)))")
            try await h.receive(invitationMail(occurrence))
            let held = try h.cal.occurrences()
            #expect(held.count == 1)
            #expect(held.first?.occurrence.start == start)
        }
    }

    @Test func invitationGoesToThisAccountsCalendar() async throws {
        try await withIntake(calendars: [("Archive", true), ("Work", false)]) { h, _ in
            var other = Account(
                id: AccountID(), displayName: "Other", email: "other@example.org", colorIndex: 1,
                imap: h.account.imap, smtp: h.account.smtp, user: "other@example.org", signature: "", sortOrder: 1)
            other.calDAV = "http://127.0.0.1:1/"
            try h.store.save(other)
            try h.store.replaceCalendars(
                [(href: "/other/home/", name: "Home", color: nil, isReadOnly: false)], for: other.id)
            let home = try #require(try h.store.calendars(other.id).first)
            try h.store.setDefaultCalendar(home.id)
            try await h.receive(invitationMail(invite()))
            let event = try #require(try h.events().first)
            let work = try h.cal.calendar(named: "Work")
            #expect(event.calendarID == work.id)
        }
    }

    @Test func replyIsRecordedOnly() async throws {
        try await withIntake { h, _ in
            let reply = invite(
                method: "REPLY", from: "jk@example.org", attendees: ["bo@example.org"], partstat: "ACCEPTED")
            let row = try await h.receive(invitationMail(reply, method: "REPLY", from: "bo@example.org"))
            #expect(try h.events().isEmpty)
            #expect(try h.store.pendingEventChangeCount(h.account.id) == 0)
            let state = try #require(try h.store.invitation(for: row.id))
            #expect(state.method == .reply)
            #expect(state.reply?.email == "bo@example.org")
            #expect(state.reply?.response == .accepted)
        }
    }

    @Test func replyFromSomeoneElseNamesNoOne() async throws {
        try await withIntake { h, _ in
            let reply = invite(
                method: "REPLY", from: "jk@example.org", attendees: ["bo@example.org"], partstat: "ACCEPTED")
            let row = try await h.receive(invitationMail(reply, method: "REPLY", from: "eve@example.org"))
            #expect(try h.store.invitation(for: row.id)?.reply == nil)
        }
    }

    @Test func recurrenceIdInTzidAndUtcFormMatch() async throws {
        try await withIntake { h, _ in
            // A weekly series from Tuesday 10 November, 10:00 in Stockholm (09:00 UTC), with the second
            // occurrence moved; then an update of that occurrence naming it in UTC.
            let series = invite(
                uid: "zoned@example.org", start: "DTSTART;TZID=Europe/Stockholm:20261110T100000",
                end: "DTEND;TZID=Europe/Stockholm:20261110T110000"
            ).replacingOccurrences(of: "END:VEVENT\r\nEND:VCALENDAR", with: "RRULE:FREQ=WEEKLY;COUNT=4\r\nEND:VEVENT")
                + icsText([
                    "BEGIN:VEVENT", "UID:zoned@example.org", "DTSTAMP:20261101T080000Z", "SEQUENCE:0",
                    "RECURRENCE-ID;TZID=Europe/Stockholm:20261117T100000",
                    "DTSTART;TZID=Europe/Stockholm:20261117T120000", "DTEND;TZID=Europe/Stockholm:20261117T130000",
                    "SUMMARY:Planning (moved)", "ORGANIZER;CN=Org:mailto:\(organizer)",
                    "ATTENDEE;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:jk@example.org", "END:VEVENT", "END:VCALENDAR",
                ])
            try await h.receive(invitationMail(series))
            let update = invite(
                uid: "zoned@example.org", sequence: 1, stamp: "20261102T080000Z", title: "Planning (moved again)",
                recurrenceID: "RECURRENCE-ID:20261117T090000Z", start: "DTSTART:20261117T140000Z",
                end: "DTEND:20261117T150000Z")
            try await h.receive(invitationMail(update))
            let event = try #require(try h.events().first)
            let held = try #require(try h.store.series(event.id))
            #expect(held.overrides.count == 1)
            #expect(held.overrides.first?.details.title == "Planning (moved again)")
            #expect(try h.cal.occurrences().count == 4)
        }
    }

    @Test func storedObjectOfAnotherUidIsLeftAlone() async throws {
        try await withIntake { h, _ in
            let work = try h.cal.calendar(named: "Work")
            let theirs = Data(invite(uid: "other@example.org", title: "Theirs").utf8)
            let mine = try ICalendarReader.calendar(Data(invite(title: "Held").utf8))
            let series = try #require(EventMapping.series(mine).first)
            try h.store.upsertRemote(
                href: "/calendars/c1/x.ics", etag: "1", ics: theirs, series: series, in: work.id,
                window: CalendarWindow.window(now: fixedNow, zone: stockholm), phoneZone: stockholm, scheduleTag: nil)
            try await h.receive(invitationMail(invite(sequence: 1, stamp: "20261102T080000Z", title: "Changed")))
            #expect(try h.events().map(\.occurrence.details.title) == ["Held"])
        }
    }

    @Test func accountWithCalendarsOffRecordsOnly() async throws {
        try await withIntake(calDAVOff: true) { h, _ in
            let row = try await h.receive(invitationMail(invite()))
            #expect(try h.events().isEmpty)
            #expect(try h.store.pendingEventChangeCount(h.account.id) == 0)
            #expect(try h.store.isInvitationRecorded(row.id))
            #expect(try h.store.invitation(for: row.id)?.wasApplied == false)
        }
    }

    // MARK: Fix round 1

    @Test func failedIntakeKeepsTheBatchAndIsTakenLater() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("store.sqlite")
        try await withIntake(storePath: path) { h, _ in
            // The store refuses the invitation's event once.
            let side = try DatabaseQueue(path: path.path)
            try await side.write { database in
                try database.execute(sql: """
                    CREATE TRIGGER refuse BEFORE INSERT ON event WHEN NEW.uid = 'inv1@example.org'
                    BEGIN SELECT RAISE(ABORT, 'refused'); END
                    """)
            }
            await h.mail.imap.deliver(invitationMail(invite()), to: "INBOX")
            await h.mail.imap.deliver(mail("plain", date: daysAgo(3)), to: "INBOX")
            let syncer = h.syncer()
            try await syncer.syncFolders()
            try await syncer.sync(try h.mail.folder(.inbox).id)
            try await syncer.prefetchInbox(limit: 100)
            let rows = try h.mail.rows(.inbox)
            #expect(rows.count == 2)
            #expect(try rows.allSatisfy { try h.store.message($0.id)?.hasBody == true })
            let invitation = try #require(rows.first { $0.subject.hasPrefix("Invitation") })
            #expect(try h.store.isInvitationRecorded(invitation.id) == false)
            #expect(try h.events().isEmpty)

            try await side.write { try $0.execute(sql: "DROP TRIGGER refuse") }
            try await syncer.prefetchInbox(limit: 100)
            #expect(try h.events().count == 1)
            #expect(try h.store.invitation(for: invitation.id)?.wasApplied == true)
        }
    }

    @Test func secondChangeFromMailBuildsOnTheFirst() async throws {
        try await withIntake { h, urls in
            let work = try #require(urls.first)
            let series = invite(rule: "FREQ=WEEKLY;COUNT=4").replacingOccurrences(of: "METHOD:REQUEST\r\n", with: "")
            await h.cal.server.putEvent(series, uid: "inv1@example.org", in: work)
            try await h.cal.syncer().sync()
            let second = fixedNow.addingTimeInterval(8 * 86_400)
            let third = fixedNow.addingTimeInterval(15 * 86_400)
            let cancel = invite(
                method: "CANCEL", sequence: 1, recurrenceID: "RECURRENCE-ID:\(utcText(second))",
                start: "DTSTART:\(utcText(second))", end: "DTEND:\(utcText(second.addingTimeInterval(3_600)))",
                status: "CANCELLED")
            let moved = invite(
                sequence: 1, title: "Planning (moved)", recurrenceID: "RECURRENCE-ID:\(utcText(third))",
                start: "DTSTART:\(utcText(third.addingTimeInterval(7_200)))",
                end: "DTEND:\(utcText(third.addingTimeInterval(10_800)))")
            // One batch, fetched newest first: the cancellation, then the moved occurrence.
            await h.mail.imap.deliver(
                invitationMail(cancel, method: "CANCEL", date: "Thu, 05 Nov 2026 10:00:00 +0000"), to: "INBOX")
            await h.mail.imap.deliver(invitationMail(moved, date: "Thu, 05 Nov 2026 09:00:00 +0000"), to: "INBOX")
            let syncer = h.syncer()
            try await syncer.syncFolders()
            try await syncer.sync(try h.mail.folder(.inbox).id)
            try await syncer.prefetchInbox(limit: 100)
            let held = try h.cal.occurrences()
            // A cancelled occurrence is held as such and not shown (L3's expansion drops it).
            #expect(held.count == 3)
            #expect(!held.contains { $0.occurrence.start == second })
            let event = try #require(held.first)
            let kept = try #require(try h.store.series(event.id))
            let cancelled = kept.overrides.filter { $0.details.status == .cancelled }.map(\.recurrenceID)
            #expect(cancelled == [EventTime.utc(second)])
            #expect(held.first { $0.occurrence.details.title == "Planning (moved)" }?.occurrence.start
                == third.addingTimeInterval(7_200))
        }
    }

    @Test func eventBeyondTheWindowGetsTheUpdate() async throws {
        try await withIntake { h, _ in
            try await h.receive(invitationMail(invite(hours: 3 * 365 * 24)))
            #expect(try h.events().isEmpty)
            let update = try await h.receive(invitationMail(invite(sequence: 1, stamp: "20261102T080000Z")))
            let events = try h.events()
            #expect(events.count == 1)
            #expect(events.first?.occurrence.start == fixedNow.addingTimeInterval(24 * 3_600))
            #expect(try h.store.invitation(for: update.id)?.wasApplied == true)
            #expect(try h.store.pendingEventChanges(h.account.id).count == 1)
        }
    }

    @Test func newRequestFromSpoofedSenderIsNotAdded() async throws {
        try await withIntake { h, _ in
            let row = try await h.receive(invitationMail(invite(), from: "eve@example.org"))
            #expect(try h.events().isEmpty)
            #expect(try h.store.pendingEventChangeCount(h.account.id) == 0)
            #expect(try h.store.invitation(for: row.id)?.wasApplied == false)
        }
    }

    @Test func oversizedCalendarPartAddsNothing() async throws {
        try await withIntake { h, _ in
            let big = invite().replacingOccurrences(
                of: "SUMMARY:Planning", with: "SUMMARY:Planning\r\nDESCRIPTION:" + String(repeating: "a", count: 600_000))
            let row = try await h.receive(invitationMail(big))
            #expect(try h.store.message(row.id)?.hasBody == true)
            #expect(try h.events().isEmpty)
            #expect(try h.store.pendingEventChangeCount(h.account.id) == 0)
            #expect(try h.store.isInvitationRecorded(row.id) == false)
        }
    }

    // MARK: Fix round 2

    @Test func invitationWaitsForTheCalendarList() async throws {
        try await withIntake(calendars: []) { h, _ in
            let row = try await h.receive(invitationMail(invite()))
            #expect(try h.events().isEmpty)
            #expect(try h.store.isInvitationRecorded(row.id) == false)
            #expect(try h.store.invitation(for: row.id)?.wasApplied == false)
            _ = await h.cal.server.addCalendar("Work")
            let coordinator = offlineCoordinator(
                store: h.store, secrets: h.mail.secrets, phoneZone: { stockholm }, actionDelay: .seconds(60))
            await coordinator.refreshCalendars(of: h.account.id)
            #expect(try h.events().count == 1)
            #expect(try h.store.invitation(for: row.id)?.wasApplied == true)
            await coordinator.refreshCalendars(of: h.account.id)
            #expect(try h.events().count == 1)
        }
    }

    @Test func headerResyncKeepsTheInvitationFlag() async throws {
        try await withIntake(calendars: []) { h, _ in
            let row = try await h.receive(invitationMail(invite()))
            #expect(try h.store.message(row.id)?.isInvitation == true)
            var headers = try #require(try h.store.message(row.id))
            headers.isInvitation = false
            _ = try h.store.upsert([headers])
            #expect(try h.store.message(row.id)?.isInvitation == true)
            #expect(try h.store.invitationsAwaitingIntake(h.account.id, limit: 10) == [row.id])
            _ = await h.cal.server.addCalendar("Work")
            let coordinator = offlineCoordinator(
                store: h.store, secrets: h.mail.secrets, phoneZone: { stockholm }, actionDelay: .seconds(60))
            await coordinator.refreshCalendars(of: h.account.id)
            #expect(try h.events().count == 1)
        }
    }

    // MARK: Fix round 3

    @Test func unreadableInvitationsDoNotCrowdOutAWaitingOne() async throws {
        try await withIntake(calendars: []) { h, _ in
            let real = try await h.receive(invitationMail(invite(), date: "Mon, 02 Nov 2026 10:00:00 +0000"))
            for number in 0..<150 {
                await h.mail.imap.deliver(invitationMail("not a calendar \(number)\r\n"), to: "INBOX")
            }
            let syncer = h.syncer()
            try await syncer.sync(try h.mail.folder(.inbox).id)
            try await syncer.prefetchInbox(limit: 200)
            let rows = try h.mail.rows(.inbox)
            #expect(rows.count == 151)
            #expect(try h.store.invitationsAwaitingIntake(h.account.id, limit: 100) == [real.id])
            _ = await h.cal.server.addCalendar("Work")
            let coordinator = offlineCoordinator(
                store: h.store, secrets: h.mail.secrets, phoneZone: { stockholm }, actionDelay: .seconds(60))
            await coordinator.refreshCalendars(of: h.account.id)
            #expect(try h.events().count == 1)
            let unreadable = rows.filter { $0.id != real.id }
            #expect(try unreadable.allSatisfy { try h.store.isInvitationRecorded($0.id) })
            #expect(try unreadable.allSatisfy { try h.store.invitation(for: $0.id) == nil })
        }
    }

    @Test func cancelInTheSameBatchAsItsInvitationWins() async throws {
        try await withIntake { h, _ in
            let cancel = invite(method: "CANCEL", sequence: 1, status: "CANCELLED")
            await h.mail.imap.deliver(invitationMail(invite(), date: "Thu, 05 Nov 2026 09:00:00 +0000"), to: "INBOX")
            await h.mail.imap.deliver(
                invitationMail(cancel, method: "CANCEL", date: "Thu, 05 Nov 2026 10:00:00 +0000"), to: "INBOX")
            let syncer = h.syncer()
            try await syncer.syncFolders()
            try await syncer.sync(try h.mail.folder(.inbox).id)
            try await syncer.prefetchInbox(limit: 100)
            let rows = try h.mail.rows(.inbox)
            #expect(rows.count == 2)
            #expect(try rows.allSatisfy { try h.store.isInvitationRecorded($0.id) })
            #expect(try h.events().allSatisfy(\.isCancelled))
        }
    }
}

// MARK: Final review fixes

extension InvitationIntakeTests {
    /// A co-attendee who knows the UID sends a change with herself as ORGANIZER and From.
    private func spoofed(_ h: IntakeHarness, _ ics: String, method: String) async throws -> MessageRow {
        try await h.receive(invitationMail(ics, method: method, from: "eve@example.org"))
    }

    /// The owner accepts; the copy the server answers from still names the organiser the calendar
    /// held, so the server's one reply goes there.
    private func answerGoesToTheRealOrganiser(_ h: IntakeHarness, _ calendars: [URL]) async throws {
        let event = try #require(try h.events().first)
        try h.store.respond(event.id, .accepted, scope: .event, sendReply: true)
        try await h.cal.syncer().sync()
        try await h.syncer().runActions()
        #expect(await h.mail.smtp.received.isEmpty)
        #expect(await h.cal.server.serverReplies.map(\.partstat) == ["ACCEPTED"])
        let calendar = try #require(calendars.first)
        let object = try #require(await h.cal.server.events(in: calendar).values.first)
        let organizers = object.components(separatedBy: "\r\n").filter { $0.hasPrefix("ORGANIZER") }
        #expect(!organizers.isEmpty && organizers.allSatisfy { $0.hasSuffix(":mailto:\(organizer)") })
    }

    @Test func cancelWithSpoofedOrganiserChangesNothing() async throws {
        try await withIntake { h, calendars in
            try await h.receive(invitationMail(invite(attendees: ["jk@example.org", "eve@example.org"])))
            try await h.cal.syncer().runChanges()
            let cancel = invite(
                method: "CANCEL", sequence: 1, stamp: "20261102T080000Z", from: "eve@example.org",
                attendees: ["jk@example.org", "eve@example.org"], status: "CANCELLED")
            let row = try await spoofed(h, cancel, method: "CANCEL")
            let event = try #require(try h.events().first)
            #expect(event.isCancelled == false)
            #expect(try h.store.series(event.id).flatMap(InvitationIntake.lead)?.organizer == organizer)
            #expect(try h.store.invitation(for: row.id)?.wasApplied == false)
            try await answerGoesToTheRealOrganiser(h, calendars)
        }
    }

    @Test func requestWithSpoofedOrganiserChangesNothing() async throws {
        try await withIntake { h, calendars in
            try await h.receive(invitationMail(invite(attendees: ["jk@example.org", "eve@example.org"])))
            try await h.cal.syncer().runChanges()
            let request = invite(
                sequence: 1, hours: 48, stamp: "20261102T080000Z", title: "Hijacked", from: "eve@example.org",
                attendees: ["jk@example.org", "eve@example.org"])
            let row = try await spoofed(h, request, method: "REQUEST")
            let event = try #require(try h.events().first)
            #expect(event.occurrence.details.title == "Planning")
            #expect(event.occurrence.start == fixedNow.addingTimeInterval(24 * 3_600))
            #expect(try h.store.series(event.id).flatMap(InvitationIntake.lead)?.organizer == organizer)
            #expect(try h.store.invitation(for: row.id)?.wasApplied == false)
            try await answerGoesToTheRealOrganiser(h, calendars)
        }
    }

    @Test func aSpoofedRequestNeverMakesALaterOneAnUpdate() async throws {
        try await withIntake { h, _ in
            // A REQUEST in the organiser's name from someone else, never applied; then the organiser's own.
            _ = try await spoofed(h, invite(), method: "REQUEST")
            let first = try await h.receive(invitationMail(invite(sequence: 1)))
            #expect(try h.store.invitation(for: first.id)?.wasApplied == true)
            #expect(try h.store.invitation(for: first.id)?.isUpdate == false)
        }
    }
}

// MARK: The organiser's changes from mail reach the server copy (RFC 6638 › 3.2.2.2)

extension InvitationIntakeTests {
    /// The invitation as the server holds it, synced in.
    private func serverHolds(_ h: IntakeHarness, _ work: URL, _ text: String = invite()) async throws {
        let held = text.replacingOccurrences(of: "METHOD:REQUEST\r\n", with: "")
        await h.cal.server.putEvent(held, uid: "inv1@example.org", in: work)
        try await h.cal.syncer().sync()
    }

    private func serverCopy(_ h: IntakeHarness, _ work: URL) async throws -> String {
        try #require(await h.cal.server.events(in: work)["inv1@example.org"])
    }

    private static let moved = "DTSTART:\(utcText(fixedNow.addingTimeInterval(48 * 3_600)))"
    private static let kept = "DTSTART:\(utcText(fixedNow.addingTimeInterval(24 * 3_600)))"

    @Test func anOrganisersUpdateByMailIsWrittenToTheServerCopy() async throws {
        try await withIntake { h, urls in
            let work = try #require(urls.first)
            try await serverHolds(h, work)
            try await h.receive(invitationMail(invite(sequence: 1, hours: 48, stamp: "20261102T080000Z")))
            try await h.cal.syncer().runChanges()
            let copy = try await serverCopy(h, work)
            #expect(copy.contains(Self.moved))
            #expect(copy.contains("SEQUENCE:1"))
            let event = try #require(try h.events().first)
            #expect(try h.store.eventObject(event.id).map { String(decoding: $0, as: UTF8.self) } == copy)
            #expect(try h.store.pendingEventChangeCount(h.account.id) == 0)
        }
    }

    @Test func anOrganisersCancellationByMailIsWrittenToTheServerCopy() async throws {
        try await withIntake { h, urls in
            let work = try #require(urls.first)
            try await serverHolds(h, work)
            try await h.receive(
                invitationMail(invite(method: "CANCEL", sequence: 1, status: "CANCELLED"), method: "CANCEL"))
            try await h.cal.syncer().runChanges()
            #expect(try await serverCopy(h, work).contains("STATUS:CANCELLED"))
            #expect(try h.events().first?.isCancelled == true)
        }
    }

    @Test func anUpdateTheServerAppliedItselfIsNotWrittenAgain() async throws {
        try await withIntake { h, urls in
            let work = try #require(urls.first)
            try await serverHolds(h, work)
            try await h.receive(invitationMail(invite(sequence: 1, hours: 48, stamp: "20261102T080000Z")))
            // The organiser is on the same server: it applied the update itself (RFC 6638 › 4.1).
            let applied = invite(sequence: 1, hours: 48, stamp: "20261102T080000Z")
                .replacingOccurrences(of: "METHOD:REQUEST\r\n", with: "")
            await h.cal.server.putEvent(applied, uid: "inv1@example.org", in: work)
            let puts = await h.cal.server.requests.filter { $0.method == "PUT" }.count
            try await h.cal.syncer().runChanges()
            #expect(await h.cal.server.requests.filter { $0.method == "PUT" }.count == puts + 1)
            try await h.cal.syncer().sync()
            #expect(try await serverCopy(h, work) == applied)
            #expect(try h.store.pendingEventChangeCount(h.account.id) == 0)
            #expect(try h.events().first?.conflict == nil)
            #expect(try h.events().first?.occurrence.start == fixedNow.addingTimeInterval(48 * 3_600))
        }
    }

    @Test func anUpdateAndAQueuedAnswerGoAsOnePut() async throws {
        try await withIntake { h, urls in
            let work = try #require(urls.first)
            try await serverHolds(h, work)
            let event = try #require(try h.events().first)
            try h.store.respond(event.id, .accepted, scope: .event, sendReply: true)
            try await h.receive(invitationMail(invite(sequence: 1, hours: 48, stamp: "20261102T080000Z")))
            let puts = await h.cal.server.requests.filter { $0.method == "PUT" }.count
            try await h.cal.syncer().runChanges()
            #expect(await h.cal.server.requests.filter { $0.method == "PUT" }.count == puts + 1)
            let copy = try await serverCopy(h, work)
            #expect(copy.contains(Self.moved))
            #expect(FakeCalDAVServer.ownPartstats(copy, FakeIMAPServer.user) == ["ACCEPTED"])
        }
    }

    @Test func aRefusedUpdateStaysOnThePhoneAndTheAnswerStillReachesTheServer() async throws {
        try await withIntake { h, urls in
            let work = try #require(urls.first)
            try await serverHolds(h, work)
            await h.cal.server.refuseAttendeeChanges()
            try await h.receive(invitationMail(invite(sequence: 1, hours: 48, stamp: "20261102T080000Z")))
            try await h.cal.syncer().runChanges()
            #expect(try h.store.pendingEventChangeCount(h.account.id) == 0)
            #expect(try h.events().first?.conflict == nil)
            let event = try #require(try h.events().first)
            #expect(event.occurrence.start == fixedNow.addingTimeInterval(48 * 3_600))
            #expect(event.changeFailed == false)
            try h.store.respond(event.id, .accepted, scope: .event, sendReply: true)
            try await h.cal.syncer().runChanges()
            let copy = try await serverCopy(h, work)
            #expect(copy.contains(Self.kept))
            #expect(FakeCalDAVServer.ownPartstats(copy, FakeIMAPServer.user) == ["ACCEPTED"])
            try await h.cal.syncer().sync()
            let shown = try #require(try h.events().first)
            #expect(shown.occurrence.start == fixedNow.addingTimeInterval(48 * 3_600))
            #expect(shown.changeFailed == false)
        }
    }

    @Test func anAnswerGivenElsewhereSinceIsKeptUnderTheUpdate() async throws {
        try await withIntake { h, urls in
            let work = try #require(urls.first)
            try await serverHolds(h, work)
            try await h.receive(
                invitationMail(invite(sequence: 1, stamp: "20261102T080000Z", title: "Planning (agenda)")))
            // Accepted on another device before the phone wrote the update.
            await h.cal.server.putEvent(
                invite(partstat: "ACCEPTED").replacingOccurrences(of: "METHOD:REQUEST\r\n", with: ""),
                uid: "inv1@example.org", in: work)
            try await h.cal.syncer().runChanges()
            let copy = try await serverCopy(h, work)
            #expect(copy.contains("SUMMARY:Planning (agenda)"))
            #expect(FakeCalDAVServer.ownPartstats(copy, FakeIMAPServer.user) == ["ACCEPTED"])
            #expect(await h.cal.server.serverReplies.isEmpty)
        }
    }

    @Test func theAppsCopyStaysTheClientsToAnswerFromAfterAnUpdate() async throws {
        try await withIntake { h, urls in
            let work = try #require(urls.first)
            let client = invite().replacingOccurrences(of: "ORGANIZER;CN=Org:", with: "ORGANIZER;CN=Org;SCHEDULE-AGENT=CLIENT:")
            try await serverHolds(h, work, client)
            try await h.receive(invitationMail(invite(sequence: 1, hours: 48, stamp: "20261102T080000Z")))
            try await h.cal.syncer().runChanges()
            let copy = try await serverCopy(h, work)
            #expect(copy.contains(Self.moved))
            #expect(copy.contains("SCHEDULE-AGENT=CLIENT"))
        }
    }

    @Test func anUpdateInAReadOnlyCalendarIsShownAndNotWritten() async throws {
        try await withIntake(calendars: [("Shared", true)]) { h, urls in
            let shared = try #require(urls.first)
            try await serverHolds(h, shared)
            try await h.receive(invitationMail(invite(sequence: 1, hours: 48, stamp: "20261102T080000Z")))
            #expect(try h.store.pendingEventChangeCount(h.account.id) == 0)
            let event = try #require(try h.events().first)
            #expect(event.occurrence.start == fixedNow.addingTimeInterval(48 * 3_600))
            #expect(event.changeFailed == false)
        }
    }

    @Test func anUpdateRefusedForGoodStaysShownAndIsNotFailed() async throws {
        try await withIntake { h, urls in
            let work = try #require(urls.first)
            try await serverHolds(h, work)
            try await h.receive(invitationMail(invite(sequence: 1, hours: 48, stamp: "20261102T080000Z")))
            // Shared read-only since the calendar was listed: the write is refused with a plain 403.
            await h.cal.server.makeReadOnly(work)
            try await h.cal.syncer().runChanges()
            #expect(try h.store.pendingEventChangeCount(h.account.id) == 0)
            let event = try #require(try h.events().first)
            #expect(event.changeFailed == false)
            #expect(event.conflict == nil)
            #expect(event.occurrence.start == fixedNow.addingTimeInterval(48 * 3_600))
            #expect(try await serverCopy(h, work).contains(Self.kept))
        }
    }
}
