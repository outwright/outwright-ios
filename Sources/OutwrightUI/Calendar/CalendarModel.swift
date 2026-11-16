// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
public import Observation
public import OutwrightModel
import OutwrightStore

/// How the calendar shows its days.
public enum CalendarMode: String, Sendable, CaseIterable {
    case agenda, day, threeDay, month
}

/// Which week the calendar shows in landscape.
public enum WeekMode: String, Sendable, CaseIterable {
    case workWeek, week
}

/// A timed event laid out in its day: events that overlap one another on the clock share the width,
/// each in its own column.
public struct PlacedEvent: Sendable, Equatable, Identifiable {
    public var event: CalendarEvent
    public var column: Int
    public var columns: Int
    /// Minutes from the day's start on the wall clock, where the event's top and bottom are drawn.
    public var startMinute: Int
    public var endMinute: Int

    public var id: String { "\(event.id.raw).\(event.occurrence.start.timeIntervalSince1970)" }
}

/// One day of the calendar on the phone, with its all-day events and its timed ones.
public struct DayColumn: Sendable, Equatable, Identifiable {
    /// The day's start on the phone.
    public var day: Date
    public var allDay: [CalendarEvent]
    public var timed: [PlacedEvent]

    public var id: Date { day }
    public var isEmpty: Bool { allDay.isEmpty && timed.isEmpty }
}

/// The Calendar tab: every account's chosen calendars, from the store only, so today shows at once
/// and without the network.
@Observable @MainActor
public final class CalendarModel {
    /// How many days the agenda reads ahead of its first day.
    static let agendaDays = 30

    public var mode: CalendarMode = .threeDay {
        didSet { if mode != oldValue { reloadDays() } }
    }
    /// The phone lies on its side: every view shows the week, and `mode` waits for the turn back.
    public var isLandscape = false {
        didSet { if isLandscape != oldValue { reloadDays() } }
    }
    /// The week shown in landscape.
    public var weekMode: WeekMode = .week {
        didSet { if weekMode != oldValue { reloadDays() } }
    }
    /// Whether the days shown are a week (in landscape).
    public var showsWeek: Bool { isLandscape }
    /// The first day shown (the chosen day in Month); always the start of a day. While it is today it
    /// stays today: after midnight it moves to the new day.
    public var anchorDay: Date {
        get { anchor }
        set {
            anchor = calendar.startOfDay(for: newValue)
            anchorParts = calendar.dateComponents([.year, .month, .day], from: anchor)
            anchorIsToday = isToday(anchor)
            reloadDays()
        }
    }
    /// The calendars shown; nil means all.
    public var shownCalendars: Set<CalendarID>? {
        didSet { if shownCalendars != oldValue { reloadDays() } }
    }
    public private(set) var days: [DayColumn] = []
    public private(set) var calendarGroups: [(account: Account, calendars: [CalendarInfo])] = []
    /// The subscribed calendars, a group of their own: they belong to no account.
    public private(set) var subscribedCalendars: [CalendarInfo] = []
    /// Per calendar, how many of its events the server gave that could not be read.
    public private(set) var refusedCounts: [CalendarID: Int] = [:]
    /// The subscribed calendars whose last fetch failed, and why.
    public private(set) var subscriptionFailures: [CalendarID: SubscriptionFailure] = [:]
    /// The store could not be read: the banner shows until a read works again.
    public var failed: Bool { calendarsFailed || daysFailed }
    /// Counts the times the hour grid should go back to now (a new day, a return to the front).
    public private(set) var nowScrolls = 0

    @ObservationIgnored let app: AppModel
    /// The phone's calendar (by default it follows the phone's zone and locale as they change).
    @ObservationIgnored var calendar: Calendar
    @ObservationIgnored let now: () -> Date
    @ObservationIgnored private let titleFormat: DateFormatter
    @ObservationIgnored private let hourFormat: Date.FormatStyle
    @ObservationIgnored private var anchorIsToday = true
    /// The anchor's day, which stays the same day when the phone's zone changes.
    @ObservationIgnored private var anchorParts: DateComponents
    private var anchor: Date
    private var calendarsFailed = false
    private var daysFailed = false
    private var colors: [CalendarID: Int] = [:]

    /// `now` is the app's clock unless another is given.
    public init(app: AppModel, calendar: Calendar = .autoupdatingCurrent, now: (() -> Date)? = nil) {
        self.app = app
        self.calendar = calendar
        let now = now ?? app.now
        self.now = now
        let start = calendar.startOfDay(for: now())
        anchor = start
        anchorParts = calendar.dateComponents([.year, .month, .day], from: start)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("LLLLy")
        titleFormat = formatter
        // Hour labels from a day with no clock change, in UTC, so none repeats or goes missing.
        var plain = Calendar(identifier: .gregorian)
        plain.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        plain.locale = calendar.locale
        hourFormat = Date.FormatStyle(
            date: .omitted, time: .shortened, locale: calendar.locale ?? .current, calendar: plain,
            timeZone: plain.timeZone)
        mode = app.initialCalendarMode
        reload()
    }

    /// Today's start on the phone.
    public var today: Date { calendar.startOfDay(for: now()) }

    public func isToday(_ day: Date) -> Bool { calendar.isDate(day, inSameDayAs: now()) }

    /// The month (and year) of the first day shown, in the phone's language.
    public var monthTitle: String {
        // The phone's zone may have changed since the last title.
        titleFormat.calendar = calendar
        titleFormat.timeZone = calendar.timeZone
        return titleFormat.string(from: anchor)
    }

    /// The weekdays' one-letter names, from the locale's first weekday.
    public var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        guard symbols.count == 7 else { return symbols }
        let first = min(max(calendar.firstWeekday, 1), 7) - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    /// The hour grid's label for an hour of the day (empty at midnight).
    public func hourLabel(_ hour: Int) -> String {
        guard (1...23).contains(hour) else { return "" }
        return hourFormat.format(Date(timeIntervalSinceReferenceDate: Double(hour) * 3_600))
    }

    /// Whether there is any calendar, an account's or a subscribed one.
    public var hasCalendars: Bool { !calendarGroups.isEmpty || !subscribedCalendars.isEmpty }

    /// Every calendar, the accounts' and the subscribed ones.
    var everyCalendar: [CalendarInfo] { calendarGroups.flatMap(\.calendars) + subscribedCalendars }

    /// Whether any calendar takes new events (not one that is read-only, such as a subscription).
    public var canAddEvents: Bool {
        calendarGroups.contains { group in group.calendars.contains { !$0.isReadOnly } }
    }

    /// The calendar's colour (0xRRGGBB).
    public func color(of id: CalendarID) -> Int { colors[id] ?? 0x8A8F98 }

    public func goToToday() {
        anchorDay = now()
        nowScrolls &+= 1
    }

    public func move(by days: Int) {
        anchorDay = calendar.date(byAdding: .day, value: days, to: anchor) ?? anchor
    }

    /// One swipe: a day in Day and 3 Day, a week in the agenda and in landscape, a month in Month.
    public func step(_ direction: Int) {
        if showsWeek {
            move(by: 7 * direction)
            return
        }
        switch mode {
        case .day, .threeDay: move(by: direction)
        case .agenda: move(by: 7 * direction)
        case .month: anchorDay = calendar.date(byAdding: .month, value: direction, to: anchor) ?? anchor
        }
    }

    /// The day chosen in Month: the anchor, with its events below the grid.
    public var chosenDay: DayColumn? { days.first { $0.day == anchor } }

    /// The app came back to the front: a new day may have begun, and the grid goes back to now.
    public func sceneBecameActive() {
        reload()
        if isToday(anchor) { nowScrolls &+= 1 }
    }

    /// Reloads when the stored calendars change (a sync, an edit, a new day), until the task is cancelled.
    public func observe() async {
        do {
            for try await _ in app.store.observeCalendars() { reload() }
        } catch is CancellationError {
            return
        } catch {
            calendarsFailed = true
        }
    }

    /// A calendar was just added: it is shown, also when only some calendars are ticked.
    func added(_ calendar: CalendarID) {
        if shownCalendars != nil { shownCalendars?.insert(calendar) }
        reload()
    }

    /// The calendars and the days shown, from the store.
    public func reload() {
        do {
            try loadCalendars()
            calendarsFailed = false
        } catch {
            calendarsFailed = true
        }
        reloadDays()
    }

    /// The days shown; the calendars are read again only when the store changes.
    private func reloadDays() {
        followToday()
        let range = shownRange()
        do {
            let events = try app.store.occurrences(from: range.from, to: range.to, in: shownCalendars)
            var columns = dayStarts(range).map { column($0, events) }
            if mode == .agenda, !showsWeek {
                columns = columns.filter { !$0.isEmpty || isToday($0.day) }
            }
            days = columns
            daysFailed = false
        } catch {
            daysFailed = true
        }
    }

    /// An anchor that follows today is today's start, after midnight and after a zone change alike. An
    /// anchor the owner chose keeps its day, at that day's start in the phone's zone, which may have
    /// changed.
    private func followToday() {
        if anchorIsToday {
            let current = today
            guard anchor != current else { return }
            anchor = current
            nowScrolls &+= 1
            anchorParts = calendar.dateComponents([.year, .month, .day], from: current)
        } else {
            anchor = calendar.date(from: anchorParts).map(calendar.startOfDay) ?? calendar.startOfDay(for: anchor)
        }
    }

    private func loadCalendars() throws(StoreError) {
        var groups: [(account: Account, calendars: [CalendarInfo])] = []
        var refused: [CalendarID: Int] = [:]
        var found: [CalendarID: Int] = [:]
        for account in app.accounts {
            let cals = try app.store.calendars(account.id)
            guard !cals.isEmpty else { continue }
            groups.append((account: account, calendars: cals))
            for cal in cals {
                found[cal.id] = cal.color
                let count = try app.store.refusedEventCount(cal.id)
                if count > 0 { refused[cal.id] = count }
            }
        }
        var failures: [CalendarID: SubscriptionFailure] = [:]
        var subscribed: [CalendarInfo] = []
        for held in try app.store.subscriptions() {
            subscribed.append(held.calendar)
            found[held.id] = held.calendar.color
            if let failure = held.failure { failures[held.id] = failure }
            let count = try app.store.refusedEventCount(held.id)
            if count > 0 { refused[held.id] = count }
        }
        calendarGroups = groups
        subscribedCalendars = subscribed
        refusedCounts = refused
        subscriptionFailures = failures
        colors = found
    }

    // MARK: Days

    /// Minutes from the day's start on its wall clock: 02:30 is 150 on a day the clocks change too. A
    /// time before the day is its top, one after it its bottom.
    public func minutes(of date: Date, on day: Date) -> Int {
        if date <= day { return 0 }
        guard calendar.isDate(date, inSameDayAs: day) else { return 24 * 60 }
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return min(max((parts.hour ?? 0) * 60 + (parts.minute ?? 0), 0), 24 * 60)
    }

    private func shownRange() -> (from: Date, to: Date) {
        if showsWeek { return weekRange() }
        switch mode {
        case .day: return (anchor, adding(1, to: anchor))
        case .threeDay: return (anchor, adding(3, to: anchor))
        case .agenda: return (anchor, adding(Self.agendaDays, to: anchor))
        case .month:
            let first = calendar.dateInterval(of: .month, for: anchor)?.start ?? anchor
            let count = calendar.range(of: .day, in: .month, for: anchor)?.count ?? 30
            let weekday = calendar.component(.weekday, from: first)
            let lead = ((weekday - calendar.firstWeekday) % 7 + 7) % 7
            let weeks = (lead + count + 6) / 7
            let start = adding(-lead, to: first)
            return (start, adding(weeks * 7, to: start))
        }
    }

    /// The week holding the anchor: seven days from the locale's first weekday, or Monday to Friday of
    /// the week that starts on Monday.
    private func weekRange() -> (from: Date, to: Date) {
        let weekday = calendar.component(.weekday, from: anchor)
        switch weekMode {
        case .week:
            let start = adding(-(((weekday - calendar.firstWeekday) % 7 + 7) % 7), to: anchor)
            return (start, adding(7, to: start))
        case .workWeek:
            // Weekday 2 is Monday in the Gregorian calendar.
            let start = adding(-(((weekday - 2) % 7 + 7) % 7), to: anchor)
            return (start, adding(5, to: start))
        }
    }

    private func adding(_ days: Int, to day: Date) -> Date {
        calendar.date(byAdding: .day, value: days, to: day) ?? day.addingTimeInterval(Double(days) * 86_400)
    }

    /// The day starts in the range, at most a year of them.
    private func dayStarts(_ range: (from: Date, to: Date)) -> [Date] {
        var starts: [Date] = []
        var day = range.from
        while day < range.to, starts.count < 366 {
            starts.append(day)
            day = adding(1, to: day)
        }
        return starts
    }

    private func column(_ day: Date, _ events: [CalendarEvent]) -> DayColumn {
        let end = adding(1, to: day)
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        let key = (parts.year ?? 0) * 10_000 + (parts.month ?? 0) * 100 + (parts.day ?? 0)
        var allDay: [CalendarEvent] = []
        var timed: [CalendarEvent] = []
        for event in events {
            let occurrence = event.occurrence
            if let first = occurrence.allDayStart, let last = occurrence.allDayEnd {
                if first <= key && key < max(last, first + 1) { allDay.append(event) }
            } else if occurrence.end > occurrence.start {
                if occurrence.start < end && occurrence.end > day { timed.append(event) }
            } else if occurrence.start >= day && occurrence.start < end {
                timed.append(event)
            }
        }
        return DayColumn(day: day, allDay: allDay, timed: DayLayout.place(timed) { self.minutes(of: $0, on: day) })
    }
}
