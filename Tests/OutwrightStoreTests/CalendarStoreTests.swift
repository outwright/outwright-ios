// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import GRDB
import OutwrightModel
import Testing

@testable import OutwrightStore

private let utcZone = TimeZone(identifier: "UTC") ?? .gmt
private let stockholm = TimeZone(identifier: "Europe/Stockholm") ?? .gmt

private func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = utcZone
    return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))
        ?? .distantPast
}

private let window = utc(2026, 12, 1)...utc(2027, 2, 1)

private func meeting(
    _ title: String = "Meeting", day: Int = 10, hour: Int = 9, organizer: String? = nil,
    attendees: [Attendee] = [], status: EventStatus = .confirmed
) -> EventDetails {
    EventDetails(
        title: title, start: .utc(utc(2026, 12, day, hour)), end: .utc(utc(2026, 12, day, hour + 1)),
        attendees: attendees, organizer: organizer, status: status)
}

private let weekly = RecurrenceRule(freq: .weekly, count: 4)

private func expectReadOnly(_ body: () throws -> Void) {
    do {
        try body()
        Issue.record("expected the edit to be refused")
    } catch {
        guard case .readOnly? = error as? StoreError else { Issue.record("wrong error \(error)"); return }
    }
}

private struct CalFixture {
    let base: Fixture
    let cal: CalendarInfo
    var store: MailStore { base.store }
    var account: AccountID { base.account.id }

    init(readOnly: Bool = false) throws {
        base = try Fixture()
        var account = base.account
        account.calDAV = "https://dav.example.org/"
        try base.store.save(account)
        try base.store.replaceCalendars(
            [(href: "/cal/work/", name: "Work", color: nil, isReadOnly: readOnly)], for: base.account.id)
        cal = try #require(try base.store.calendars(base.account.id).first)
    }

    @discardableResult
    func remote(
        _ href: String, _ series: EventSeries, etag: String = "e1",
        zone: TimeZone = utcZone
    ) throws -> Bool {
        try store.upsertRemote(
            href: href, etag: etag, ics: Data("BEGIN:VCALENDAR".utf8), series: series,
            in: cal.id, window: window, phoneZone: zone, scheduleTag: nil)
    }

    func all() throws -> [CalendarEvent] {
        try store.occurrences(from: window.lowerBound, to: window.upperBound, in: nil)
    }

    func theEvent() throws -> CalendarEvent {
        try #require(try all().first)
    }

    /// The stored occurrence rows of an event: start instants, ascending.
    func starts(_ id: EventID) throws -> [Date] {
        try store.queue.read { database in
            try Double.fetchAll(
                database, sql: "SELECT startUTC FROM occurrence WHERE eventId = ? ORDER BY startUTC",
                arguments: [id.raw]
            ).map { Date(timeIntervalSince1970: $0) }
        }
    }
}

@Suite struct CalendarStoreTests {
    @Test func migrationFromV5KeepsAccountsAndContacts() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("v5-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let id = UUID().uuidString
        do {
            let old = try DatabaseQueue(path: url.path)
            try Schema.migrator().migrate(old, upTo: "v5")
            try old.write { database in
                try database.execute(
                    sql: """
                        INSERT INTO account (id, displayName, email, colorIndex, imapHost, imapPort,
                            imapSecurity, smtpHost, smtpPort, smtpSecurity, user, signature, sortOrder)
                        VALUES (?, 'Anna', 'anna@example.org', 0, 'm.example.org', 993, 'tls',
                            'm.example.org', 465, 'tls', 'anna', '', 0);
                        INSERT INTO address_book (id, accountId, href, name, isReadOnly)
                        VALUES (1, '\(id)', '/b/', 'Contacts', 0);
                        INSERT INTO contact (accountId, addressBookId, detailsJSON, sortKey)
                        VALUES ('\(id)', 1, '{}', 'x');
                        """, arguments: [id])
            }
        }
        let store = try MailStore(path: url)
        let account = try #require(try store.accounts().first)
        #expect(account.calDAV == nil)
        #expect(!account.calDAVOff)
        #expect(try store.contacts(in: nil, matching: nil).count == 1)
    }

    @Test func accountKeepsCalDAVFieldsAcrossSave() throws {
        let f = try Fixture()
        var account = f.account
        account.calDAV = "https://dav.example.org/"
        account.calDAVUnconfirmed = "https://other.example.net/"
        account.calDAVOff = true
        try f.store.save(account)
        let read = try #require(try f.store.accounts().first)
        #expect(read.calDAV == "https://dav.example.org/")
        #expect(read.calDAVUnconfirmed == "https://other.example.net/")
        #expect(read.calDAVOff)
    }

    @Test func paletteColourIsStable() throws {
        let account = Fixture.makeAccount(name: "Anna", email: "anna@example.org", order: 0)
        var colours: [Int] = []
        for _ in 0..<2 {
            let store = try MailStore(path: nil)
            var saved = account
            saved.calDAV = "https://dav.example.org/"
            try store.save(saved)
            try store.replaceCalendars([(href: "/c/", name: "C", color: nil, isReadOnly: false)], for: account.id)
            colours.append(try #require(try store.calendars(account.id).first).color)
        }
        #expect(colours[0] == colours[1])
        #expect(colours[0] == CalendarPalette.color(account: account.id, href: "/c/"))
        #expect((0...0xFFFFFF).contains(colours[0]))
    }

    @Test func upsertExpandsOccurrencesInTheWindow() throws {
        let f = try CalFixture()
        #expect(try f.remote("/cal/work/a.ics", EventSeries(uid: "u1", base: meeting(), rule: weekly)))
        let found = try f.all()
        #expect(found.count == 4)
        #expect(found.allSatisfy { $0.isSeries && $0.calendarID == f.cal.id })
        #expect(Set(found.map(\.id)).count == 1)
        #expect(try f.store.remoteETags(f.cal.id) == ["/cal/work/a.ics": "e1"])
    }

    @Test func resourceOutsideTheWindowIsNotKept() throws {
        let f = try CalFixture()
        try f.remote("/cal/work/a.ics", EventSeries(uid: "u1", base: meeting(), rule: weekly))
        let old = EventDetails(
            title: "Old", start: .utc(utc(2020, 1, 1, 9)), end: .utc(utc(2020, 1, 1, 10)))
        try f.remote("/cal/work/a.ics", EventSeries(uid: "u1", base: old), etag: "e2")
        #expect(try f.all().isEmpty)
        #expect(try f.store.remoteETags(f.cal.id).isEmpty)
    }

    @Test func occurrencesByRangeIncludeAllDayDays() throws {
        let f = try CalFixture()
        let day = { (d: Int) in EventTime.date(year: 2026, month: 12, day: d) }
        let on24 = EventDetails(title: "Eve", start: day(24), end: day(25))
        let on25 = EventDetails(title: "Day", start: day(25), end: day(26))
        let both = EventDetails(title: "Two", start: day(24), end: day(26))
        try f.remote("/cal/work/a.ics", EventSeries(uid: "a", base: on24), zone: stockholm)
        try f.remote("/cal/work/b.ics", EventSeries(uid: "b", base: on25), zone: stockholm)
        try f.remote("/cal/work/c.ics", EventSeries(uid: "c", base: both), zone: stockholm)
        func titles(_ from: Int, _ to: Int) throws -> [String] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = stockholm
            let start = calendar.date(from: DateComponents(year: 2026, month: 12, day: from)) ?? .distantPast
            let end = calendar.date(from: DateComponents(year: 2026, month: 12, day: to)) ?? .distantPast
            return try f.store.occurrences(from: start, to: end, in: nil).map(\.occurrence.details.title)
        }
        #expect(try titles(25, 26).sorted() == ["Day", "Two"])
        #expect(try titles(24, 25).sorted() == ["Eve", "Two"])
        #expect(try titles(26, 27).isEmpty)
    }

    @Test func allDayComesFirstThenByStart() throws {
        let f = try CalFixture()
        let allDay = EventDetails(
            title: "All", start: .date(year: 2026, month: 12, day: 10), end: .date(year: 2026, month: 12, day: 11))
        try f.remote("/cal/work/a.ics", EventSeries(uid: "a", base: meeting("Late", hour: 15)))
        try f.remote("/cal/work/b.ics", EventSeries(uid: "b", base: meeting("Early", hour: 8)))
        try f.remote("/cal/work/c.ics", EventSeries(uid: "c", base: allDay))
        #expect(try f.all().map(\.occurrence.details.title) == ["All", "Early", "Late"])
    }

    @Test func ownerEditIsQueuedAndShownAtOnce() async throws {
        let f = try CalFixture()
        var queued = f.store.queuedActions().makeAsyncIterator()
        let id = try f.store.createEvent(meeting("Lunch"), rule: nil, in: f.cal.id)
        #expect(await queued.next() == f.account)
        let shown = try #require(try f.all().first)
        #expect(shown.id == id && shown.isEditable && shown.occurrence.details.title == "Lunch")
        let pending = try f.store.pendingEventChanges(f.account)
        #expect(pending.count == 1)
        guard case .create? = pending.first?.edits.first else { Issue.record("not a create"); return }
        try f.store.updateEvent(id, meeting("Late lunch"), rule: nil, scope: .event)
        let after = try f.store.pendingEventChanges(f.account)
        #expect(after.count == 1 && after.first?.edits.count == 2)
        guard case .create? = after.first?.edits.first, case .update? = after.first?.edits.last else {
            Issue.record("create then update stay in order")
            return
        }
        #expect(try f.all().first?.occurrence.details.title == "Late lunch")
    }

    @Test func seriesTimeChangeDropsOverrides() throws {
        let f = try CalFixture()
        let moved = meeting("Moved", day: 17, hour: 11)
        let series = EventSeries(
            uid: "u1", base: meeting(), rule: weekly,
            overrides: [EventOverride(recurrenceID: .utc(utc(2026, 12, 17, 9)), details: moved)])
        try f.remote("/cal/work/a.ics", series)
        let id = try #require(try f.all().first).id
        try f.store.updateEvent(id, meeting(hour: 10), rule: weekly, scope: .event)
        #expect(try f.store.series(id)?.overrides.isEmpty == true)
    }

    @Test func seriesTitleChangeKeepsOverrides() throws {
        let f = try CalFixture()
        let moved = meeting("Moved", day: 17, hour: 11)
        let series = EventSeries(
            uid: "u1", base: meeting(), rule: weekly,
            overrides: [EventOverride(recurrenceID: .utc(utc(2026, 12, 17, 9)), details: moved)])
        try f.remote("/cal/work/a.ics", series)
        let id = try #require(try f.all().first).id
        try f.store.updateEvent(id, meeting("Renamed"), rule: weekly, scope: .event)
        #expect(try f.store.series(id)?.overrides.count == 1)
        let titles = try f.all().map(\.occurrence.details.title)
        #expect(titles.contains("Moved") && titles.contains("Renamed"))
    }

    @Test func occurrenceUpdateAddsAnOverride() throws {
        let f = try CalFixture()
        try f.remote("/cal/work/a.ics", EventSeries(uid: "u1", base: meeting(), rule: weekly))
        let id = try #require(try f.all().first).id
        let second = EventTime.utc(utc(2026, 12, 17, 9))
        try f.store.updateEvent(id, meeting("Special", day: 17), rule: weekly, scope: .occurrence(second))
        #expect(try f.store.series(id)?.overrides.count == 1)
        #expect(try f.all().map(\.occurrence.details.title).filter { $0 == "Special" }.count == 1)
        #expect(try f.all().count == 4)
        guard case .update(_, _, .occurrence)? = try f.store.pendingEventChanges(f.account).first?.edits.last else {
            Issue.record("not an occurrence update")
            return
        }
    }

    @Test func occurrenceDeleteAddsExdate() throws {
        let f = try CalFixture()
        try f.remote("/cal/work/a.ics", EventSeries(uid: "u1", base: meeting(), rule: weekly))
        let id = try #require(try f.all().first).id
        let second = EventTime.utc(utc(2026, 12, 17, 9))
        try f.store.deleteEvent(id, scope: .occurrence(second))
        #expect(try f.store.series(id)?.exdates == [second])
        #expect(try f.all().count == 3)
        guard case .delete(.occurrence)? = try f.store.pendingEventChanges(f.account).first?.edits.last else {
            Issue.record("not an occurrence delete")
            return
        }
    }

    @Test func deletingTheEventHidesItAndQueuesDelete() throws {
        let f = try CalFixture()
        try f.remote("/cal/work/a.ics", EventSeries(uid: "u1", base: meeting()))
        let id = try #require(try f.all().first).id
        try f.store.deleteEvent(id, scope: .event)
        #expect(try f.all().isEmpty)
        let pending = try f.store.pendingEventChanges(f.account)
        #expect(pending.first?.edits == [.delete(scope: .event)])
        #expect(pending.first?.href == "/cal/work/a.ics")
        try f.store.eventChangeDone(
            id, revision: try #require(pending.first?.revision), href: "/cal/work/a.ics", etag: nil,
            ics: Data(), series: EventSeries(uid: "u1", base: meeting()), scheduleTag: nil)
        #expect(try f.store.series(id) == nil)
    }

    @Test func createThenDeleteStaysQueuedAsDelete() throws {
        let f = try CalFixture()
        let id = try f.store.createEvent(meeting(), rule: nil, in: f.cal.id)
        try f.store.deleteEvent(id, scope: .event)
        let pending = try #require(try f.store.pendingEventChanges(f.account).first)
        #expect(pending.edits == [.delete(scope: .event)] && pending.href == nil)
        #expect(try f.all().isEmpty)
        #expect(try f.store.pendingEventChangeCount(f.account) == 1)
        do {
            try f.store.setEventCreateTarget(id, href: "/cal/work/x.ics", ics: Data())
            Issue.record("a deleted create must not get a target")
        } catch {
            guard case .noSuchEvent = error else { Issue.record("wrong error"); return }
        }
        #expect(try f.store.eventCreateTarget(id) == nil)
    }

    @Test func createOccurrenceUpdateOccurrenceDeleteKeepsThreeEdits() throws {
        let f = try CalFixture()
        let id = try f.store.createEvent(meeting(), rule: weekly, in: f.cal.id)
        let second = EventTime.utc(utc(2026, 12, 17, 9))
        let third = EventTime.utc(utc(2026, 12, 24, 9))
        let special = meeting("Special", day: 17)
        try f.store.updateEvent(id, special, rule: weekly, scope: .occurrence(second))
        try f.store.deleteEvent(id, scope: .occurrence(third))
        let edits = try #require(try f.store.pendingEventChanges(f.account).first).edits
        #expect(edits.count == 3)
        guard case .create(let first, _) = edits[0] else { Issue.record("first is the create"); return }
        #expect(first == meeting())
        #expect(edits[1] == .update(special, rule: weekly, scope: .occurrence(second)))
        #expect(edits[2] == .delete(scope: .occurrence(third)))
        let series = try #require(try f.store.series(id))
        #expect(series.overrides.count == 1 && series.exdates == [third])
    }

    @Test func seriesUpdateThenOccurrenceUpdateKeepsTwoEdits() throws {
        let f = try CalFixture()
        try f.remote("/cal/work/a.ics", EventSeries(uid: "u1", base: meeting(), rule: weekly))
        let id = try #require(try f.all().first).id
        try f.store.updateEvent(id, meeting("Renamed"), rule: weekly, scope: .event)
        let second = EventTime.utc(utc(2026, 12, 17, 9))
        try f.store.updateEvent(id, meeting("One", day: 17), rule: weekly, scope: .occurrence(second))
        let edits = try #require(try f.store.pendingEventChanges(f.account).first).edits
        #expect(edits.count == 2)
        guard case .update(_, _, .event) = edits[0], case .update(_, _, .occurrence) = edits[1] else {
            Issue.record("order lost")
            return
        }
    }

    @Test func movingTheSeriesDropsExdatesAndLaysOutEveryRow() throws {
        let f = try CalFixture()
        let series = EventSeries(
            uid: "u1", base: meeting(), rule: weekly, exdates: [.utc(utc(2026, 12, 17, 9))])
        try f.remote("/cal/work/a.ics", series)
        let id = try #require(try f.all().first).id
        #expect(try f.starts(id).count == 3)
        try f.store.updateEvent(id, meeting(hour: 10), rule: weekly, scope: .event)
        #expect(try f.store.series(id)?.exdates.isEmpty == true)
        #expect(try f.starts(id) == [10, 17, 24, 31].map { utc(2026, 12, $0, 10) })
    }

    @Test func overrideWithForeignOrganizerKeepsTheSeriesEditable() throws {
        let f = try CalFixture()
        let foreign = meeting("Theirs", day: 17, organizer: "boss@example.org")
        let series = EventSeries(
            uid: "u1", base: meeting(organizer: "anna@example.org"), rule: weekly,
            overrides: [EventOverride(recurrenceID: .utc(utc(2026, 12, 17, 9)), details: foreign)])
        try f.remote("/cal/work/a.ics", series)
        let shown = try f.all()
        #expect(shown.count == 4 && shown.allSatisfy(\.isEditable))
        try f.store.updateEvent(shown[0].id, meeting("All", organizer: "anna@example.org"), rule: weekly, scope: .event)
    }

    @Test func overridesOnlySeriesUsesTheFirstOverrideForOwnership() throws {
        let f = try CalFixture()
        let mine = meeting("Mine", organizer: "anna@example.org")
        let series = EventSeries(
            uid: "u1", base: nil, overrides: [EventOverride(recurrenceID: .utc(utc(2026, 12, 10, 9)), details: mine)])
        try f.remote("/cal/work/a.ics", series)
        #expect(try f.theEvent().isEditable)
    }

    @Test func applyAgainRefusesWhenTheServerVersionIsNotOurs() throws {
        let f = try CalFixture()
        try f.remote("/cal/work/a.ics", EventSeries(uid: "u1", base: meeting()))
        let id = try #require(try f.all().first).id
        try f.store.updateEvent(id, meeting("Mine"), rule: nil, scope: .event)
        let theirs = EventSeries(uid: "u1", base: meeting("Theirs", organizer: "boss@example.org"))
        try f.store.eventChangeConflicted(
            id, server: (etag: "e9", ics: Data(), series: theirs))
        expectReadOnly { try f.store.applyEventConflictAgain(id) }
        #expect(try f.store.pendingEventChanges(f.account).isEmpty)
        #expect(try f.theEvent().conflict != nil)
    }

    @Test func heldConflictSurvivesTheServerMovingTheEventOut() throws {
        let f = try CalFixture()
        try f.remote("/cal/work/a.ics", EventSeries(uid: "u1", base: meeting()))
        let id = try #require(try f.all().first).id
        try f.store.updateEvent(id, meeting("Mine"), rule: nil, scope: .event)
        try f.store.eventChangeConflicted(
            id, server: (etag: "e9", ics: Data(), series: EventSeries(uid: "u1", base: meeting("Theirs"))))
        let old = EventDetails(title: "Old", start: .utc(utc(2020, 1, 1, 9)), end: .utc(utc(2020, 1, 1, 10)))
        #expect(try f.remote("/cal/work/a.ics", EventSeries(uid: "u1", base: old), etag: "e10") == false)
        #expect(try f.theEvent().conflict != nil)
    }

    @Test func unreadableWindowFallsBackToTheDefault() throws {
        let f = try CalFixture()
        try f.store.queue.write { database in
            try database.execute(sql: "INSERT OR REPLACE INTO calendar_meta (key, value) VALUES ('windowFrom', 'nan')")
            try database.execute(sql: "INSERT OR REPLACE INTO calendar_meta (key, value) VALUES ('windowTo', 'inf')")
        }
        let soon = Date().addingTimeInterval(10 * 86_400)
        let details = EventDetails(title: "Soon", start: .utc(soon), end: .utc(soon.addingTimeInterval(3_600)))
        _ = try f.store.createEvent(details, rule: nil, in: f.cal.id)
        let found = try f.store.occurrences(
            from: soon.addingTimeInterval(-86_400), to: soon.addingTimeInterval(86_400), in: nil)
        #expect(found.count == 1)
    }

    @Test func defaultCalendarSkipsAFlaggedCalendarThatBecameReadOnly() throws {
        let f = try Fixture()
        var account = f.account
        account.calDAV = "https://dav.example.org/"
        try f.store.save(account)
        try f.store.replaceCalendars(
            [(href: "/a/", name: "A", color: nil, isReadOnly: false), (href: "/b/", name: "B", color: nil, isReadOnly: false)],
            for: account.id)
        let b = try #require(try f.store.calendars(account.id).first { $0.href == "/b/" })
        try f.store.setDefaultCalendar(b.id)
        try f.store.replaceCalendars(
            [(href: "/a/", name: "A", color: nil, isReadOnly: false), (href: "/b/", name: "B", color: nil, isReadOnly: true)],
            for: account.id)
        #expect(try f.store.defaultCalendar()?.href == "/a/")
    }

    @Test func editDuringSendStaysQueued() throws {
        let f = try CalFixture()
        try f.remote("/cal/work/a.ics", EventSeries(uid: "u1", base: meeting()))
        let id = try #require(try f.all().first).id
        try f.store.updateEvent(id, meeting("First"), rule: nil, scope: .event)
        let sent = try #require(try f.store.pendingEventChanges(f.account).first)
        try f.store.updateEvent(id, meeting("Second"), rule: nil, scope: .event)
        try f.store.eventChangeDone(
            id, revision: sent.revision, href: "/cal/work/a.ics", etag: "e2", ics: Data("x".utf8),
            series: EventSeries(uid: "u1", base: meeting("First")), scheduleTag: nil)
        let left = try #require(try f.store.pendingEventChanges(f.account).first)
        #expect(left.etag == "e2" && left.revision > sent.revision && left.edits.count == 1)
        #expect(try f.all().first?.occurrence.details.title == "Second")
        try f.store.eventChangeDone(
            id, revision: left.revision, href: "/cal/work/a.ics", etag: "e3", ics: Data("y".utf8),
            series: EventSeries(uid: "u1", base: meeting("Second")), scheduleTag: nil)
        #expect(try f.store.pendingEventChanges(f.account).isEmpty)
    }

    @Test func conflictDuringNewerEditHoldsTheEdits() throws {
        let f = try CalFixture()
        try f.remote("/cal/work/a.ics", EventSeries(uid: "u1", base: meeting()))
        let id = try #require(try f.all().first).id
        try f.store.updateEvent(id, meeting("First"), rule: nil, scope: .event)
        // While its send is in flight:
        try f.store.updateEvent(id, meeting("Second"), rule: nil, scope: .event)
        try f.store.eventChangeConflicted(
            id, server: (etag: "e9", ics: Data("s".utf8), series: EventSeries(uid: "u1", base: meeting("Theirs"))))
        let shown = try f.theEvent()
        #expect(shown.occurrence.details.title == "Theirs")
        guard case let .update(own, _, _)? = shown.conflict else { Issue.record("no conflict held"); return }
        #expect(own.title == "Second")
        #expect(try f.store.pendingEventChanges(f.account).isEmpty)
        #expect(try f.store.remoteETags(f.cal.id)["/cal/work/a.ics"] == "e9")
        try f.store.applyEventConflictAgain(id)
        let queued = try #require(try f.store.pendingEventChanges(f.account).first)
        #expect(queued.etag == "e9" && queued.edits.count == 2)
        #expect(try f.theEvent().occurrence.details.title == "Second")
    }

    @Test func conflictDuringNewerDeleteIsAFailedChange() throws {
        let f = try CalFixture()
        try f.remote("/cal/work/a.ics", EventSeries(uid: "u1", base: meeting()))
        let id = try #require(try f.all().first).id
        try f.store.updateEvent(id, meeting("First"), rule: nil, scope: .event)
        // While its send is in flight:
        try f.store.deleteEvent(id, scope: .event)
        try f.store.eventChangeConflicted(
            id, server: (etag: "e9", ics: Data("s".utf8), series: EventSeries(uid: "u1", base: meeting("Theirs"))))
        let shown = try f.theEvent()
        #expect(shown.occurrence.details.title == "Theirs")
        #expect(shown.conflict == nil)
        #expect(shown.changeFailed)
        #expect(try f.store.pendingEventChanges(f.account).isEmpty)
        // Deleting again is a new delete, over the server's object.
        try f.store.deleteEvent(id, scope: .event)
        let again = try #require(try f.store.pendingEventChanges(f.account).first)
        #expect(again.edits == [.delete(scope: .event)] && again.etag == "e9")
    }

    @Test func deleteThatMeetsAConflictIsAFailedChangeUntilDiscarded() throws {
        let f = try CalFixture()
        try f.remote("/cal/work/a.ics", EventSeries(uid: "u1", base: meeting()))
        let id = try #require(try f.all().first).id
        try f.store.deleteEvent(id, scope: .event)
        try f.store.eventChangeConflicted(
            id, server: (etag: "e9", ics: Data("s".utf8), series: EventSeries(uid: "u1", base: meeting("Theirs"))))
        let shown = try f.theEvent()
        #expect(shown.occurrence.details.title == "Theirs")
        #expect(shown.changeFailed && shown.conflict == nil)
        #expect(try f.store.pendingEventChanges(f.account).isEmpty)
        try f.store.restoreEventServerVersion(id, series: EventSeries(uid: "u1", base: meeting("Theirs")))
        let discarded = try f.theEvent()
        #expect(!discarded.changeFailed && discarded.occurrence.details.title == "Theirs")
        #expect(try f.store.pendingEventChanges(f.account).isEmpty)
    }

    @Test func aStaleFailureLeavesTheNewerEditQueued() throws {
        let f = try CalFixture()
        try f.remote("/cal/work/a.ics", EventSeries(uid: "u1", base: meeting()))
        let id = try #require(try f.all().first).id
        try f.store.updateEvent(id, meeting("First"), rule: nil, scope: .event)
        let sent = try #require(try f.store.pendingEventChanges(f.account).first)
        try f.store.updateEvent(id, meeting("Second"), rule: nil, scope: .event)
        try f.store.eventChangeFailed(id, revision: sent.revision)
        let pending = try f.store.pendingEventChanges(f.account)
        #expect(pending.count == 1 && pending.first?.revision != sent.revision)
        #expect(try !f.theEvent().changeFailed)
        #expect(try f.theEvent().occurrence.details.title == "Second")
    }

    @Test func conflictAfterDiscardDuringSendShowsTheServersEvent() throws {
        let f = try CalFixture()
        try f.remote("/cal/work/a.ics", EventSeries(uid: "u1", base: meeting()))
        let id = try #require(try f.all().first).id
        try f.store.updateEvent(id, meeting("First"), rule: nil, scope: .event)
        // While its send is in flight:
        try f.store.restoreEventServerVersion(id, series: EventSeries(uid: "u1", base: meeting()))
        try f.store.eventChangeConflicted(
            id, server: (etag: "e9", ics: Data("s".utf8), series: EventSeries(uid: "u1", base: meeting("Theirs"))))
        let shown = try f.theEvent()
        #expect(shown.occurrence.details.title == "Theirs")
        #expect(shown.conflict == nil)
        #expect(try f.store.pendingEventChanges(f.account).isEmpty)
        #expect(try f.store.remoteETags(f.cal.id)["/cal/work/a.ics"] == "e9")
    }

    @Test func createDuringSendBecomesUpdate() throws {
        let f = try CalFixture()
        let id = try f.store.createEvent(meeting("A"), rule: nil, in: f.cal.id)
        let sent = try #require(try f.store.pendingEventChanges(f.account).first)
        try f.store.setEventCreateTarget(id, href: "/cal/work/new.ics", ics: Data("n".utf8))
        #expect(try f.store.eventCreateTarget(id)?.href == "/cal/work/new.ics")
        try f.store.updateEvent(id, meeting("B"), rule: nil, scope: .event)
        try f.store.eventChangeDone(
            id, revision: sent.revision, href: "/cal/work/new.ics", etag: "e1", ics: Data("n".utf8),
            series: EventSeries(uid: "u", base: meeting("A")), scheduleTag: nil)
        let left = try #require(try f.store.pendingEventChanges(f.account).first)
        guard case .update? = left.edits.first, left.edits.count == 1 else {
            Issue.record("the sent create is done, the newer update is left")
            return
        }
        #expect(left.href == "/cal/work/new.ics")
        #expect(try f.store.eventCreateTarget(id) == nil)
    }

    @Test func invitedEventCannotBeEdited() throws {
        let f = try CalFixture()
        let invited = meeting(organizer: "boss@example.org", attendees: [Attendee(email: "anna@example.org")])
        try f.remote("/cal/work/a.ics", EventSeries(uid: "u1", base: invited))
        let shown = try f.theEvent()
        #expect(!shown.isEditable)
        expectReadOnly { try f.store.updateEvent(shown.id, meeting("Mine"), rule: nil, scope: .event) }
        expectReadOnly { try f.store.deleteEvent(shown.id, scope: .event) }
        let own = meeting("Own", organizer: "Anna@Example.org")
        try f.remote("/cal/work/b.ics", EventSeries(uid: "u2", base: own))
        #expect(try f.all().first { $0.occurrence.details.title == "Own" }?.isEditable == true)
    }

    @Test func readOnlyCalendarRefusesEdits() throws {
        let f = try CalFixture(readOnly: true)
        expectReadOnly { _ = try f.store.createEvent(meeting(), rule: nil, in: f.cal.id) }
        try f.remote("/cal/work/a.ics", EventSeries(uid: "u1", base: meeting()))
        let shown = try f.theEvent()
        #expect(!shown.isEditable)
        expectReadOnly { try f.store.deleteEvent(shown.id, scope: .event) }
    }

    @Test func ownTentativeReplyDrawsTentative() throws {
        let f = try CalFixture()
        let replied = meeting(
            organizer: "boss@example.org",
            attendees: [Attendee(email: "ANNA@example.org", response: .tentative)])
        try f.remote("/cal/work/a.ics", EventSeries(uid: "u1", base: replied))
        let shown = try f.theEvent()
        #expect(shown.occurrence.details.status == .confirmed)
        #expect(shown.isTentative)
        try f.remote("/cal/work/b.ics", EventSeries(uid: "u2", base: meeting("Plain", day: 11)))
        #expect(try f.all().first { $0.occurrence.details.title == "Plain" }?.isTentative == false)
    }

    @Test func eventByUidAndRecurrenceIdIsFound() throws {
        let f = try CalFixture()
        try f.remote("/cal/work/a.ics", EventSeries(uid: "u1", base: meeting(), rule: weekly))
        let second = EventTime.utc(utc(2026, 12, 17, 9))
        let found = try #require(try f.store.event(accountId: f.account, uid: "u1", recurrenceID: second))
        #expect(found.occurrence.recurrenceID == second)
        #expect(found.occurrence.start == utc(2026, 12, 17, 9))
        #expect(try f.store.event(accountId: f.account, uid: "nope", recurrenceID: nil) == nil)
        let byID = try f.store.event(found.id, occurrence: second)
        #expect(byID?.occurrence.start == utc(2026, 12, 17, 9))
    }

    @Test func queuedEventIsNotOverwrittenByServer() throws {
        let f = try CalFixture()
        try f.remote("/cal/work/a.ics", EventSeries(uid: "u1", base: meeting()))
        let id = try #require(try f.all().first).id
        try f.store.updateEvent(id, meeting("Mine"), rule: nil, scope: .event)
        #expect(try f.remote("/cal/work/a.ics", EventSeries(uid: "u1", base: meeting("Theirs")), etag: "e2") == false)
        #expect(try f.all().first?.occurrence.details.title == "Mine")
        #expect(try f.store.remoteETags(f.cal.id)["/cal/work/a.ics"] == "e1")
    }

    @Test func conflictKeepsBothVersions() throws {
        let f = try CalFixture()
        try f.remote("/cal/work/a.ics", EventSeries(uid: "u1", base: meeting()))
        let id = try #require(try f.all().first).id
        try f.store.updateEvent(id, meeting("Mine"), rule: nil, scope: .event)
        let theirs = EventSeries(uid: "u1", base: meeting("Theirs"))
        try f.store.eventChangeConflicted(
            id, server: (etag: "e9", ics: Data("s".utf8), series: theirs))
        let shown = try f.theEvent()
        #expect(shown.occurrence.details.title == "Theirs")
        guard case let .update(own, _, _)? = shown.conflict else { Issue.record("no conflict held"); return }
        #expect(own.title == "Mine")
        #expect(try f.store.pendingEventChanges(f.account).isEmpty)
    }

    @Test func applyAgainQueuesUpdate() throws {
        let f = try CalFixture()
        try f.remote("/cal/work/a.ics", EventSeries(uid: "u1", base: meeting()))
        let id = try #require(try f.all().first).id
        try f.store.updateEvent(id, meeting("Mine"), rule: nil, scope: .event)
        let sent = try #require(try f.store.pendingEventChanges(f.account).first)
        try f.store.eventChangeConflicted(
            id, server: (etag: "e9", ics: Data("s".utf8), series: EventSeries(uid: "u1", base: meeting("Theirs"))))
        try f.store.applyEventConflictAgain(id)
        let shown = try f.theEvent()
        #expect(shown.conflict == nil && shown.occurrence.details.title == "Mine")
        let queued = try #require(try f.store.pendingEventChanges(f.account).first)
        #expect(queued.etag == "e9" && queued.revision > sent.revision)
    }

    @Test func discardDropsOwnVersion() throws {
        let f = try CalFixture()
        try f.remote("/cal/work/a.ics", EventSeries(uid: "u1", base: meeting()))
        let id = try #require(try f.all().first).id
        try f.store.updateEvent(id, meeting("Mine"), rule: nil, scope: .event)
        try f.store.eventChangeConflicted(
            id, server: (etag: "e9", ics: Data("s".utf8), series: EventSeries(uid: "u1", base: meeting("Theirs"))))
        try f.store.discardEventConflict(id)
        let shown = try f.theEvent()
        #expect(shown.conflict == nil && shown.occurrence.details.title == "Theirs")
        #expect(try f.store.pendingEventChanges(f.account).isEmpty)
    }

    @Test func failedChangeMarksTheEvent() throws {
        let f = try CalFixture()
        try f.remote("/cal/work/a.ics", EventSeries(uid: "u1", base: meeting()))
        let id = try #require(try f.all().first).id
        try f.store.deleteEvent(id, scope: .event)
        let sent = try #require(try f.store.pendingEventChanges(f.account).first)
        #expect(try f.store.eventChangeAttempted(id, revision: sent.revision) == 1)
        #expect(try f.store.eventChangeAttempted(id, revision: sent.revision) == 2)
        try f.store.eventChangeFailed(id, revision: sent.revision)
        #expect(try f.store.pendingEventChanges(f.account).isEmpty)
        let shown = try f.theEvent()
        #expect(shown.changeFailed)
    }

    @Test func removedCalendarKeepsEventsWithQueuedChanges() throws {
        let f = try CalFixture()
        try f.remote("/cal/work/a.ics", EventSeries(uid: "u1", base: meeting("Queued")))
        try f.remote("/cal/work/b.ics", EventSeries(uid: "u2", base: meeting("Plain", day: 11)))
        let id = try #require(try f.all().first { $0.occurrence.details.title == "Queued" }).id
        try f.store.updateEvent(id, meeting("Queued 2"), rule: nil, scope: .event)
        try f.store.replaceCalendars([], for: f.account)
        #expect(try f.store.calendars(f.account).isEmpty)
        let left = try f.all()
        #expect(left.map(\.occurrence.details.title) == ["Queued 2"])
        #expect(left.first?.changeFailed == true)
        #expect(try f.store.pendingEventChangeCount(f.account) == 0)
    }

    @Test func clearCalendarsRemovesEverything() throws {
        let f = try CalFixture()
        try f.remote("/cal/work/a.ics", EventSeries(uid: "u1", base: meeting()))
        try f.store.clearCalendars(of: f.account)
        #expect(try f.store.allCalendars().isEmpty && f.all().isEmpty)
    }

    @Test func defaultCalendarFallsBackToFirstWritable() throws {
        let f = try Fixture()
        var account = f.account
        account.calDAV = "https://dav.example.org/"
        try f.store.save(account)
        #expect(try f.store.defaultCalendar() == nil)
        try f.store.replaceCalendars(
            [
                (href: "/ro/", name: "Holidays", color: 0x112233, isReadOnly: true),
                (href: "/rw/", name: "Home", color: nil, isReadOnly: false),
                (href: "/rw2/", name: "Work", color: nil, isReadOnly: false)
            ], for: account.id)
        let all = try f.store.calendars(account.id)
        #expect(all.first { $0.href == "/ro/" }?.color == 0x112233)
        #expect(try f.store.defaultCalendar()?.href == "/rw/")
        let work = try #require(all.first { $0.href == "/rw2/" })
        try f.store.setDefaultCalendar(work.id)
        #expect(try f.store.defaultCalendar()?.href == "/rw2/")
        #expect(try f.store.allCalendars().filter(\.isDefault).count == 1)
    }

    @Test func syncStateIsKeptPerCalendar() throws {
        let f = try CalFixture()
        #expect(try f.store.syncToken(f.cal.id) == nil && f.store.windowListedFrom(f.cal.id) == nil)
        try f.store.setSyncToken("tok", for: f.cal.id)
        try f.store.setWindowListedFrom(20_261_101, for: f.cal.id)
        #expect(try f.store.syncToken(f.cal.id) == "tok")
        #expect(try f.store.windowListedFrom(f.cal.id) == 20_261_101)
    }

    @Test func removeRemoteSparesQueuedEvents() throws {
        let f = try CalFixture()
        try f.remote("/cal/work/a.ics", EventSeries(uid: "u1", base: meeting("A")))
        try f.remote("/cal/work/b.ics", EventSeries(uid: "u2", base: meeting("B", day: 11)))
        let a = try #require(try f.all().first { $0.occurrence.details.title == "A" }).id
        try f.store.updateEvent(a, meeting("A2"), rule: nil, scope: .event)
        try f.store.removeRemote(hrefs: ["/cal/work/a.ics", "/cal/work/b.ics"], in: f.cal.id)
        #expect(try f.all().map(\.occurrence.details.title) == ["A2"])
    }

    @Test func reexpandFollowsPhoneZone() throws {
        let f = try CalFixture()
        let floating = EventDetails(
            title: "Standup", start: .floating(DateComponents(year: 2026, month: 12, day: 10, hour: 9)),
            end: .floating(DateComponents(year: 2026, month: 12, day: 10, hour: 10)))
        try f.remote("/cal/work/a.ics", EventSeries(uid: "u1", base: floating), zone: utcZone)
        #expect(try f.all().first?.occurrence.start == utc(2026, 12, 10, 9))
        try f.store.reexpandAll(window: window, phoneZone: stockholm, day: 20_261_107)
        #expect(try f.all().first?.occurrence.start == utc(2026, 12, 10, 8))
    }

    @Test func observingCalendarsSeesEveryChange() async throws {
        let f = try CalFixture()
        let changes = f.store.observeCalendars()
        let store = f.store
        let cal = f.cal
        let account = f.account
        let seen = try await withThrowingTaskGroup(of: Int?.self) { group in
            group.addTask {
                var changed = changes.makeAsyncIterator()
                _ = try await changed.next()
                try store.upsertRemote(
                    href: "/a.ics", etag: "1", ics: Data(), series: EventSeries(uid: "a", base: meeting("A")),
                    in: cal.id, window: window, phoneZone: utcZone, scheduleTag: nil)
                var count = try await changed.next() != nil ? 1 : 0
                try store.replaceCalendars(
                    [(href: "/cal/work/", name: "Work renamed", color: nil, isReadOnly: false)], for: account)
                count += try await changed.next() != nil ? 1 : 0
                return count
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                return nil
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }
        #expect(seen == 2)
    }
}

@Suite struct EventRestoreStoreTests {
    @Test func discardingAFailedChangeRestoresTheServerVersion() throws {
        let f = try CalFixture()
        try f.remote("/cal/work/a.ics", EventSeries(uid: "u1", base: meeting("Theirs")))
        let id = try f.theEvent().id
        try f.store.updateEvent(id, meeting("Mine", hour: 11), rule: nil, scope: .event)
        let sent = try #require(try f.store.pendingEventChanges(f.account).first)
        try f.store.eventChangeFailed(id, revision: sent.revision)
        #expect(try f.theEvent().changeFailed)

        try f.store.restoreEventServerVersion(id, series: EventSeries(uid: "u1", base: meeting("Theirs")))
        let restored = try f.theEvent()
        #expect(restored.occurrence.details.title == "Theirs")
        #expect(restored.occurrence.start == utc(2026, 12, 10, 9))
        #expect(!restored.changeFailed)
        #expect(try f.store.pendingEventChanges(f.account).isEmpty)
        // The next sync takes the server's object again instead of skipping the row.
        #expect(try f.remote("/cal/work/a.ics", EventSeries(uid: "u1", base: meeting("Newer")), etag: "e2"))
        #expect(try f.theEvent().occurrence.details.title == "Newer")
    }

    @Test func discardingACreateTheServerNeverHadRemovesIt() throws {
        let f = try CalFixture()
        let id = try f.store.createEvent(meeting("Never sent"), rule: nil, in: f.cal.id)
        let sent = try #require(try f.store.pendingEventChanges(f.account).first)
        try f.store.eventChangeFailed(id, revision: sent.revision)
        try f.store.restoreEventServerVersion(id, series: nil)
        #expect(try f.all().isEmpty)
    }

    @Test func anUnreadableServerObjectIsFetchedAgain() throws {
        let f = try CalFixture()
        try f.remote("/cal/work/a.ics", EventSeries(uid: "u1", base: meeting("Theirs")))
        let id = try f.theEvent().id
        try f.store.updateEvent(id, meeting("Mine"), rule: nil, scope: .event)
        let sent = try #require(try f.store.pendingEventChanges(f.account).first)
        try f.store.eventChangeFailed(id, revision: sent.revision)
        try f.store.setSyncToken("t1", for: f.cal.id)
        try f.store.restoreEventServerVersion(id, series: nil)
        #expect(try !f.theEvent().changeFailed)
        #expect(try f.store.remoteETags(f.cal.id)["/cal/work/a.ics"] != "e1", "its tag goes, so it is fetched again")
        #expect(try f.store.syncToken(f.cal.id) == nil)
    }

    /// A Microsoft account has calendars and takes edits without a CalDAV address (Graph is its server).
    @Test func microsoftAccountAcceptsEventEdits() throws {
        let f = try CalFixture()
        try f.remote("me/events/e1", EventSeries(uid: "e1", base: meeting("Held")))
        var account = try #require(try f.store.accounts().first { $0.id == f.account })
        account.calDAV = nil
        account.calendarVia = .graph
        try f.store.save(account)
        try f.store.replaceCalendars(
            [(href: "/cal/work/", name: "Work", color: nil, isReadOnly: false)], for: f.account)
        #expect(try f.store.calendars(f.account).map(\.href) == ["/cal/work/"])
        let held = try f.theEvent()
        try f.store.updateEvent(held.id, meeting("Edited"), rule: nil, scope: .event)
        _ = try f.store.createEvent(meeting("New", day: 11), rule: nil, in: f.cal.id)
        #expect(try f.store.pendingEventChanges(f.account).count == 2)
    }
}
