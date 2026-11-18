// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
public import Observation
public import OutwrightModel
import OutwrightStore

/// How the calendar shows its days. The week and the work week are offered on a wide screen; a phone
/// shows the week when it lies on its side.
public enum CalendarMode: String, Sendable, CaseIterable {
    case agenda, day, threeDay, month, week, workWeek

    /// The views a phone held upright offers.
    public static let upright: [CalendarMode] = [.agenda, .day, .threeDay, .month]
}

/// An end of the agenda: the past at the top, the future at the bottom.
public enum AgendaEdge: Sendable {
    case top, bottom
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
    /// How many days the agenda reads each way from today, and adds when one of its ends is reached.
    static let agendaDays = 30
    /// The most days the agenda holds at once; growing past them lets go of the other end.
    static let agendaWindow = 120
    /// How far from today the agenda goes, either way: about ten years.
    static let agendaReach = 3_660
    /// How many days the paging grid holds on each side of the days shown.
    static let pageMargin = 7

    public var mode: CalendarMode = .threeDay {
        didSet {
            guard mode != oldValue else { return }
            if !applyingDefault {
                defaults.set(mode.rawValue, forKey: SettingsKeys.calendarMode)
                modeChosen = true
            }
            if mode == .agenda { resetAgenda(around: anchor) }
            reloadDays()
        }
    }
    /// The screen is wide (an iPad): the week and the work week are offered, and the week is the view
    /// until another is chosen.
    public var isRegularWidth = false {
        didSet {
            guard isRegularWidth != oldValue, !modeChosen else { return }
            applyingDefault = true
            mode = isRegularWidth ? .week : .threeDay
            applyingDefault = false
        }
    }
    /// The views the switcher offers.
    public var offeredModes: [CalendarMode] {
        isRegularWidth ? [.agenda, .day, .threeDay, .week, .workWeek, .month] : CalendarMode.upright
    }
    /// The month above the days is open (the title was tapped); it opens at the day in view.
    public var showsMiniMonth = false {
        didSet {
            guard showsMiniMonth else {
                // A closed month's failed read no longer shows.
                miniMonthFailed = false
                return
            }
            guard !oldValue else { return }
            miniMonth = anchor
            loadMiniMonth()
        }
    }
    /// A day in the month the open month shows, and that month's weeks with their events.
    public internal(set) var miniMonth: Date
    public internal(set) var miniMonthDays: [DayColumn] = []
    /// The days the agenda lists, today and a month each way until it grows.
    public internal(set) var agendaRange: ClosedRange<Date>
    /// The phone lies on its side: every view shows the week, and `mode` waits for the turn back.
    public var isLandscape = false {
        didSet { if isLandscape != oldValue { reloadDays() } }
    }
    /// The week shown in landscape.
    public var weekMode: WeekMode = .week {
        didSet {
            guard weekMode != oldValue else { return }
            defaults.set(weekMode.rawValue, forKey: SettingsKeys.calendarWeekMode)
            reloadDays()
        }
    }
    /// Whether the days shown are a week (in landscape, or the week chosen on a wide screen).
    public var showsWeek: Bool { isLandscape || mode == .week || mode == .workWeek }
    /// The week shown: the landscape choice on its side, else the one chosen.
    var shownWeek: WeekMode { isLandscape ? weekMode : (mode == .workWeek ? .workWeek : .week) }
    /// Day and 3 Day page a day at a time under the finger.
    public var pages: Bool { !showsWeek && (mode == .day || mode == .threeDay) }
    /// The days on screen at once in the paging grid.
    public var pageWidth: Int { mode == .day ? 1 : 3 }
    /// The first day shown (the chosen day in Month); always the start of a day. While it is today it
    /// stays today: after midnight it moves to the new day.
    public var anchorDay: Date {
        get { anchor }
        set {
            anchor = calendar.startOfDay(for: newValue)
            anchorParts = calendar.dateComponents([.year, .month, .day], from: anchor)
            anchorIsToday = isToday(anchor)
            if mode == .agenda, !showsWeek {
                // Within the agenda's days only the title follows; no reading again.
                guard !agendaRange.contains(anchor) else { return }
                resetAgenda(around: anchor)
            }
            reloadDays()
        }
    }
    /// The calendars shown; nil means all.
    public var shownCalendars: Set<CalendarID>? {
        didSet {
            guard shownCalendars != oldValue else { return }
            if let shown = shownCalendars {
                defaults.set(shown.map(\.raw).sorted(), forKey: SettingsKeys.shownCalendars)
            } else {
                defaults.removeObject(forKey: SettingsKeys.shownCalendars)
            }
            reloadDays()
        }
    }
    /// The days shown.
    public internal(set) var days: [DayColumn] = []
    /// Day and 3 Day: the days shown with a week either side, which the grid pages through.
    public private(set) var pageDays: [DayColumn] = []
    /// Counts the times a day was chosen to go to (the month, the week strip), which the views scroll to.
    public internal(set) var jumps = 0
    public private(set) var calendarGroups: [(account: Account, calendars: [CalendarInfo])] = []
    /// The subscribed calendars, a group of their own: they belong to no account.
    public private(set) var subscribedCalendars: [CalendarInfo] = []
    /// Per calendar, how many of its events the server gave that could not be read.
    public private(set) var refusedCounts: [CalendarID: Int] = [:]
    /// The subscribed calendars whose last fetch failed, and why.
    public private(set) var subscriptionFailures: [CalendarID: SubscriptionFailure] = [:]
    /// The store could not be read: the banner shows until a read works again.
    public var failed: Bool { calendarsFailed || daysFailed || miniMonthFailed }
    /// Counts the times the hour grid should go back to now (a new day, a return to the front).
    public private(set) var nowScrolls = 0

    @ObservationIgnored let app: AppModel
    /// The phone's calendar (by default it follows the phone's zone and locale as they change).
    @ObservationIgnored var calendar: Calendar
    @ObservationIgnored let now: () -> Date
    /// Where the view and the calendars chosen are kept across launches.
    @ObservationIgnored let defaults: UserDefaults
    /// A view was chosen (now or at an earlier launch): the wide screen's default no longer applies.
    @ObservationIgnored var modeChosen = false
    @ObservationIgnored var applyingDefault = false
    /// The stored view and week as last read, so only a change to them is followed.
    @ObservationIgnored var lastStoredMode: String?
    @ObservationIgnored var lastStoredWeek: String?
    @ObservationIgnored private let titleFormat: DateFormatter
    @ObservationIgnored private let monthFormat: DateFormatter
    @ObservationIgnored private let hourFormat: Date.FormatStyle
    @ObservationIgnored private var anchorIsToday = true
    /// The anchor's day, which stays the same day when the phone's zone changes.
    @ObservationIgnored private var anchorParts: DateComponents
    private(set) var anchor: Date
    private var calendarsFailed = false
    var daysFailed = false
    var miniMonthFailed = false
    private var colors: [CalendarID: Int] = [:]

    /// `now` is the app's clock unless another is given. The view and the calendars are the ones last
    /// chosen, kept in `defaults`; a launch argument may choose the view.
    public init(
        app: AppModel, calendar: Calendar = .autoupdatingCurrent, now: (() -> Date)? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.app = app
        self.calendar = calendar
        let now = now ?? app.now
        self.now = now
        self.defaults = defaults
        let start = calendar.startOfDay(for: now())
        anchor = start
        miniMonth = start
        agendaRange = Self.agenda(around: start, calendar: calendar)
        anchorParts = calendar.dateComponents([.year, .month, .day], from: start)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("LLLLy")
        titleFormat = formatter
        let monthOnly = DateFormatter()
        monthOnly.calendar = calendar
        monthOnly.locale = calendar.locale
        monthOnly.timeZone = calendar.timeZone
        monthOnly.setLocalizedDateFormatFromTemplate("LLLL")
        monthFormat = monthOnly
        // Hour labels from a day with no clock change, in UTC, so none repeats or goes missing.
        var plain = Calendar(identifier: .gregorian)
        plain.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        plain.locale = calendar.locale
        hourFormat = Date.FormatStyle(
            date: .omitted, time: .shortened, locale: calendar.locale ?? .current, calendar: plain,
            timeZone: plain.timeZone)
        readStoredSettings()
        if let ids = defaults.array(forKey: SettingsKeys.shownCalendars) as? [Int64] {
            shownCalendars = Set(ids.map(CalendarID.init(raw:)))
        }
        reload()
    }

    /// The month of the first day shown, in the phone's language, with the year unless it is this year.
    public var monthTitle: String { monthTitle(of: anchor) }

    /// A day's month, in the phone's language, with the year unless it is this year.
    public func monthTitle(of day: Date) -> String {
        // The phone's zone may have changed since the last title.
        titleFormat.calendar = calendar
        titleFormat.timeZone = calendar.timeZone
        monthFormat.calendar = calendar
        monthFormat.timeZone = calendar.timeZone
        let sameYear = calendar.component(.year, from: day) == calendar.component(.year, from: now())
        return (sameYear ? monthFormat : titleFormat).string(from: day)
    }

    /// The hour grid's label for an hour of the day (empty at midnight).
    public func hourLabel(_ hour: Int) -> String {
        guard (1...23).contains(hour) else { return "" }
        return hourFormat.format(Date(timeIntervalSinceReferenceDate: Double(hour) * 3_600))
    }

    /// The calendar's colour (0xRRGGBB).
    public func color(of id: CalendarID) -> Int { colors[id] ?? 0x8A8F98 }

    public func goToToday() {
        anchorDay = now()
        showsMiniMonth = false
        nowScrolls &+= 1
    }

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

    /// The calendars and the days shown, from the store.
    public func reload() {
        do {
            try loadCalendars()
            calendarsFailed = false
            // A choice that changed has read the days already.
            if forgetGoneCalendars() { return }
        } catch {
            calendarsFailed = true
        }
        reloadDays()
    }

    /// The days shown; the calendars are read again only when the store changes.
    func reloadDays() {
        followToday()
        let range = shownRange()
        // Day and 3 Day read a week more on each side, for the grid to page into.
        let read = pages ? (adding(-Self.pageMargin, to: range.from), adding(Self.pageMargin, to: range.to)) : range
        do {
            let events = try app.store.occurrences(from: read.0, to: read.1, in: shownCalendars)
            let columns = columns(dayStarts(read), events)
            if pages {
                pageDays = columns
                days = columns.filter { $0.day >= range.from && $0.day < range.to }
            } else {
                pageDays = []
                days = columns
            }
            daysFailed = false
        } catch {
            daysFailed = true
        }
        if showsMiniMonth { loadMiniMonth() }
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
        let chosen = CalendarColors.chosen(defaults)
        for account in app.accounts {
            let cals = try app.store.calendars(account.id).map { CalendarColors.applied($0, chosen) }
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
            let calendar = CalendarColors.applied(held.calendar, chosen)
            subscribed.append(calendar)
            found[held.id] = calendar.color
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

}
