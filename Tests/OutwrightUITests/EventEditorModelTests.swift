// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightMIME
import OutwrightModel
import OutwrightStore
import OutwrightSync
import Testing

@testable import OutwrightUI

@MainActor @Suite struct EventEditorModelTests {
    private func editor(
        _ fixture: CalendarFixture, editing: EventRequest? = nil, day: Date? = nil, scope: EditScope = .event
    ) -> EventEditorModel {
        EventEditorModel(
            app: fixture.app, editing: editing, day: day, scope: scope, calendar: phoneCalendar(),
            now: { calendarNow })
    }

    private func wall(day: Int, _ hour: Int) -> DateComponents {
        DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: 0, second: 0)
    }

    /// A daily stand-up at 9 in Stockholm from November 10, with the 11th's occurrence moved to 9:30
    /// and named "Moved stand-up".
    private func series(_ fixture: CalendarFixture, rule: RecurrenceRule = RecurrenceRule(freq: .daily))
        throws -> EventID {
        let zone = "Europe/Stockholm"
        let base = EventDetails(
            title: "Stand-up", start: .zoned(wall(day: 10, 9), zone: zone), end: .zoned(wall(day: 10, 10), zone: zone),
            reminder: 10)
        var moved = base
        moved.title = "Moved stand-up"
        var later = wall(day: 11, 9)
        later.minute = 30
        moved.start = .zoned(later, zone: zone)
        later.hour = 10
        moved.end = .zoned(later, zone: zone)
        let cal = try fixture.calendar("Work")
        let window = CalendarWindow.window(now: calendarNow, zone: stockholm)
        try fixture.store.upsertRemote(
            href: "/cal/standup.ics", etag: "1", ics: Data(),
            series: EventSeries(
                uid: "standup", base: base, rule: rule,
                overrides: [EventOverride(recurrenceID: .zoned(wall(day: 11, 9), zone: zone), details: moved)]),
            in: cal.id, window: window, phoneZone: stockholm, scheduleTag: nil)
        let found = try fixture.store.occurrences(from: window.lowerBound, to: window.upperBound, in: [cal.id])
        return try #require(found.first { $0.occurrence.details.title == "Stand-up" }?.id)
    }

    private func occurrence(_ fixture: CalendarFixture, _ id: EventID, day: Int) throws -> EventRequest {
        let found = try fixture.store.occurrences(
            from: fixture.at(day: day, 0), to: fixture.at(day: day + 1, 0), in: nil)
        let event = try #require(found.first { $0.id == id })
        return EventRequest(event)
    }

    @Test func newEventDefaultsToDefaultCalendarNextHalfHourAnd15Minutes() throws {
        let fixture = try CalendarFixture()
        try fixture.store.setDefaultCalendar(try fixture.calendar("Home").id)
        let model = editor(fixture)
        #expect(model.calendar == (try fixture.calendar("Home").id))
        #expect(model.start == fixture.at(day: 10, 10, 30))
        #expect(model.end == fixture.at(day: 10, 11))
        #expect(model.details.reminder == 15)
        #expect(model.zone == stockholm)
        #expect(model.rule == nil)
        #expect(!model.isAllDay)
        #expect(model.canSave)

        let onDay = editor(fixture, day: fixture.at(day: 14, 0))
        #expect(onDay.start == fixture.at(day: 14, 10, 30))
    }

    /// Thirty minutes from the next half hour, or from the slot tapped, in the account in view's calendar.
    @Test func newEventIsThirtyMinutesInTheAccountInView() throws {
        let fixture = try CalendarFixture()
        try fixture.store.setDefaultCalendar(try fixture.calendar("Home").id)
        let home = try #require(fixture.app.accounts.first { $0.email == "home@example.org" })
        fixture.app.scope = .folder(try fixture.box.folder(home, .inbox).id)
        let model = EventEditorModel(
            app: fixture.app, editing: nil, day: nil, calendar: phoneCalendar(), now: { fixture.at(day: 10, 10, 47) })
        #expect(model.calendar == (try fixture.calendar("Family").id))
        #expect(model.start == fixture.at(day: 10, 11))
        #expect(model.end == fixture.at(day: 10, 11, 30))

        let tapped = EventEditorModel(
            app: fixture.app, editing: nil, day: nil, start: fixture.at(day: 14, 9, 30), calendar: phoneCalendar(),
            now: { calendarNow })
        #expect(tapped.start == fixture.at(day: 14, 9, 30))
        #expect(tapped.end == fixture.at(day: 14, 10))

        // With every account in view, the default calendar.
        fixture.app.scope = .allAccounts
        #expect(editor(fixture).calendar == (try fixture.calendar("Home").id))
    }

    @Test func allDayHasNoReminder() throws {
        let fixture = try CalendarFixture()
        let model = editor(fixture, day: fixture.at(day: 14, 0))
        model.isAllDay = true
        #expect(model.details.reminder == nil)
        #expect(model.details.start == .date(year: 2026, month: 11, day: 14))
        #expect(model.details.end == .date(year: 2026, month: 11, day: 15))
        let id = try model.save(scope: .event)
        let saved = try #require(try fixture.store.series(id)?.base)
        #expect(saved.reminder == nil)
        #expect(saved.start == .date(year: 2026, month: 11, day: 14))
    }

    @Test func readOnlyCalendarsAreNotOffered() throws {
        let fixture = try CalendarFixture()
        let anna = try #require(fixture.box.accounts.first)
        try fixture.store.replaceCalendars(
            [(href: "/cal/work/", name: "Work", color: 0x2F6FDB, isReadOnly: false),
             (href: "/cal/home/", name: "Home", color: 0xD9534F, isReadOnly: false),
             (href: "/cal/holidays/", name: "Holidays", color: nil, isReadOnly: true)], for: anna.id)
        let model = editor(fixture)
        let names = model.writableCalendars.map { $0.calendars.map(\.name) }
        #expect(names == [["Home", "Work"], ["Family"]])
        #expect(model.writableCalendars.map(\.account.email) == ["anna@example.org", "home@example.org"])
    }

    @Test func endBeforeStartCannotBeSaved() throws {
        let fixture = try CalendarFixture()
        let model = editor(fixture)
        model.end = model.start.addingTimeInterval(-1_800)
        #expect(!model.canSave)
        #expect(throws: EventEditError.endBeforeStart) { _ = try model.save(scope: .event) }
        // Moving the start keeps the length, so it can't put the end before it.
        model.end = model.start.addingTimeInterval(1_800)
        model.start = fixture.at(day: 10, 15)
        #expect(model.end == fixture.at(day: 10, 15, 30))
        #expect(model.canSave)
    }

    @Test func editSeriesTitleKeepsOverrides() throws {
        let fixture = try CalendarFixture()
        let id = try series(fixture)
        let model = editor(fixture, editing: try occurrence(fixture, id, day: 12))
        model.details.title = "Daily stand-up"
        #expect(!model.dropsOverrides)
        _ = try model.save(scope: .event)
        let saved = try #require(try fixture.store.series(id))
        #expect(saved.base?.title == "Daily stand-up")
        #expect(saved.base?.start == .zoned(wall(day: 10, 9), zone: "Europe/Stockholm"))
        #expect(saved.overrides.map(\.details.title) == ["Moved stand-up"])
    }

    @Test func editSeriesTimeWarnsAndDropsOverrides() throws {
        let fixture = try CalendarFixture()
        let id = try series(fixture)
        let model = editor(fixture, editing: try occurrence(fixture, id, day: 12))
        #expect(model.start == fixture.at(day: 12, 9))
        model.start = fixture.at(day: 12, 10)
        #expect(model.dropsOverrides)
        _ = try model.save(scope: .event)
        let saved = try #require(try fixture.store.series(id))
        #expect(saved.overrides.isEmpty)
        // The series moves by the same hour from its own first day, not to the day it was edited from.
        #expect(saved.base?.start == .zoned(wall(day: 10, 10), zone: "Europe/Stockholm"))
        #expect(saved.base?.end == .zoned(wall(day: 10, 11), zone: "Europe/Stockholm"))
    }

    @Test func anOccurrenceInAZoneOnlyItsObjectDefinesKeepsItsEnd() throws {
        let fixture = try CalendarFixture()
        // Five hours east of UTC all year, known only from the object's VTIMEZONE.
        let zone = "Example Standard Time"
        let rules = ZoneRules(observances: [
            Observance(
                isDaylight: false, start: DateComponents(year: 1970, month: 1, day: 1, hour: 0, minute: 0, second: 0),
                offsetFrom: 18_000, offsetTo: 18_000)
        ])
        let base = EventDetails(
            title: "Far stand-up", start: .zoned(wall(day: 10, 9), zone: zone), end: .zoned(wall(day: 10, 10), zone: zone))
        let cal = try fixture.calendar("Work")
        let window = CalendarWindow.window(now: calendarNow, zone: stockholm)
        try fixture.store.upsertRemote(
            href: "/cal/far.ics", etag: "1", ics: Data(),
            series: EventSeries(uid: "far", base: base, rule: RecurrenceRule(freq: .daily), zones: [zone: rules]),
            in: cal.id, window: window, phoneZone: stockholm, scheduleTag: nil)
        let found = try fixture.store.occurrences(from: window.lowerBound, to: window.upperBound, in: [cal.id])
        let id = try #require(found.first { $0.occurrence.details.title == "Far stand-up" }?.id)
        let request = try occurrence(fixture, id, day: 12)
        let rid = try #require(request.occurrence)
        let model = editor(fixture, editing: request, scope: .occurrence(rid))
        #expect(model.details.start == .zoned(wall(day: 12, 9), zone: zone))
        #expect(model.details.end == .zoned(wall(day: 12, 10), zone: zone))
    }

    @Test func editThisOccurrenceOnly() throws {
        let fixture = try CalendarFixture()
        let id = try series(fixture)
        let request = try occurrence(fixture, id, day: 12)
        let rid = try #require(request.occurrence)
        let model = editor(fixture, editing: request, scope: .occurrence(rid))
        #expect(model.start == fixture.at(day: 12, 9))
        model.details.title = "Long stand-up"
        model.end = fixture.at(day: 12, 11)
        #expect(!model.dropsOverrides)
        _ = try model.save(scope: .occurrence(rid))
        let saved = try #require(try fixture.store.series(id))
        #expect(saved.base?.title == "Stand-up")
        #expect(saved.overrides.count == 2)
        let twelfth = try fixture.store.occurrences(from: fixture.at(day: 12, 0), to: fixture.at(day: 13, 0), in: nil)
        #expect(twelfth.map(\.occurrence.details.title) == ["Long stand-up"])
        #expect(twelfth.first?.occurrence.end == fixture.at(day: 12, 11))
        let thirteenth = try fixture.store.occurrences(
            from: fixture.at(day: 13, 0), to: fixture.at(day: 14, 0), in: nil)
        #expect(thirteenth.map(\.occurrence.details.title) == ["Stand-up"])
    }

    /// The daily stand-up moved to 9:30, half an hour, and renamed from the 11th on (RANGE=THISANDFUTURE).
    private func rangedSeries(_ fixture: CalendarFixture, rule: RecurrenceRule = RecurrenceRule(freq: .daily),
                              rangeTitle: String = "Later stand-up", more: [EventOverride] = [])
        throws -> EventID {
        let zone = "Europe/Stockholm"
        let base = rangedBase
        var moved = base
        moved.title = rangeTitle
        var start = wall(day: 11, 9)
        start.minute = 30
        moved.start = .zoned(start, zone: zone)
        moved.end = .zoned(wall(day: 11, 10), zone: zone)
        let cal = try fixture.calendar("Work")
        let window = CalendarWindow.window(now: calendarNow, zone: stockholm)
        try fixture.store.upsertRemote(
            href: "/cal/ranged.ics", etag: "1", ics: Data(),
            series: EventSeries(
                uid: "ranged", base: base, rule: rule,
                overrides: [EventOverride(recurrenceID: .zoned(wall(day: 11, 9), zone: zone), details: moved,
                                          thisAndFuture: true)] + more),
            in: cal.id, window: window, phoneZone: stockholm, scheduleTag: nil)
        let found = try fixture.store.occurrences(from: window.lowerBound, to: window.upperBound, in: [cal.id])
        return try #require(found.first { $0.occurrence.details.title == "Stand-up" }?.id)
    }

    private var rangedBase: EventDetails {
        let zone = "Europe/Stockholm"
        return EventDetails(
            title: "Stand-up", start: .zoned(wall(day: 10, 9), zone: zone), end: .zoned(wall(day: 10, 10), zone: zone))
    }

    @Test func editTheRangeOwnOccurrenceStopsAtTheNextRange() throws {
        let fixture = try CalendarFixture()
        let zone = "Europe/Stockholm"
        let next = EventDetails(
            title: "Latest stand-up", start: .zoned(wall(day: 12, 11), zone: zone),
            end: .zoned(wall(day: 12, 12), zone: zone))
        let id = try rangedSeries(fixture, more: [
            EventOverride(recurrenceID: .zoned(wall(day: 12, 9), zone: zone), details: next, thisAndFuture: true),
        ])
        let rid = try #require(try occurrence(fixture, id, day: 11).occurrence)
        let model = editor(fixture, editing: try occurrence(fixture, id, day: 11), scope: .occurrence(rid))
        model.details.title = "Renamed stand-up"
        _ = try model.save(scope: .occurrence(rid))
        let saved = try #require(try fixture.store.series(id))
        // No range is carried on: the 12th's own range begins where the 11th's would have.
        #expect(saved.overrides.count == 2)
        #expect(saved.overrides.first { $0.recurrenceID == .zoned(wall(day: 11, 9), zone: zone) }?.thisAndFuture
            == false)
        #expect(saved.overrides.first { $0.recurrenceID == .zoned(wall(day: 12, 9), zone: zone) }?.thisAndFuture
            == true)
        let days = try fixture.store.occurrences(from: fixture.at(day: 11, 0), to: fixture.at(day: 14, 0), in: nil)
            .filter { $0.id == id }
        #expect(days.map(\.occurrence.details.title) == ["Renamed stand-up", "Latest stand-up", "Latest stand-up"])
        #expect(days.map(\.occurrence.start) == [fixture.at(day: 11, 9, 30), fixture.at(day: 12, 11),
                                                 fixture.at(day: 13, 11)])
    }

    @Test func aSeriesEditReachesARangeWhereItKeptTheSeriesFields() throws {
        let fixture = try CalendarFixture()
        let id = try rangedSeries(fixture, rangeTitle: "Stand-up")
        var renamed = rangedBase
        renamed.title = "Daily"
        renamed.place = "Room 1"
        try fixture.store.updateEvent(id, renamed, rule: RecurrenceRule(freq: .daily), scope: .event)
        let days = try fixture.store.occurrences(from: fixture.at(day: 10, 0), to: fixture.at(day: 13, 0), in: nil)
            .filter { $0.id == id }
        #expect(days.map(\.occurrence.details.title) == ["Daily", "Daily", "Daily"])
        #expect(days.map(\.occurrence.details.place) == ["Room 1", "Room 1", "Room 1"])
        #expect(days.map(\.occurrence.start) == [fixture.at(day: 10, 9), fixture.at(day: 11, 9, 30),
                                                 fixture.at(day: 12, 9, 30)])
    }

    @Test func aSeriesEditLeavesWhatARangeChangedOnPurpose() throws {
        let fixture = try CalendarFixture()
        let id = try rangedSeries(fixture)
        var renamed = rangedBase
        renamed.title = "Daily"
        renamed.place = "Room 1"
        try fixture.store.updateEvent(id, renamed, rule: RecurrenceRule(freq: .daily), scope: .event)
        let days = try fixture.store.occurrences(from: fixture.at(day: 10, 0), to: fixture.at(day: 13, 0), in: nil)
            .filter { $0.id == id }
        #expect(days.map(\.occurrence.details.title) == ["Daily", "Later stand-up", "Later stand-up"])
        #expect(days.map(\.occurrence.details.place) == ["Room 1", "Room 1", "Room 1"])
    }

    @Test func editThisOccurrenceInsideARangeStartsFromTheRange() throws {
        let fixture = try CalendarFixture()
        let id = try rangedSeries(fixture)
        let request = try occurrence(fixture, id, day: 13)
        let rid = try #require(request.occurrence)
        let model = editor(fixture, editing: request, scope: .occurrence(rid))
        #expect(model.details.title == "Later stand-up")
        #expect(model.start == fixture.at(day: 13, 9, 30))
        #expect(model.end == fixture.at(day: 13, 10))
        model.details.title = "Single stand-up"
        _ = try model.save(scope: .occurrence(rid))
        let saved = try #require(try fixture.store.series(id))
        #expect(saved.overrides.map(\.thisAndFuture) == [true, false])
        let thirteenth = try fixture.store.occurrences(
            from: fixture.at(day: 13, 0), to: fixture.at(day: 14, 0), in: nil)
        #expect(thirteenth.map(\.occurrence.details.title) == ["Single stand-up"])
        #expect(thirteenth.first?.occurrence.start == fixture.at(day: 13, 9, 30))
        let fourteenth = try fixture.store.occurrences(
            from: fixture.at(day: 14, 0), to: fixture.at(day: 15, 0), in: nil)
        #expect(fourteenth.map(\.occurrence.details.title) == ["Later stand-up"])
    }

    @Test func editTheRangeOwnOccurrenceChangesItAlone() throws {
        let fixture = try CalendarFixture()
        let id = try rangedSeries(fixture)
        let request = try occurrence(fixture, id, day: 11)
        let rid = try #require(request.occurrence)
        let model = editor(fixture, editing: request, scope: .occurrence(rid))
        model.details.title = "Renamed stand-up"
        _ = try model.save(scope: .occurrence(rid))
        let saved = try #require(try fixture.store.series(id))
        let zone = "Europe/Stockholm"
        #expect(saved.overrides.map(\.recurrenceID) == [.zoned(wall(day: 11, 9), zone: zone),
                                                         .zoned(wall(day: 12, 9), zone: zone)])
        #expect(saved.overrides.map(\.thisAndFuture) == [false, true])
        var later = wall(day: 12, 9)
        later.minute = 30
        #expect(saved.overrides.last?.details.start == .zoned(later, zone: zone))
        #expect(saved.overrides.last?.details.end == .zoned(wall(day: 12, 10), zone: zone))
        let days = try fixture.store.occurrences(from: fixture.at(day: 11, 0), to: fixture.at(day: 14, 0), in: nil)
            .filter { $0.id == id }
        #expect(days.map(\.occurrence.details.title) == ["Renamed stand-up", "Later stand-up", "Later stand-up"])
        #expect(days.map(\.occurrence.start) == [11, 12, 13].map { fixture.at(day: $0, 9, 30) })
    }

    @Test func deleteTheRangeOwnOccurrenceKeepsTheLaterOnesMoved() throws {
        let fixture = try CalendarFixture()
        let id = try rangedSeries(fixture)
        let rid = try #require(try occurrence(fixture, id, day: 11).occurrence)
        try fixture.store.deleteEvent(id, scope: .occurrence(rid))
        let saved = try #require(try fixture.store.series(id))
        #expect(saved.exdates == [rid])
        #expect(saved.overrides.map(\.recurrenceID) == [.zoned(wall(day: 12, 9), zone: "Europe/Stockholm")])
        #expect(saved.overrides.map(\.thisAndFuture) == [true])
        let days = try fixture.store.occurrences(from: fixture.at(day: 10, 0), to: fixture.at(day: 14, 0), in: nil)
            .filter { $0.id == id }
        #expect(days.map(\.occurrence.details.title) == ["Stand-up", "Later stand-up", "Later stand-up"])
        #expect(days.map(\.occurrence.start) == [fixture.at(day: 10, 9), fixture.at(day: 12, 9, 30),
                                                 fixture.at(day: 13, 9, 30)])
    }

    @Test func aRangeOnTheLastOccurrenceEndsWithIt() throws {
        let fixture = try CalendarFixture()
        let id = try rangedSeries(fixture, rule: RecurrenceRule(freq: .daily, count: 2))
        let rid = try #require(try occurrence(fixture, id, day: 11).occurrence)
        let model = editor(fixture, editing: try occurrence(fixture, id, day: 11), scope: .occurrence(rid))
        model.details.title = "Last stand-up"
        _ = try model.save(scope: .occurrence(rid))
        let saved = try #require(try fixture.store.series(id))
        #expect(saved.overrides.map(\.thisAndFuture) == [false])
        let days = try fixture.store.occurrences(from: fixture.at(day: 10, 0), to: fixture.at(day: 14, 0), in: nil)
            .filter { $0.id == id }
        #expect(days.map(\.occurrence.details.title) == ["Stand-up", "Last stand-up"])
    }

    @Test func customRuleIsKeptWhenUntouched() throws {
        let fixture = try CalendarFixture()
        let custom = RecurrenceRule(
            freq: .weekly, count: 10, byDay: [WeekdayNum(weekday: 2), WeekdayNum(weekday: 4)])
        let id = try series(fixture, rule: custom)
        let model = editor(fixture, editing: EventRequest(event: id, occurrence: nil))
        #expect(model.repeatChoice == .custom)
        model.details.title = "Planning"
        _ = try model.save(scope: .event)
        #expect(try fixture.store.series(id)?.rule == custom)

        let plain = editor(fixture)
        #expect(plain.repeatChoice == .never)
        plain.repeatChoice = .weekly
        #expect(plain.rule?.freq == .weekly)
        #expect(plain.repeatChoice == .weekly)
        plain.repeatChoice = .everyTwoWeeks
        #expect(plain.rule?.interval == 2)
        plain.repeatChoice = .custom
        #expect(plain.repeatChoice == .everyTwoWeeks, "custom is shown, never chosen")
    }

    @Test func peopleBecomeAttendees() throws {
        let fixture = try CalendarFixture()
        let model = editor(fixture)
        model.calendar = try fixture.calendar("Work").id
        model.details.title = "Planning"
        model.people = [Address(name: "Maja Ek", email: "maja.ek@example.org")]
        let id = try model.save(scope: .event)
        let saved = try #require(try fixture.store.series(id)?.base)
        #expect(saved.attendees.map(\.email) == ["maja.ek@example.org"])
        #expect(saved.attendees.first?.name == "Maja Ek")
        #expect(saved.organizer == "anna@example.org")
        #expect(try fixture.store.event(id, occurrence: nil)?.isEditable == true)

        let reopened = editor(fixture, editing: EventRequest(event: id, occurrence: nil))
        #expect(reopened.people.map(\.email) == ["maja.ek@example.org"])
    }

    @Test func aTappedReminderWaitsForTheEditor() throws {
        let fixture = try CalendarFixture()
        let app = fixture.app
        app.showNewEvent(day: fixture.at(day: 12, 0))
        #expect(app.eventEditor?.day == fixture.at(day: 12, 0))
        let request = EventRequest(event: EventID(raw: 1), occurrence: nil)
        app.showEvent(request)
        #expect(app.eventToShow == nil, "the event being written stays")
        app.eventEditor = nil
        app.openPending()
        #expect(app.eventToShow == request)
    }

    @Test func editingFromDetailsOpensOnceTheyHaveClosed() throws {
        let fixture = try CalendarFixture()
        let app = fixture.app
        let request = EventRequest(event: try fixture.timed("Planning", day: 10, 9), occurrence: nil)
        app.eventToShow = request
        app.edit(request, scope: .event)
        #expect(app.eventToShow == nil)
        #expect(app.eventEditor == nil, "not while the details are going")
        app.openPending()
        #expect(app.eventEditor?.editing == request)
    }

    /// A series in Stockholm at 9 from `day` with `rule`.
    private func plainSeries(_ fixture: CalendarFixture, day: Int, month: Int = 11, rule: RecurrenceRule) throws
        -> EventID {
        let zone = "Europe/Stockholm"
        var start = wall(day: day, 9)
        start.month = month
        var end = start
        end.hour = 10
        return try fixture.add(
            EventDetails(title: "Series", start: .zoned(start, zone: zone), end: .zoned(end, zone: zone)), rule: rule)
    }

    /// A series whose repeat Graph can't hold may not be moved into a Microsoft account's calendar; one
    /// it can hold may.
    /// A new event is never offered a calendar of an account this build cannot sync.
    @Test func anUnavailableAccountsCalendarsAreNotOffered() throws {
        let fixture = try CalendarFixture()
        var home = try #require(try fixture.store.accounts().first { $0.email == "home@example.org" })
        #expect(editor(fixture).writableCalendars.contains { $0.account.id == home.id })
        home.provider = ProviderID(raw: "gone")
        try fixture.store.save(home)
        fixture.app.reloadAccounts()
        #expect(!editor(fixture).writableCalendars.contains { $0.account.id == home.id })
    }

    @Test func aCustomRuleGraphCantHoldBlocksSaving() throws {
        let fixture = try CalendarFixture()
        var home = try #require(try fixture.store.accounts().first { $0.email == "home@example.org" })
        home.calendarVia = .graph
        try fixture.store.save(home)
        fixture.app.reloadAccounts()
        let hourly = try plainSeries(fixture, day: 10, rule: RecurrenceRule(freq: .hourly, interval: 4, count: 3))
        let model = editor(fixture, editing: EventRequest(event: hourly, occurrence: nil))
        #expect(!model.isOverLimits && model.canSave)
        model.calendar = try fixture.calendar("Family").id
        #expect(model.isOverLimits && !model.canSave)
        model.repeatChoice = .weekly
        #expect(!model.isOverLimits && model.canSave)
    }

    @Test func aWeeklySeriesMovedToAnotherDayRepeatsOnIt() throws {
        let fixture = try CalendarFixture()
        // Tuesdays, from Tuesday 10 November.
        let id = try plainSeries(fixture, day: 10, rule: RecurrenceRule(freq: .weekly, byDay: [WeekdayNum(weekday: 2)]))
        let model = editor(fixture, editing: try occurrence(fixture, id, day: 17))
        #expect(model.repeatChoice == .weekly)
        model.start = fixture.at(day: 18, 9)
        #expect(model.repeatChoice == .weekly, "still every week, now on Wednesdays")
        _ = try model.save(scope: .event)
        let week = try fixture.store.occurrences(from: fixture.at(day: 16, 0), to: fixture.at(day: 23, 0), in: nil)
        #expect(week.map(\.occurrence.start) == [fixture.at(day: 18, 9)])
    }

    @Test func aMonthlySeriesMovedToAnotherDateRepeatsOnIt() throws {
        let fixture = try CalendarFixture()
        let id = try plainSeries(fixture, day: 10, rule: RecurrenceRule(freq: .monthly, byMonthDay: [10]))
        let model = editor(fixture, editing: EventRequest(event: id, occurrence: nil))
        model.start = fixture.at(day: 12, 9)
        #expect(model.repeatChoice == .monthly)
        _ = try model.save(scope: .event)
        let saved = try #require(try fixture.store.series(id))
        #expect(saved.rule == RecurrenceRule(freq: .monthly))
        #expect(saved.base?.start == .zoned(wall(day: 12, 9), zone: "Europe/Stockholm"))
    }

    @Test func aCustomRuleIsKeptWhenTheSeriesMoves() throws {
        let fixture = try CalendarFixture()
        let custom = RecurrenceRule(freq: .weekly, byDay: [WeekdayNum(weekday: 2), WeekdayNum(weekday: 4)])
        let id = try plainSeries(fixture, day: 10, rule: custom)
        let model = editor(fixture, editing: EventRequest(event: id, occurrence: nil))
        model.start = fixture.at(day: 11, 9)
        _ = try model.save(scope: .event)
        #expect(try fixture.store.series(id)?.rule == custom)
    }

    /// A rule with parts the picker does not show (seconds, a calendar scale, a skip, unknown parts, a
    /// frequency under a day) is Custom, and moving the series leaves it exactly as it was.
    @Test func aRuleWithPartsThePickerDoesNotShowIsKeptOnAMove() throws {
        for text in ["FREQ=WEEKLY;BYDAY=TU;BYSECOND=30", "FREQ=MONTHLY;BYMONTHDAY=10;RSCALE=GREGORIAN",
                     "FREQ=MONTHLY;RSCALE=GREGORIAN;SKIP=BACKWARD", "FREQ=WEEKLY;X-OWN=kept",
                     "FREQ=HOURLY;INTERVAL=4;COUNT=3"] {
            let fixture = try CalendarFixture()
            let rule = try #require(RecurrenceRule.parse(text))
            let id = try plainSeries(fixture, day: 10, rule: rule)
            let model = editor(fixture, editing: EventRequest(event: id, occurrence: nil))
            #expect(model.repeatChoice == .custom, "\(text)")
            model.start = fixture.at(day: 12, 9)
            #expect(model.repeatChoice == .custom, "\(text)")
            _ = try model.save(scope: .event)
            #expect(try fixture.store.series(id)?.rule == rule, "\(text)")
        }
    }

    @Test func aRuleWithAnotherWeekStartIsCustom() throws {
        let fixture = try CalendarFixture()
        let id = try plainSeries(fixture, day: 10, rule: RecurrenceRule(freq: .weekly, weekStart: 7))
        #expect(editor(fixture, editing: EventRequest(event: id, occurrence: nil)).repeatChoice == .custom)
    }

    @Test func lateInTheEveningANewEventStartsAtMidnight() throws {
        let fixture = try CalendarFixture()
        let model = EventEditorModel(
            app: fixture.app, editing: nil, day: nil, calendar: phoneCalendar(), now: { fixture.at(day: 10, 23, 40) })
        #expect(model.start == fixture.at(day: 11, 0))
        #expect(model.end == fixture.at(day: 11, 0, 30))
    }

    @Test func aNewZoneKeepsTheHoursShown() throws {
        let fixture = try CalendarFixture()
        let model = EventEditorModel(
            app: fixture.app, editing: nil, day: nil, start: fixture.at(day: 10, 11), calendar: phoneCalendar(),
            now: { calendarNow })
        let newYork = try #require(TimeZone(identifier: "America/New_York"))
        model.zone = newYork
        #expect(model.details.start == .zoned(wall(day: 10, 11), zone: "America/New_York"))
        #expect(model.start == fixture.at(day: 10, 17), "11 in New York is 17 in Stockholm")
    }

    @Test func aTimedEventOverSeveralDaysBecomesThoseDays() throws {
        let fixture = try CalendarFixture()
        let model = editor(fixture)
        model.start = fixture.at(day: 10, 22)
        model.end = fixture.at(day: 12, 1)
        model.isAllDay = true
        #expect(model.details.start == .date(year: 2026, month: 11, day: 10))
        #expect(model.details.end == .date(year: 2026, month: 11, day: 13))
        #expect(model.end == fixture.at(day: 12, 0), "the last day shown is the 12th")
    }

    @Test func aSeriesMovedAcrossTheSummerTimeChangeKeepsItsClock() throws {
        let fixture = try CalendarFixture()
        // From 20 October (summer time) every day at 9.
        let id = try plainSeries(fixture, day: 20, month: 10, rule: RecurrenceRule(freq: .daily))
        let model = editor(fixture, editing: try occurrence(fixture, id, day: 12))
        model.start = fixture.at(day: 12, 10)
        _ = try model.save(scope: .event)
        var moved = wall(day: 20, 10)
        moved.month = 10
        #expect(try fixture.store.series(id)?.base?.start == .zoned(moved, zone: "Europe/Stockholm"))
    }

    @Test func aUTCOccurrenceMovedInAPickedZoneMovesTheSeriesByItsClock() throws {
        let fixture = try CalendarFixture()
        let zone = "Europe/Stockholm"
        var first = wall(day: 20, 9)
        first.month = 10
        var firstEnd = first
        firstEnd.hour = 10
        let base = EventDetails(title: "Series", start: .zoned(first, zone: zone), end: .zoned(firstEnd, zone: zone))
        // The 11 November occurrence moved to 9:30 and stored as UTC.
        var moved = base
        moved.start = .utc(fixture.at(day: 11, 9, 30))
        moved.end = .utc(fixture.at(day: 11, 10, 30))
        let cal = try fixture.calendar("Work")
        let window = CalendarWindow.window(now: calendarNow, zone: stockholm)
        try fixture.store.upsertRemote(
            href: "/cal/s.ics", etag: "1", ics: Data(),
            series: EventSeries(
                uid: "s", base: base, rule: RecurrenceRule(freq: .daily),
                overrides: [EventOverride(recurrenceID: .zoned(wall(day: 11, 9), zone: zone), details: moved)]),
            in: cal.id, window: window, phoneZone: stockholm, scheduleTag: nil)
        let found = try fixture.store.occurrences(from: fixture.at(day: 11, 0), to: fixture.at(day: 12, 0), in: nil)
        let request = EventRequest(try #require(found.first))
        let model = editor(fixture, editing: request)
        model.zone = try #require(TimeZone(identifier: "Europe/Berlin"))
        model.start = fixture.at(day: 11, 10, 30)
        _ = try model.save(scope: .event)
        // One hour later by the clock, from 9 on 20 October: 10 in Berlin, still summer time there.
        var expected = wall(day: 20, 10)
        expected.month = 10
        expected.minute = 0
        let saved = try #require(try fixture.store.series(request.event))
        #expect(saved.base?.start == .zoned(expected, zone: "Europe/Berlin"))
    }
    // MARK: Show as, private, length and repeat

    @Test func showAsAndPrivateAreSaved() throws {
        let fixture = try CalendarFixture()
        let model = editor(fixture)
        model.details.title = "Dentist"
        #expect(model.details.showAs == .busy && !model.details.isPrivate)
        model.details.showAs = .away
        model.details.isPrivate = true
        let id = try model.save(scope: .event)
        let saved = try #require(try fixture.store.series(id)?.base)
        #expect(saved.showAs == .away && saved.isPrivate)
    }

    @Test func theLengthMovesTheEnd() throws {
        let fixture = try CalendarFixture()
        let model = editor(fixture)
        #expect(model.durationMinutes == EventEditorModel.defaultMinutes)
        model.durationMinutes = 90
        #expect(model.end.timeIntervalSince(model.start) == 90 * 60)
        model.start = model.start.addingTimeInterval(3_600)
        #expect(model.durationMinutes == 90, "moving the start keeps the length")
    }

    @Test func weekdayPresetIsMOtoFR() throws {
        let fixture = try CalendarFixture()
        let model = editor(fixture)
        model.repeatChoice = .weekdays
        let rule = try #require(model.rule)
        #expect(rule.freq == .weekly && rule.interval == 1)
        #expect(rule.byDay.map(\.weekday) == [1, 2, 3, 4, 5] && rule.byDay.allSatisfy { $0.ordinal == 0 })
        #expect(model.repeatChoice == .weekdays)
        model.details.title = "Stand-up"
        let id = try model.save(scope: .event)
        // Tuesday 10 November to Tuesday 17 November: five weekdays, no weekend.
        let days = try fixture.store.occurrences(from: fixture.at(day: 11, 0), to: fixture.at(day: 18, 0), in: nil)
            .filter { $0.id == id }
        #expect(days.count == 5)
        #expect(days.allSatisfy { !phoneCalendar().isDateInWeekend($0.occurrence.start) })
    }

    @Test func untilRuleIsEditable() throws {
        let fixture = try CalendarFixture()
        let until = EventTime.utc(fixture.at(day: 30, 23, 59))
        let id = try plainSeries(
            fixture, day: 10, rule: RecurrenceRule(freq: .weekly, until: until, byDay: [WeekdayNum(weekday: 2)]))
        let model = editor(fixture, editing: EventRequest(event: id, occurrence: nil))
        var custom = try #require(model.customRepeat)
        #expect(custom.frequency == .weekly && custom.interval == 1 && custom.weekdays == [2])
        guard case let .onDay(day) = custom.end else {
            Issue.record("an UNTIL rule ends on its date")
            return
        }
        #expect(phoneCalendar().isDate(day, inSameDayAs: fixture.at(day: 30, 12)))
        custom.end = .after(5)
        custom.interval = 2
        custom.weekdays = [2, 4]
        model.customRepeat = custom
        _ = try model.save(scope: .event)
        let rule = try #require(try fixture.store.series(id)?.rule)
        #expect(rule.freq == .weekly && rule.interval == 2 && rule.count == 5 && rule.until == nil)
        #expect(rule.byDay.map(\.weekday) == [2, 4])
    }

    @Test func aCustomEndOnADateEndsThatDay() throws {
        let fixture = try CalendarFixture()
        let model = editor(fixture)
        model.details.title = "Course"
        var custom = try #require(model.customRepeat)
        custom.frequency = .daily
        custom.end = .onDay(fixture.at(day: 12, 0))
        model.customRepeat = custom
        let id = try model.save(scope: .event)
        let days = try fixture.store.occurrences(from: fixture.at(day: 10, 0), to: fixture.at(day: 20, 0), in: nil)
            .filter { $0.id == id }
        #expect(days.count == 3, "the 10th, the 11th and the 12th")
    }

    @Test func monthlyByWeekdayIsTheStartsWeekdayOfTheMonth() throws {
        let fixture = try CalendarFixture()
        // Tuesday 10 November is the second Tuesday.
        let id = try plainSeries(fixture, day: 10, rule: RecurrenceRule(freq: .monthly))
        let model = editor(fixture, editing: EventRequest(event: id, occurrence: nil))
        var custom = try #require(model.customRepeat)
        #expect(custom.frequency == .monthly && custom.monthlyBy == .date)
        custom.monthlyBy = .weekday
        model.customRepeat = custom
        _ = try model.save(scope: .event)
        let rule = try #require(try fixture.store.series(id)?.rule)
        #expect(rule.byDay == [WeekdayNum(weekday: 2, ordinal: 2)])
        let reopened = editor(fixture, editing: EventRequest(event: id, occurrence: nil))
        #expect(reopened.customRepeat?.monthlyBy == .weekday)
    }

    @Test func aRuleTheCustomScreenCantShowIsNotOpenedInIt() throws {
        let fixture = try CalendarFixture()
        let id = try plainSeries(fixture, day: 10, rule: RecurrenceRule(freq: .hourly, interval: 4, count: 3))
        #expect(editor(fixture, editing: EventRequest(event: id, occurrence: nil)).customRepeat == nil)
    }
    @Test func openingCustomAndBackingOutLeavesTheEventNotRepeating() throws {
        let fixture = try CalendarFixture()
        let model = editor(fixture)
        model.details.title = "Once"
        // The custom screen opens on its pattern; nothing is changed on it.
        #expect(model.openCustom()?.frequency == .weekly)
        #expect(model.rule == nil && model.repeatChoice == .never)
        let id = try model.save(scope: .event)
        #expect(try fixture.store.series(id)?.rule == nil)
    }

    @Test func aCustomPatternFollowsTheStart() throws {
        let fixture = try CalendarFixture()
        // Tuesday 10 November is the second Tuesday.
        let id = try plainSeries(
            fixture, day: 10, rule: RecurrenceRule(freq: .monthly, count: 6, byDay: [WeekdayNum(weekday: 2, ordinal: 2)]))
        let model = editor(fixture, editing: EventRequest(event: id, occurrence: nil))
        #expect(model.repeatChoice == .custom)
        // Wednesday 18 November is the third Wednesday.
        model.start = fixture.at(day: 18, 9)
        #expect(model.customRepeat?.monthlyBy == .weekday)
        _ = try model.save(scope: .event)
        let rule = try #require(try fixture.store.series(id)?.rule)
        #expect(rule.byDay == [WeekdayNum(weekday: 3, ordinal: 3)] && rule.count == 6)
    }

    @Test func aLengthOutOfRangeIsClampedNotATrap() {
        #expect(EventEditorModel.lengthMinutes(.infinity) == EventEditorModel.maxMinutes)
        #expect(EventEditorModel.lengthMinutes(-.infinity) == 0)
        #expect(EventEditorModel.lengthMinutes(.nan) == 0)
        #expect(EventEditorModel.lengthMinutes(1e300) == EventEditorModel.maxMinutes)
        #expect(EventEditorModel.lengthMinutes(-300) == 0)
        #expect(EventEditorModel.lengthMinutes(5_400) == 90)
    }

    @Test func aHugeEventStillHasALength() throws {
        let fixture = try CalendarFixture()
        let model = editor(fixture)
        // Further than the calendar reads: no trap, and a length within the bounds.
        model.details.end = .utc(Date(timeIntervalSinceReferenceDate: 1e300))
        #expect((0...EventEditorModel.maxMinutes).contains(model.durationMinutes))
    }
}
