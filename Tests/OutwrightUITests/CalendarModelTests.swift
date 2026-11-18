// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightModel
@testable import OutwrightStore
import OutwrightSync
import Testing

@testable import OutwrightUI

let stockholm = TimeZone(identifier: "Europe/Stockholm") ?? .gmt

/// A Gregorian calendar in Stockholm with the given locale.
func phoneCalendar(_ locale: String = "sv_SE") -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = stockholm
    calendar.locale = Locale(identifier: locale)
    return calendar
}

/// Tuesday 10 November 2026, 10:30 in Stockholm.
let calendarNow: Date = phoneCalendar().date(
    from: DateComponents(year: 2026, month: 11, day: 10, hour: 10, minute: 30)) ?? .distantPast

/// A store with an account `anna@example.org` that has the calendars "Work" and "Home", and
/// `home@example.org` with "Family"; events are added as the server would give them.
@MainActor
struct CalendarFixture {
    let box: Mailbox
    let app: AppModel
    let calendars: [CalendarInfo]
    let reminders: KeptReminders
    var store: MailStore { box.store }

    init(withCalendars: Bool = true, remindersAllowed: Bool = true) throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org", calDAV: true)
        let home = try box.addAccount("home@example.org", calDAV: true)
        if withCalendars {
            try box.store.replaceCalendars(
                [(href: "/cal/work/", name: "Work", color: 0x2F6FDB, isReadOnly: false),
                 (href: "/cal/home/", name: "Home", color: 0xD9534F, isReadOnly: false)], for: anna.id)
            try box.store.replaceCalendars(
                [(href: "/cal/family/", name: "Family", color: nil, isReadOnly: false)], for: home.id)
        }
        self.box = box
        calendars = try box.store.allCalendars()
        let reminders = KeptReminders(allowed: remindersAllowed)
        self.reminders = reminders
        app = AppModel(
            store: box.store, sync: offlineSync(store: box.store, secrets: InMemorySecretStore(), reminders: reminders))
    }

    func calendar(_ name: String) throws -> CalendarInfo {
        try #require(calendars.first { $0.name == name })
    }

    /// The instant of a wall time in Stockholm on November `day` 2026.
    func at(day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        phoneCalendar().date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))
            ?? .distantPast
    }

    @discardableResult
    func add(
        _ details: EventDetails, rule: RecurrenceRule? = nil, in calendarName: String = "Work",
        uid: String = UUID().uuidString, ics: Data = Data()
    ) throws -> EventID {
        let cal = try calendar(calendarName)
        let window = CalendarWindow.window(now: calendarNow, zone: stockholm)
        try store.upsertRemote(
            href: "/cal/\(uid).ics", etag: "1", ics: ics, series: EventSeries(uid: uid, base: details, rule: rule),
            in: cal.id, window: window, phoneZone: stockholm, scheduleTag: nil)
        let found = try store.occurrences(from: window.lowerBound, to: window.upperBound, in: [cal.id])
        return try #require(found.first { $0.occurrence.details.title == details.title }?.id)
    }

    @discardableResult
    func timed(
        _ title: String, day: Int, _ hour: Int, _ minute: Int = 0, minutes: Int = 60, in calendarName: String = "Work"
    ) throws -> EventID {
        let start = at(day: day, hour, minute)
        return try add(
            EventDetails(title: title, start: .utc(start), end: .utc(start.addingTimeInterval(Double(minutes) * 60))),
            in: calendarName)
    }

    @discardableResult
    func allDay(_ title: String, day: Int, days: Int = 1, in calendarName: String = "Work") throws -> EventID {
        try add(
            EventDetails(
                title: title, start: .date(year: 2026, month: 11, day: day),
                end: .date(year: 2026, month: 11, day: day + days)),
            in: calendarName)
    }

    /// A calendar model over defaults of its own (`defaults` to share them with another).
    func model(
        _ locale: String = "sv_SE", now: @escaping () -> Date = { calendarNow }, defaults: UserDefaults = freshDefaults()
    ) -> CalendarModel {
        let model = CalendarModel(app: app, calendar: phoneCalendar(locale), now: now, defaults: defaults)
        model.reload()
        return model
    }
}

/// Empty defaults of a suite of their own.
func freshDefaults() -> UserDefaults {
    UserDefaults(suiteName: "test.\(UUID().uuidString)") ?? .standard
}

/// A clock a test moves on.
@MainActor final class TestClock {
    var now = calendarNow
}

/// The instant of a UTC wall time.
func utcTime(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC") ?? .gmt
    return utc.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))
        ?? .distantPast
}

@MainActor @Suite struct CalendarModelTests {
    @Test func filterShowsSubscriptionFailure() throws {
        let fixture = try CalendarFixture()
        let cal = try fixture.store.addSubscription(key: UUID(), host: "example.org", name: "Published", color: nil)
        try fixture.store.setSubscriptionFailure(cal, .unpublished, at: calendarNow)
        let model = fixture.model()
        #expect(model.subscriptionFailures == [cal: .unpublished])
        #expect(model.subscribedCalendars.map(\.id) == [cal])
    }

    @Test func subscribedCalendarsAreAGroupOfTheirOwn() throws {
        let fixture = try CalendarFixture()
        let cal = try fixture.store.addSubscription(key: UUID(), host: "example.org", name: "Published", color: nil)
        let model = fixture.model()
        #expect(!model.calendarGroups.contains { group in group.calendars.contains { $0.id == cal } })
        #expect(model.subscribedCalendars.map(\.id) == [cal])
        #expect(model.color(of: cal) != 0x8A8F98)
    }

    @Test func anAddedSubscriptionIsShownUnderAFilter() throws {
        let fixture = try CalendarFixture()
        let model = fixture.model()
        model.shownCalendars = []
        let cal = try fixture.store.addSubscription(key: UUID(), host: "example.org", name: "Published", color: nil)
        model.added(cal)
        #expect(model.shownCalendars == [cal])
        #expect(model.subscribedCalendars.map(\.id) == [cal])
    }

    @Test func opensOnTodayInThreeDay() throws {
        let fixture = try CalendarFixture()
        let model = fixture.model()
        #expect(model.mode == .threeDay)
        #expect(model.anchorDay == fixture.at(day: 10, 0))
        #expect(model.days.map(\.day) == [fixture.at(day: 10, 0), fixture.at(day: 11, 0), fixture.at(day: 12, 0)])
    }

    @Test func dayColumnsHoldAllDayAndTimed() throws {
        let fixture = try CalendarFixture()
        try fixture.allDay("Conference", day: 10)
        try fixture.allDay("Trip", day: 11, days: 2)
        try fixture.timed("Stand-up", day: 10, 9)
        try fixture.timed("Lunch", day: 11, 12)
        try fixture.timed("Late", day: 9, 23, minutes: 120)
        let model = fixture.model()
        let titles = model.days.map { day in
            (day.allDay.map(\.occurrence.details.title), day.timed.map(\.event.occurrence.details.title))
        }
        #expect(titles.map(\.0) == [["Conference"], ["Trip"], ["Trip"]])
        #expect(titles.map(\.1) == [["Late", "Stand-up"], ["Lunch"], []])
    }

    /// An all-day event over several days is one bar across them, in the first lane free on all of them.
    @Test func multiDayAllDayEventsAreOneBar() throws {
        let fixture = try CalendarFixture()
        try fixture.allDay("Conference", day: 10)
        try fixture.allDay("Trip", day: 11, days: 2)
        try fixture.allDay("Fair", day: 10, days: 2)
        let model = fixture.model()
        let bars = AllDayLayout.bars(model.days).map {
            [$0.event.occurrence.details.title, "\($0.first)-\($0.last)", "\($0.lane)"]
        }
        // The longer bar first, on top.
        #expect(bars == [["Fair", "0-1", "0"], ["Conference", "0-0", "1"], ["Trip", "1-2", "1"]])
    }

    @Test func overlappingEventsShareWidth() throws {
        let fixture = try CalendarFixture()
        try fixture.timed("A", day: 10, 9)
        try fixture.timed("B", day: 10, 9, 30)
        try fixture.timed("C", day: 10, 11)
        try fixture.timed("D", day: 10, 9, 15, minutes: 30, in: "Home")
        let model = fixture.model()
        let placed = try #require(model.days.first).timed
        let layout = Dictionary(
            uniqueKeysWithValues: placed.map { ($0.event.occurrence.details.title, [$0.column, $0.columns]) })
        #expect(layout["A"] == [0, 3])
        #expect(layout["D"] == [1, 3])
        #expect(layout["B"] == [2, 3])
        #expect(layout["C"] == [0, 1])
    }

    @Test func filterHidesCalendars() throws {
        let fixture = try CalendarFixture()
        try fixture.timed("Work thing", day: 10, 9)
        try fixture.timed("Home thing", day: 10, 11, in: "Home")
        try fixture.timed("Family thing", day: 10, 13, in: "Family")
        let model = fixture.model()
        #expect(model.calendarGroups.map(\.account.email) == ["anna@example.org", "home@example.org"])
        #expect(model.calendarGroups.map { $0.calendars.map(\.name) } == [["Home", "Work"], ["Family"]])
        #expect(model.days.first?.timed.count == 3)
        model.shownCalendars = [try fixture.calendar("Work").id, try fixture.calendar("Family").id]
        #expect(model.days.first?.timed.map(\.event.occurrence.details.title) == ["Work thing", "Family thing"])
        model.shownCalendars = nil
        #expect(model.days.first?.timed.count == 3)
    }

    @Test func moveAndTodayChangeTheAnchor() throws {
        let fixture = try CalendarFixture()
        let model = fixture.model()
        model.move(by: 1)
        #expect(model.anchorDay == fixture.at(day: 11, 0))
        #expect(model.days.first?.day == fixture.at(day: 11, 0))
        model.move(by: -3)
        #expect(model.anchorDay == fixture.at(day: 8, 0))
        model.goToToday()
        #expect(model.anchorDay == fixture.at(day: 10, 0))
        model.mode = .month
        model.step(1)
        #expect(phoneCalendar().dateComponents([.month, .day], from: model.anchorDay) == DateComponents(month: 12, day: 10))
        model.mode = .threeDay
        model.step(-1)
        #expect(phoneCalendar().dateComponents([.month, .day], from: model.anchorDay) == DateComponents(month: 12, day: 9))
    }

    @Test func weekStartsOnLocaleFirstWeekday() throws {
        let fixture = try CalendarFixture()
        for (locale, weekday) in [("sv_SE", 2), ("en_US", 1)] {
            let model = fixture.model(locale)
            model.mode = .month
            let calendar = phoneCalendar(locale)
            let first = try #require(model.days.first?.day)
            #expect(calendar.component(.weekday, from: first) == weekday)
            #expect(model.days.count % 7 == 0)
            #expect(model.days.contains { $0.day == fixture.at(day: 1, 0) })
            #expect(model.days.contains { $0.day == fixture.at(day: 30, 0) })
            #expect(model.weekdaySymbols.first == calendar.veryShortStandaloneWeekdaySymbols[weekday - 1])
        }
    }

    @Test func monthTitleFollowsAnchor() throws {
        let fixture = try CalendarFixture()
        let model = fixture.model("en_US")
        let months = phoneCalendar("en_US").standaloneMonthSymbols
        #expect(model.monthTitle.contains(months[10]))
        #expect(!model.monthTitle.contains("2026"), "the current year is left out")
        model.move(by: 25)
        #expect(model.monthTitle.contains(months[11]))
        #expect(!model.monthTitle.contains("2026"))
        model.move(by: -400)
        #expect(model.monthTitle.contains("2025"), "another year is shown")
    }

    @Test func monthTitleOmitsTheCurrentYear() throws {
        let fixture = try CalendarFixture()
        let model = fixture.model("en_US")
        #expect(model.monthTitle == "November")
        model.move(by: 60)
        #expect(model.monthTitle.contains("January") && model.monthTitle.contains("2027"))
    }

    /// The agenda is one list around today, a month each way, that grows at whichever end is reached.
    @Test func agendaExtendsBothWays() throws {
        let fixture = try CalendarFixture()
        let model = fixture.model()
        model.mode = .agenda
        let today = fixture.at(day: 10, 0)
        let day = { (offset: Int) in phoneCalendar().date(byAdding: .day, value: offset, to: today) ?? today }
        #expect(model.agendaRange == day(-30)...day(30))
        #expect(model.days.first?.day == day(-30))
        #expect(model.days.last?.day == day(30))
        model.extendAgenda(.top)
        #expect(model.days.first?.day == day(-60))
        #expect(model.days.last?.day == day(30))
        model.extendAgenda(.bottom)
        // 121 days would be one past the window: the first lets go.
        #expect(model.days.first?.day == day(-59))
        #expect(model.days.last?.day == day(60))
        // A day chosen outside the list starts a new one around it.
        model.anchorDay = day(200)
        #expect(model.agendaRange == day(170)...day(230))
    }

    @Test func agendaKeepsEmptyDays() throws {
        let fixture = try CalendarFixture()
        try fixture.timed("Dentist", day: 13, 8)
        let model = fixture.model()
        model.mode = .agenda
        #expect(model.days.count == 61)
        let shown = Dictionary(uniqueKeysWithValues: model.days.map { ($0.day, $0) })
        #expect(shown[fixture.at(day: 10, 0)]?.isEmpty == true)
        #expect(shown[fixture.at(day: 11, 0)]?.isEmpty == true)
        #expect(shown[fixture.at(day: 13, 0)]?.timed.map(\.event.occurrence.details.title) == ["Dentist"])
    }

    @Test func tappedSlotRoundsDownToHalfHour() throws {
        let fixture = try CalendarFixture()
        let model = fixture.model()
        #expect(model.slot(on: fixture.at(day: 12, 0), minute: 10 * 60 + 47) == fixture.at(day: 12, 10, 30))
        #expect(model.slot(on: fixture.at(day: 12, 0), minute: 10 * 60 + 29) == fixture.at(day: 12, 10))
        #expect(model.slot(on: fixture.at(day: 12, 0), minute: -5) == fixture.at(day: 12, 0))
        #expect(model.slot(on: fixture.at(day: 12, 0), minute: 24 * 60 + 9) == fixture.at(day: 12, 23, 30))
        let calendar = phoneCalendar()
        // 02:30 on the spring day doesn't exist: the slot is the first time after the gap, 03:00 summer time.
        let spring = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 29)))
        #expect(model.slot(on: spring, minute: 150) == utcTime(2026, 3, 29, 1, 0))
        // 02:30 on the autumn day comes twice: the first, in summer time.
        let autumn = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 25)))
        #expect(model.slot(on: autumn, minute: 150) == utcTime(2026, 10, 25, 0, 30))
    }

    /// A kept choice of calendars that no longer exist is dropped: the calendar shows every calendar.
    @Test func aChosenCalendarThatWentIsForgotten() throws {
        let fixture = try CalendarFixture()
        try fixture.timed("Family thing", day: 10, 13, in: "Family")
        let defaults = freshDefaults()
        fixture.model(defaults: defaults).shownCalendars = [try fixture.calendar("Home").id]
        try fixture.store.replaceCalendars(
            [(href: "/cal/work/", name: "Work", color: 0x2F6FDB, isReadOnly: false)],
            for: try #require(fixture.app.accounts.first { $0.email == "anna@example.org" }).id)
        let again = fixture.model(defaults: defaults)
        #expect(again.shownCalendars == nil)
        #expect(again.days.first?.timed.map(\.event.occurrence.details.title) == ["Family thing"])
        #expect(defaults.object(forKey: SettingsKeys.shownCalendars) == nil)
    }

    /// The agenda holds at most a window of days: growing at one end lets go of the other, and it
    /// stops at its furthest reach.
    @Test func agendaSlidesAndStopsAtItsReach() throws {
        let fixture = try CalendarFixture()
        try fixture.timed("Dentist", day: 13, 8)
        let model = fixture.model()
        model.mode = .agenda
        let calendar = phoneCalendar()
        let span = {
            calendar.dateComponents([.day], from: model.agendaRange.lowerBound, to: model.agendaRange.upperBound).day ?? 0
        }
        for _ in 0..<5 { model.extendAgenda(.bottom) }
        #expect(span() + 1 <= CalendarModel.agendaWindow)
        #expect(model.days.count == span() + 1)
        #expect(model.days.first?.day == model.agendaRange.lowerBound)
        #expect(model.days.last?.day == model.agendaRange.upperBound)
        for _ in 0..<5 { model.extendAgenda(.top) }
        #expect(span() + 1 <= CalendarModel.agendaWindow)
        #expect(model.days.first { $0.day == fixture.at(day: 13, 0) }?.timed.count == 1, "spliced days hold their events")
        for _ in 0..<200 { model.extendAgenda(.bottom) }
        let reach = calendar.date(byAdding: .day, value: CalendarModel.agendaReach, to: fixture.at(day: 10, 0))
        #expect(model.agendaRange.upperBound == reach)
        #expect(span() + 1 <= CalendarModel.agendaWindow)
    }

    /// The month opened under the title is read once, and again when the store changes.
    @Test func theMiniMonthIsReadWhenItOpensAndWhenTheStoreChanges() throws {
        let fixture = try CalendarFixture()
        let model = fixture.model()
        model.showsMiniMonth = true
        model.stepMiniMonth(1)
        #expect(phoneCalendar().component(.month, from: model.miniMonth) == 12)
        let december = { (day: Int) in
            phoneCalendar().date(from: DateComponents(year: 2026, month: 12, day: day)) ?? .distantPast
        }
        #expect(model.miniMonthDays.contains { $0.day == december(24) })
        try fixture.add(EventDetails(
            title: "Eve", start: .date(year: 2026, month: 12, day: 24), end: .date(year: 2026, month: 12, day: 25)))
        model.reload()
        #expect(model.miniMonthDays.first { $0.day == december(24) }?.allDay.count == 1)
    }

    @Test func viewAndCalendarsSurviveRelaunch() throws {
        let fixture = try CalendarFixture()
        let defaults = freshDefaults()
        let first = fixture.model(defaults: defaults)
        let work = try fixture.calendar("Work").id
        first.mode = .agenda
        first.weekMode = .workWeek
        first.shownCalendars = [work]
        let again = fixture.model(defaults: defaults)
        #expect(again.mode == .agenda)
        #expect(again.weekMode == .workWeek)
        #expect(again.shownCalendars == [work])
        first.shownCalendars = nil
        #expect(fixture.model(defaults: defaults).shownCalendars == nil)
    }

    /// A view and week stored after the model exists (a restored setup) are followed at once; a
    /// launch argument's view stays until the stored view changes.
    @Test func theCalendarFollowsARestoredView() async throws {
        let fixture = try CalendarFixture()
        let defaults = freshDefaults()
        defaults.set(CalendarMode.month.rawValue, forKey: SettingsKeys.calendarMode)
        fixture.app.initialCalendarMode = .agenda
        let model = fixture.model(defaults: defaults)
        let watch = Task { await model.observeSettings() }
        defaults.set(true, forKey: "somethingElse")
        // What a change to another setting makes the model do, done here before the check.
        model.followStoredSettings()
        #expect(model.mode == .agenda)
        defaults.set(CalendarMode.day.rawValue, forKey: SettingsKeys.calendarMode)
        // Once the day shows, the watch has read the stored settings and listens for changes.
        let day = await eventually { model.mode == .day }
        // Only a delivered change notice brings this one in.
        defaults.set(WeekMode.workWeek.rawValue, forKey: SettingsKeys.calendarWeekMode)
        let workWeek = await eventually { model.weekMode == .workWeek }
        watch.cancel()
        #expect(day)
        #expect(workWeek)
    }

    /// On a wide screen with nothing stored, a restored week is a chosen view: turning the screen
    /// narrow keeps it instead of going back to the narrow default.
    @Test func aRestoredWeekOnAWideScreenStaysChosen() throws {
        let fixture = try CalendarFixture()
        let defaults = freshDefaults()
        let model = fixture.model(defaults: defaults)
        model.isRegularWidth = true
        #expect(model.mode == .week)
        defaults.set(CalendarMode.week.rawValue, forKey: SettingsKeys.calendarMode)
        model.followStoredSettings()
        model.isRegularWidth = false
        #expect(model.mode == .week)
    }

    /// The permission is asked when the first reminder is to be scheduled, never because the tab opened.
    @Test func permissionIsAskedWhenTheFirstReminderIsScheduled() async throws {
        let fixture = try CalendarFixture(remindersAllowed: false)
        await fixture.app.sync.rescheduleReminders()
        #expect(await fixture.reminders.questions == 0, "nothing to schedule, nothing to ask")
        let soon = Date().addingTimeInterval(86_400)
        try fixture.add(
            EventDetails(title: "Soon", start: .utc(soon), end: .utc(soon.addingTimeInterval(3_600)), reminder: 15))
        await fixture.app.sync.rescheduleReminders()
        #expect(await fixture.reminders.questions == 1)
    }

    /// A subscribed calendar alone is shown, but nothing can be added to it.
    @Test func subscriptionAloneAddsNothing() throws {
        let bare = try CalendarFixture(withCalendars: false)
        _ = try bare.store.addSubscription(key: UUID(), host: "example.org", name: "Work", color: nil)
        let model = bare.model()
        #expect(model.hasCalendars)
        #expect(!model.canAddEvents)
        #expect(try CalendarFixture().model().canAddEvents)
    }

    @Test func anchorFollowsTodayOverMidnight() throws {
        let fixture = try CalendarFixture()
        let clock = TestClock()
        let model = fixture.model(now: { clock.now })
        let scrolls = model.nowScrolls
        clock.now = fixture.at(day: 11, 0, 30)
        model.reload()
        #expect(model.anchorDay == fixture.at(day: 11, 0))
        #expect(model.days.first?.day == fixture.at(day: 11, 0))
        #expect(model.nowScrolls > scrolls, "the grid goes back to now")

        model.move(by: 2)
        clock.now = fixture.at(day: 12, 7)
        model.reload()
        #expect(model.anchorDay == fixture.at(day: 13, 0), "a day the owner moved to stays")
    }

    @Test func returningToTheFrontFindsToday() throws {
        let fixture = try CalendarFixture()
        let clock = TestClock()
        let model = fixture.model(now: { clock.now })
        clock.now = fixture.at(day: 11, 7)
        let scrolls = model.nowScrolls
        model.sceneBecameActive()
        #expect(model.anchorDay == fixture.at(day: 11, 0))
        #expect(model.nowScrolls > scrolls)
    }

    @Test func todayIsTheAppsClock() throws {
        let fixture = try CalendarFixture()
        let clock = TestClock()
        clock.now = fixture.at(day: 12, 23, 57)
        fixture.app.now = { clock.now }
        let model = CalendarModel(app: fixture.app, calendar: phoneCalendar(), defaults: freshDefaults())
        #expect(model.anchorDay == fixture.at(day: 12, 0))
        clock.now = fixture.at(day: 13, 0, 3)
        model.sceneBecameActive()
        #expect(model.anchorDay == fixture.at(day: 13, 0), "the app's clock passed midnight")
    }

    @Test func firstFrameIsAlreadyRead() throws {
        let fixture = try CalendarFixture()
        try fixture.timed("Dentist", day: 13, 8)
        fixture.app.initialCalendarMode = .agenda
        let model = CalendarModel(
            app: fixture.app, calendar: phoneCalendar(), now: { calendarNow }, defaults: freshDefaults())
        #expect(model.days.contains { $0.day == fixture.at(day: 13, 0) && !$0.isEmpty })
        #expect(!model.calendarGroups.isEmpty)
        fixture.app.initialCalendarMode = .threeDay
        let grid = CalendarModel(
            app: fixture.app, calendar: phoneCalendar(), now: { calendarNow }, defaults: freshDefaults())
        #expect(grid.days.count == 3)
    }

    @Test func wallMinutesOnClockChangeDays() throws {
        let fixture = try CalendarFixture()
        let model = fixture.model()
        let calendar = phoneCalendar()
        let autumn = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 25)))
        // 02:30 summer time, then 02:30 winter time an hour later: the same line on the grid.
        #expect(model.minutes(of: utcTime(2026, 10, 25, 0, 30), on: autumn) == 150)
        #expect(model.minutes(of: utcTime(2026, 10, 25, 1, 30), on: autumn) == 150)
        #expect(model.minutes(of: utcTime(2026, 10, 25, 22), on: autumn) == 23 * 60)
        let spring = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 29)))
        #expect(model.minutes(of: utcTime(2026, 3, 29, 0, 59), on: spring) == 60 + 59)
        #expect(model.minutes(of: utcTime(2026, 3, 29, 1, 30), on: spring) == 3 * 60 + 30)
        #expect(model.minutes(of: utcTime(2026, 3, 28, 20), on: spring) == 0, "before the day: its top")
        #expect(model.minutes(of: utcTime(2026, 3, 30, 1), on: spring) == 24 * 60, "after the day: its bottom")
    }

    @Test func repeatedHourEventsGetTheirOwnColumns() throws {
        let fixture = try CalendarFixture()
        for (title, hour) in [("Summer time", 0), ("Winter time", 1)] {
            let start = utcTime(2026, 10, 25, hour)
            try fixture.add(EventDetails(title: title, start: .utc(start), end: .utc(start.addingTimeInterval(1_800))))
        }
        let model = fixture.model()
        model.mode = .day
        model.anchorDay = utcTime(2026, 10, 25, 12)
        let placed = try #require(model.days.first).timed
        #expect(placed.count == 2)
        #expect(Set(placed.map(\.column)) == [0, 1])
        #expect(placed.allSatisfy { $0.columns == 2 })
    }

    @Test func hourLabelsNeverRepeatOnAClockChangeDay() throws {
        let fixture = try CalendarFixture()
        let model = fixture.model()
        for day in [utcTime(2026, 3, 29, 12), utcTime(2026, 10, 25, 12)] {
            model.anchorDay = day
            let labels = (1..<24).map(model.hourLabel)
            #expect(Set(labels).count == 23)
        }
    }

    @Test func refusedEventsAreCountedPerCalendar() throws {
        let fixture = try CalendarFixture()
        let work = try fixture.calendar("Work")
        try fixture.store.setSkippedEvent(href: "/cal/work/a.ics", etag: "1", refused: true, in: work.id)
        try fixture.store.setSkippedEvent(href: "/cal/work/b.ics", etag: "1", refused: true, in: work.id)
        try fixture.store.setSkippedEvent(href: "/cal/work/c.ics", etag: "1", refused: false, in: work.id)
        let model = fixture.model()
        #expect(model.refusedCounts == [work.id: 2])
    }

    @Test func reminderTapWaitsForComposeAndClosesAPersonCard() throws {
        let fixture = try CalendarFixture()
        let app = fixture.app
        let request = EventRequest(event: EventID(raw: 1), occurrence: nil)
        app.compose(.new)
        app.showEvent(request)
        #expect(app.eventToShow == nil, "a sheet can't open over compose")
        #expect(app.composeRequest != nil, "the mail being written stays")
        app.composeRequest = nil
        app.openPending()
        #expect(app.eventToShow == request)

        app.eventToShow = nil
        app.personToShow = PersonRequest(contact: ContactID(raw: 1))
        app.showEvent(request)
        #expect(app.personToShow == nil, "the person card closes")
        app.openPending()
        #expect(app.eventToShow == request)
        #expect(app.selectedTab == .calendar)
    }

    @Test func bannerGoesWhenReadingWorksAgain() throws {
        let fixture = try CalendarFixture()
        let model = fixture.model()
        try fixture.store.write { try $0.execute(sql: "ALTER TABLE occurrence RENAME TO occurrence_away") }
        model.move(by: 1)
        #expect(model.failed)
        try fixture.store.write { try $0.execute(sql: "ALTER TABLE occurrence_away RENAME TO occurrence") }
        model.move(by: 1)
        #expect(!model.failed, "a read that works again clears the banner")
    }

    /// A month that could not be read stops showing the banner once it is closed.
    @Test func closingTheMonthClearsItsFailure() throws {
        let fixture = try CalendarFixture()
        let model = fixture.model()
        model.showsMiniMonth = true
        try fixture.store.write { try $0.execute(sql: "ALTER TABLE occurrence RENAME TO occurrence_away") }
        model.stepMiniMonth(1)
        #expect(model.failed)
        try fixture.store.write { try $0.execute(sql: "ALTER TABLE occurrence_away RENAME TO occurrence") }
        model.showsMiniMonth = false
        #expect(!model.failed)
    }

    @Test func titleAndDayFollowAZoneChange() throws {
        let fixture = try CalendarFixture()
        let model = fixture.model("en_US")
        model.anchorDay = fixture.at(day: 1, 12)
        // Far east: 1 November starts while it is still 31 October in Stockholm.
        let far = try #require(TimeZone(identifier: "Pacific/Kiritimati"))
        model.calendar.timeZone = far
        model.reload()
        var there = phoneCalendar("en_US")
        there.timeZone = far
        #expect(there.dateComponents([.month, .day], from: model.anchorDay) == DateComponents(month: 11, day: 1))
        #expect(model.monthTitle.contains(there.standaloneMonthSymbols[10]))
        // Far west: the chosen day stays the chosen day, not the evening before.
        let west = try #require(TimeZone(identifier: "America/New_York"))
        model.calendar.timeZone = west
        model.reload()
        there.timeZone = west
        #expect(there.dateComponents([.month, .day], from: model.anchorDay) == DateComponents(month: 11, day: 1))
    }

    @Test func sheetsWithNothingUnsavedCloseForAReminder() throws {
        let fixture = try CalendarFixture()
        let app = fixture.app
        let request = EventRequest(event: EventID(raw: 1), occurrence: nil)
        let filter = UUID()
        app.localSheet(filter, isOpen: true)
        let closes = app.localSheetCloses
        app.showEvent(request)
        #expect(app.eventToShow == nil, "not over the open filter")
        #expect(app.localSheetCloses > closes, "the filter is asked to close")
        app.localSheet(filter, isOpen: false)
        app.openPending()
        #expect(app.eventToShow == request)
    }

    @Test func todayStaysTodayAfterAZoneChange() throws {
        let fixture = try CalendarFixture()
        let clock = TestClock()
        // 1 November 02:00 in Stockholm is 31 October 20:00 in New York.
        clock.now = fixture.at(day: 1, 2)
        let model = fixture.model("en_US", now: { clock.now })
        let west = try #require(TimeZone(identifier: "America/New_York"))
        model.calendar.timeZone = west
        model.reload()
        var there = phoneCalendar("en_US")
        there.timeZone = west
        #expect(there.dateComponents([.month, .day], from: model.anchorDay) == DateComponents(month: 10, day: 31))
        #expect(model.isToday(model.anchorDay))
    }
    @Test func colourOverrideWins() throws {
        let fixture = try CalendarFixture()
        let work = try fixture.calendar("Work")
        let defaults = freshDefaults()
        let model = fixture.model(defaults: defaults)
        #expect(model.color(of: work.id) == 0x2F6FDB)
        model.setColor(0xC2478A, of: work.id)
        #expect(model.color(of: work.id) == 0xC2478A)
        let listed = model.calendarGroups.flatMap(\.calendars).first { $0.id == work.id }
        #expect(listed?.color == 0xC2478A, "the drawer's row shows it too")
        // Kept across launches.
        #expect(fixture.model(defaults: defaults).color(of: work.id) == 0xC2478A)
        // Back to the server's colour.
        model.setColor(nil, of: work.id)
        #expect(model.color(of: work.id) == 0x2F6FDB)
        #expect(fixture.model(defaults: defaults).color(of: work.id) == 0x2F6FDB)
    }
}
