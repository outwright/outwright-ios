// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightModel
@testable import OutwrightStore
import OutwrightSync
import Testing

@testable import OutwrightUI

@MainActor @Suite struct EventDetailsModelTests {
    private func details(_ fixture: CalendarFixture, _ id: EventID) -> EventDetailsModel {
        EventDetailsModel(
            app: fixture.app, request: EventRequest(event: id, occurrence: nil), calendar: phoneCalendar())
    }

    private func zoned(_ fixture: CalendarFixture, _ title: String, zone: String) throws -> EventID {
        var wall = DateComponents(year: 2026, month: 11, day: 10, hour: 9, minute: 0, second: 0)
        let start = EventTime.zoned(wall, zone: zone)
        wall.hour = 10
        return try fixture.add(EventDetails(title: title, start: start, end: .zoned(wall, zone: zone)))
    }

    @Test func zoneNoteOnlyWhenZoneDiffers() throws {
        let fixture = try CalendarFixture()
        let newYork = details(fixture, try zoned(fixture, "Call", zone: "America/New_York"))
        #expect(newYork.event != nil)
        #expect(newYork.zoneNote != nil)
        #expect(details(fixture, try zoned(fixture, "Here", zone: "Europe/Stockholm")).zoneNote == nil)
        // Another zone with the phone's offset at the event's time says nothing either.
        #expect(details(fixture, try zoned(fixture, "Berlin", zone: "W. Europe Standard Time")).zoneNote == nil)
        #expect(details(fixture, try fixture.timed("UTC", day: 10, 9)).zoneNote == nil)
    }

    @Test func invitedEventIsNotEditable() throws {
        let fixture = try CalendarFixture()
        let start = fixture.at(day: 10, 9)
        let invited = try fixture.add(
            EventDetails(
                title: "Invited", start: .utc(start), end: .utc(start.addingTimeInterval(3_600)),
                attendees: [Attendee(email: "anna@example.org", response: .accepted)],
                organizer: "johan.berg@example.org"))
        #expect(details(fixture, invited).canEdit == false)
        let own = try fixture.add(
            EventDetails(
                title: "Own", start: .utc(start), end: .utc(start.addingTimeInterval(3_600)),
                attendees: [Attendee(email: "johan.berg@example.org")], organizer: "ANNA@example.org"))
        #expect(details(fixture, own).canEdit == true)
    }

    @Test func attendeesShowResponses() throws {
        let fixture = try CalendarFixture()
        let start = fixture.at(day: 10, 9)
        let id = try fixture.add(
            EventDetails(
                title: "Planning", start: .utc(start), end: .utc(start.addingTimeInterval(3_600)),
                attendees: [
                    Attendee(email: "anna@example.org", name: "Anna", response: .accepted),
                    Attendee(email: "maja.ek@example.org", name: "Maja Ek", response: .declined),
                    Attendee(email: "johan.berg@example.org", response: .tentative),
                    Attendee(email: "nils@example.org")
                ], organizer: "anna@example.org"))
        let model = details(fixture, id)
        #expect(model.organizer == "Anna")
        #expect(model.attendees.map(\.email) == ["maja.ek@example.org", "johan.berg@example.org", "nils@example.org"])
        #expect(model.attendees.map(\.response) == [.declined, .tentative, .needsAction])
    }

    @Test func linksComeFromPlaceAndNotes() throws {
        let fixture = try CalendarFixture()
        let start = fixture.at(day: 10, 9)
        let id = try fixture.add(
            EventDetails(
                title: "Video", place: "Room 4, https://meet.example.org/abc",
                notes: "Join at https://meet.example.org/abc or https://backup.example.org/x. javascript:alert(1)",
                start: .utc(start), end: .utc(start.addingTimeInterval(3_600))))
        #expect(details(fixture, id).links.map(\.absoluteString) == [
            "https://meet.example.org/abc", "https://backup.example.org/x"
        ])
    }

    @Test func notificationOpensItsEvent() throws {
        let occurrence = EventTime.date(year: 2026, month: 11, day: 10)
        let text = try #require(String(bytes: try JSONEncoder().encode(occurrence), encoding: .utf8))
        let request = try #require(EventRequest(userInfo: ["event": Int64(42), "occurrence": text]))
        #expect(request.event == EventID(raw: 42))
        #expect(request.occurrence == occurrence)
        #expect(EventRequest(userInfo: ["event": Int64(7)])?.occurrence == nil)
        #expect(EventRequest(userInfo: ["event": "seven"]) == nil)
        #expect(EventRequest(userInfo: ["s": "subscription"]) == nil)
        #expect(EventRequest(userInfo: ["event": Int64(7), "occurrence": "not json"])?.occurrence == nil)
    }

    @Test func followsTheStore() async throws {
        let fixture = try CalendarFixture()
        let start = fixture.at(day: 10, 9)
        let id = try fixture.add(
            EventDetails(title: "Planning", start: .utc(start), end: .utc(start.addingTimeInterval(3_600))), uid: "p")
        let model = details(fixture, id)
        let watching = Task { await model.observe() }
        defer { watching.cancel() }
        let cal = try fixture.calendar("Work")
        try fixture.store.upsertRemote(
            href: "/cal/p.ics", etag: "2", ics: Data(),
            series: EventSeries(
                uid: "p",
                base: EventDetails(title: "Moved", start: .utc(start), end: .utc(start.addingTimeInterval(7_200)))),
            in: cal.id, window: CalendarWindow.window(now: calendarNow, zone: stockholm),
            phoneZone: stockholm, scheduleTag: nil)
        #expect(await soon { model.details?.title == "Moved" }, "a sync's change shows in the open sheet")
        try fixture.store.removeRemote(hrefs: ["/cal/p.ics"], in: cal.id)
        #expect(await soon { model.event == nil }, "an event the server dropped is gone from the sheet")
    }

    @Test func aStoreThatCannotBeWatchedSaysSo() async throws {
        let fixture = try CalendarFixture()
        let id = try fixture.timed("Planning", day: 10, 9)
        let model = details(fixture, id)
        struct Broken: Error {}
        await model.watch(AsyncThrowingStream { $0.finish(throwing: Broken()) })
        #expect(model.failed)
        let other = details(fixture, id)
        await other.watch(AsyncThrowingStream { $0.finish(throwing: CancellationError()) })
        #expect(!other.failed, "a sheet that closes is no failure")
    }

    @Test func aReadErrorIsNotAMissingEvent() throws {
        let fixture = try CalendarFixture()
        let id = try fixture.timed("Planning", day: 10, 9)
        let model = details(fixture, id)
        try fixture.store.write { try $0.execute(sql: "ALTER TABLE occurrence RENAME TO occurrence_away") }
        model.reload()
        #expect(model.failed, "a store that can't be read shows the banner")
        #expect(model.event != nil, "and the event stays as it was")
        try fixture.store.write { try $0.execute(sql: "ALTER TABLE occurrence_away RENAME TO occurrence") }
        model.reload()
        #expect(!model.failed)

        let missing = details(fixture, EventID(raw: 999_999))
        #expect(missing.event == nil, "an event that is not there is not found")
        #expect(!missing.failed)
    }

    @Test func deletingOneOccurrenceLeavesTheRest() throws {
        let fixture = try CalendarFixture()
        let start = fixture.at(day: 10, 9)
        let id = try fixture.add(
            EventDetails(title: "Stand-up", start: .utc(start), end: .utc(start.addingTimeInterval(1_800))),
            rule: RecurrenceRule(freq: .daily))
        let eleventh = try #require(
            try fixture.store.occurrences(from: fixture.at(day: 11, 0), to: fixture.at(day: 12, 0), in: nil).first)
        let model = EventDetailsModel(app: fixture.app, request: EventRequest(eleventh), calendar: phoneCalendar())
        #expect(model.isSeries)
        try model.delete(scope: try #require(model.occurrenceScope))
        #expect(model.event == nil)
        #expect(try fixture.store.occurrences(from: fixture.at(day: 11, 0), to: fixture.at(day: 12, 0), in: nil).isEmpty)
        #expect(try fixture.store.occurrences(from: fixture.at(day: 12, 0), to: fixture.at(day: 13, 0), in: nil)
            .map(\.id) == [id])

        let whole = details(fixture, id)
        try whole.delete(scope: .event)
        #expect(try fixture.store.occurrences(from: fixture.at(day: 10, 0), to: fixture.at(day: 20, 0), in: nil).isEmpty)
    }

    @Test func aConflictCanBeAppliedAgainOrDiscarded() throws {
        let fixture = try CalendarFixture()
        let start = fixture.at(day: 10, 9)
        let base = EventDetails(title: "Planning", start: .utc(start), end: .utc(start.addingTimeInterval(3_600)))
        let id = try fixture.add(base, uid: "p")
        func conflict() throws {
            var mine = base
            mine.title = "Mine"
            try fixture.store.updateEvent(id, mine, rule: nil, scope: .event)
            var theirs = base
            theirs.title = "Theirs"
            try fixture.store.eventChangeConflicted(
                id, server: (etag: "2", ics: Data(), series: EventSeries(uid: "p", base: theirs)))
        }
        try conflict()
        let model = details(fixture, id)
        #expect(model.conflict != nil)
        #expect(model.details?.title == "Theirs")
        try model.applyAgain()
        #expect(model.conflict == nil)
        #expect(model.details?.title == "Mine")

        try conflict()
        model.reload()
        #expect(model.conflict != nil)
        try model.discard()
        #expect(model.conflict == nil)
        #expect(model.details?.title == "Theirs")
    }

    @Test func aConflictCountsEveryChangeItHolds() throws {
        let fixture = try CalendarFixture()
        let start = fixture.at(day: 10, 9)
        let base = EventDetails(title: "Planning", start: .utc(start), end: .utc(start.addingTimeInterval(3_600)))
        let id = try fixture.add(base, uid: "p")
        var first = base
        first.title = "First"
        try fixture.store.updateEvent(id, first, rule: nil, scope: .event)
        var second = first
        second.place = "Room 2"
        try fixture.store.updateEvent(id, second, rule: nil, scope: .event)
        try fixture.store.eventChangeConflicted(
            id, server: (etag: "2", ics: Data(), series: EventSeries(uid: "p", base: base)))
        let model = details(fixture, id)
        #expect(model.conflict != nil)
        #expect(model.conflictChanges == 2)
        try model.applyAgain()
        #expect(model.conflictChanges == 0)
        #expect(model.details?.title == "First" && model.details?.place == "Room 2")
    }

    @Test func aRefusedChangeCanBeDiscarded() throws {
        let fixture = try CalendarFixture()
        let cal = try fixture.calendar("Work")
        let ics = """
            BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//example.org//test//EN\r\nBEGIN:VEVENT\r\nUID:p\r\n\
            DTSTAMP:20261101T000000Z\r\nDTSTART:20261110T080000Z\r\nDTEND:20261110T090000Z\r\n\
            SUMMARY:Planning\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n
            """
        let start = fixture.at(day: 10, 9)
        let base = EventDetails(title: "Planning", start: .utc(start), end: .utc(start.addingTimeInterval(3_600)))
        try fixture.store.upsertRemote(
            href: "/cal/p.ics", etag: "1", ics: Data(ics.utf8), series: EventSeries(uid: "p", base: base),
            in: cal.id, window: CalendarWindow.window(now: calendarNow, zone: stockholm),
            phoneZone: stockholm, scheduleTag: nil)
        let id = try #require(try fixture.store.occurrences(from: start, to: start.addingTimeInterval(3_600), in: nil)
            .first?.id)
        var mine = base
        mine.title = "Mine"
        try fixture.store.updateEvent(id, mine, rule: nil, scope: .event)
        let anna = try #require(fixture.box.accounts.first)
        let sent = try #require(try fixture.store.pendingEventChanges(anna.id).first)
        try fixture.store.eventChangeFailed(id, revision: sent.revision)
        let model = details(fixture, id)
        #expect(model.changeFailed)
        #expect(model.details?.title == "Mine")
        try model.discardFailedChange()
        #expect(!model.changeFailed)
        #expect(model.details?.title == "Planning")
    }

    /// An invitation from Maja to Anna on November 10, 09:00, as the server holds it.
    private func invitation(
        _ fixture: CalendarFixture, status: EventStatus = .confirmed, uid: String = "inv"
    ) throws -> EventID {
        let start = fixture.at(day: 10, 9)
        return try fixture.add(
            EventDetails(
                title: "Invited", start: .utc(start), end: .utc(start.addingTimeInterval(3_600)), reminder: 15,
                attendees: [
                    Attendee(email: "maja.ek@example.org", response: .accepted),
                    Attendee(email: "anna@example.org", response: .needsAction)
                ],
                organizer: "maja.ek@example.org", status: status),
            uid: uid)
    }

    private func pending(_ fixture: CalendarFixture, _ id: EventID) throws -> [EventEdit] {
        let anna = try #require(fixture.box.accounts.first)
        return try fixture.store.pendingEventChanges(anna.id).first { $0.event == id }?.edits ?? []
    }

    @Test func invitationShowsRsvpAndEditableReminder() throws {
        let fixture = try CalendarFixture()
        let id = try invitation(fixture)
        let model = details(fixture, id)
        #expect(!model.canEdit)
        #expect(model.isInvitation)
        #expect(model.canAnswer)
        #expect(model.response == .needsAction)
        // A copy on the server that it schedules: the server answers, the choice is not offered.
        #expect(!model.canWithholdReply)
        try model.answer(.tentative, sendReply: true, scope: .event)
        #expect(model.response == .tentative)
        #expect(model.canEditReminder)
        try model.setReminder(60, scope: .event)
        #expect(model.details?.reminder == 60)
        #expect(try pending(fixture, id) == [
            .respond(.tentative, scope: .event, sendReply: true), .ownReminder(60, scope: .event)
        ])
        // An own event has no answer to give.
        let own = details(fixture, try fixture.timed("Own", day: 11, 9))
        #expect(!own.isInvitation)
        #expect(!own.canAnswer)
        #expect(!own.canEditReminder)
    }

    @Test func deleteOnInvitationDeclines() throws {
        let fixture = try CalendarFixture()
        let id = try invitation(fixture)
        let model = details(fixture, id)
        #expect(model.canDecline)
        try model.declineByDeleting(scope: .event)
        #expect(try pending(fixture, id) == [.respond(.declined, scope: .event, sendReply: true)])
        #expect(try fixture.store.occurrences(from: fixture.at(day: 10, 0), to: fixture.at(day: 11, 0), in: nil)
            .isEmpty)
    }

    @Test func cancelledEventOffersRemove() throws {
        let fixture = try CalendarFixture()
        let id = try invitation(fixture, status: .cancelled)
        let model = details(fixture, id)
        #expect(model.canRemoveCancelled)
        #expect(!model.canAnswer)
        try model.removeFromCalendar()
        #expect(model.event == nil)
        #expect(try pending(fixture, id) == [.delete(scope: .event)])
        #expect(!details(fixture, try invitation(fixture, uid: "inv2")).canRemoveCancelled)
    }

    @Test func aFailedReplyIsRetriedFromTheDetails() throws {
        let fixture = try CalendarFixture()
        let id = try invitation(fixture)
        let anna = try #require(fixture.box.accounts.first)
        let model = details(fixture, id)
        try model.answer(.accepted, sendReply: true, scope: .event)
        let folders = try fixture.store.folders(anna.id).filter { $0.kind != .drafts }
        try fixture.store.replaceFolders(folders, for: anna.id)
        let queued = try #require(try fixture.store.pendingEventChanges(anna.id).first { $0.event == id })
        try fixture.store.respondDone(
            id, revision: queued.revision, href: "/cal/inv.ics", etag: "2", ics: Data(),
            series: try #require(try fixture.store.series(id)),
            reply: (replyRow(anna), try message(subject: "Accepted: Invited", text: "Anna has replied.")),
            scheduleTag: nil)
        model.reload()
        #expect(model.replyFailed)
        #expect(throws: InvitationError.noDraftsFolder) { try model.retryReply() }
        try fixture.store.replaceFolders(folders + [drafts(anna)], for: anna.id)
        try model.retryReply()
        #expect(!model.replyFailed)
    }
}

/// Waits up to five seconds for `condition`, letting other work run.
@MainActor
func soon(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<500 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}
