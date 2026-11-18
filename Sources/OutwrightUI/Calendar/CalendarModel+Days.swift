// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
import OutwrightModel

// MARK: Going to a day

extension CalendarModel {
    /// The agenda's first days: a month each way from the day.
    static func agenda(around day: Date, calendar: Calendar) -> ClosedRange<Date> {
        let first = calendar.date(byAdding: .day, value: -agendaDays, to: day) ?? day
        let last = calendar.date(byAdding: .day, value: agendaDays, to: day) ?? day
        return min(first, last)...max(first, last)
    }

    /// The agenda's days around a day chosen, kept within its reach from today so it can still grow.
    func resetAgenda(around day: Date) {
        let nearest = adding(-Self.agendaReach + Self.agendaDays, to: today)
        let furthest = adding(Self.agendaReach - Self.agendaDays, to: today)
        agendaRange = Self.agenda(around: min(max(day, nearest), furthest), calendar: calendar)
    }

    /// The agenda reached an end: a month more on that side, read alone and joined on, up to its reach
    /// from today. Past its window of days it lets go of as many at the other end.
    public func extendAgenda(_ edge: AgendaEdge) {
        guard mode == .agenda, !showsWeek else { return }
        let added: (from: Date, to: Date)
        switch edge {
        case .top:
            let from = max(adding(-Self.agendaDays, to: agendaRange.lowerBound), adding(-Self.agendaReach, to: today))
            guard from < agendaRange.lowerBound else { return }
            added = (from, agendaRange.lowerBound)
        case .bottom:
            let after = adding(1, to: agendaRange.upperBound)
            let to = min(adding(Self.agendaDays, to: after), adding(Self.agendaReach + 1, to: today))
            guard after < to else { return }
            added = (after, to)
        }
        let events: [CalendarEvent]
        do {
            events = try app.store.occurrences(from: added.from, to: added.to, in: shownCalendars)
        } catch {
            daysFailed = true
            return
        }
        let new = columns(dayStarts(added), events)
        var joined = edge == .top ? new + days : days + new
        if joined.count > Self.agendaWindow {
            joined = edge == .top ? Array(joined.prefix(Self.agendaWindow)) : Array(joined.suffix(Self.agendaWindow))
        }
        guard let first = joined.first?.day, let last = joined.last?.day else { return }
        days = joined
        agendaRange = first...last
        daysFailed = false
    }

    /// The open month a month on or back.
    public func stepMiniMonth(_ months: Int) {
        miniMonth = calendar.date(byAdding: .month, value: months, to: miniMonth) ?? miniMonth
        loadMiniMonth()
    }

    /// Reads the open month's weeks; a failure shows as the calendar's banner.
    func loadMiniMonth() {
        let range = monthRange(miniMonth)
        do {
            let events = try app.store.occurrences(from: range.from, to: range.to, in: shownCalendars)
            miniMonthDays = columns(dayStarts(range), events)
            miniMonthFailed = false
        } catch {
            miniMonthFailed = true
        }
    }

    /// The agenda scrolled to a day: it becomes the anchor, so the title and the week strip follow.
    public func scrolled(to day: Date) {
        guard day != anchor else { return }
        anchorDay = day
    }

    /// A day chosen in the month or the week strip: shown, and the open month closes.
    public func jump(to day: Date) {
        anchorDay = day
        showsMiniMonth = false
        jumps &+= 1
    }

    /// A day's header was tapped: that day alone.
    public func openDay(_ day: Date) {
        mode = .day
        jump(to: day)
    }

    /// The start of the half hour a tap in the hour grid fell in: `minute` is from the top of the day
    /// on its wall clock.
    public func slot(on day: Date, minute: Int) -> Date {
        let clamped = min(max(minute, 0), 24 * 60 - 1)
        let rounded = clamped / 30 * 30
        return calendar.date(bySettingHour: rounded / 60, minute: rounded % 60, second: 0, of: day)
            ?? day.addingTimeInterval(Double(rounded) * 60)
    }

    public func move(by days: Int) {
        anchorDay = calendar.date(byAdding: .day, value: days, to: anchor) ?? anchor
    }

    /// One swipe: a day in Day and 3 Day, a week in the weeks, a month in Month. The agenda scrolls
    /// instead.
    public func step(_ direction: Int) {
        if showsWeek {
            move(by: 7 * direction)
            return
        }
        switch mode {
        case .day, .threeDay: move(by: direction)
        case .agenda: return
        case .month: anchorDay = calendar.date(byAdding: .month, value: direction, to: anchor) ?? anchor
        case .week, .workWeek: move(by: 7 * direction)
        }
    }
}

// MARK: Days

extension CalendarModel {
    /// The seven days of the week that holds the day, from the locale's first weekday.
    public func week(of day: Date) -> [Date] {
        let start = calendar.startOfDay(for: day)
        let weekday = calendar.component(.weekday, from: start)
        let first = adding(-(((weekday - calendar.firstWeekday) % 7 + 7) % 7), to: start)
        return (0..<7).map { adding($0, to: first) }
    }

    /// Minutes from the day's start on its wall clock: 02:30 is 150 on a day the clocks change too. A
    /// time before the day is its top, one after it its bottom.
    public func minutes(of date: Date, on day: Date) -> Int {
        if date <= day { return 0 }
        guard calendar.isDate(date, inSameDayAs: day) else { return 24 * 60 }
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return min(max((parts.hour ?? 0) * 60 + (parts.minute ?? 0), 0), 24 * 60)
    }

    func shownRange() -> (from: Date, to: Date) {
        if showsWeek { return weekRange() }
        switch mode {
        case .day: return (anchor, adding(1, to: anchor))
        case .threeDay: return (anchor, adding(3, to: anchor))
        case .agenda: return (agendaRange.lowerBound, adding(1, to: agendaRange.upperBound))
        case .month, .week, .workWeek: return monthRange(anchor)
        }
    }

    /// The whole weeks that hold the day's month.
    func monthRange(_ day: Date) -> (from: Date, to: Date) {
        let first = calendar.dateInterval(of: .month, for: day)?.start ?? calendar.startOfDay(for: day)
        let count = calendar.range(of: .day, in: .month, for: day)?.count ?? 30
        let weekday = calendar.component(.weekday, from: first)
        let lead = ((weekday - calendar.firstWeekday) % 7 + 7) % 7
        let weeks = (lead + count + 6) / 7
        let start = adding(-lead, to: first)
        return (start, adding(weeks * 7, to: start))
    }

    /// The week holding the anchor: seven days from the locale's first weekday, or Monday to Friday of
    /// the week that starts on Monday.
    func weekRange() -> (from: Date, to: Date) {
        let weekday = calendar.component(.weekday, from: anchor)
        switch shownWeek {
        case .week:
            let start = adding(-(((weekday - calendar.firstWeekday) % 7 + 7) % 7), to: anchor)
            return (start, adding(7, to: start))
        case .workWeek:
            // Weekday 2 is Monday in the Gregorian calendar.
            let start = adding(-(((weekday - 2) % 7 + 7) % 7), to: anchor)
            return (start, adding(5, to: start))
        }
    }

    func adding(_ days: Int, to day: Date) -> Date {
        calendar.date(byAdding: .day, value: days, to: day) ?? day.addingTimeInterval(Double(days) * 86_400)
    }

    /// The day starts in the range, at most a year of them.
    func dayStarts(_ range: (from: Date, to: Date)) -> [Date] {
        var starts: [Date] = []
        var day = range.from
        while day < range.to, starts.count < 366 {
            starts.append(day)
            day = adding(1, to: day)
        }
        return starts
    }

    /// The days' columns, each event put in the days it falls on in one pass over the events.
    func columns(_ starts: [Date], _ events: [CalendarEvent]) -> [DayColumn] {
        guard let rangeStart = starts.first, let lastStart = starts.last else { return [] }
        let rangeEnd = adding(1, to: lastStart)
        let keys = starts.map(dayKey)
        var index: [Date: Int] = [:]
        for (position, day) in starts.enumerated() { index[day] = position }
        var allDay = [[CalendarEvent]](repeating: [], count: starts.count)
        var timed = [[CalendarEvent]](repeating: [], count: starts.count)
        for event in events {
            let occurrence = event.occurrence
            if let first = occurrence.allDayStart, let last = occurrence.allDayEnd {
                let end = max(last, first + 1)
                var position = firstIndex(in: keys, atLeast: first)
                while position < keys.count, keys[position] < end {
                    allDay[position].append(event)
                    position += 1
                }
                continue
            }
            let lasts = occurrence.end > occurrence.start
            guard occurrence.start < rangeEnd, lasts ? occurrence.end > rangeStart : occurrence.start >= rangeStart
            else { continue }
            // Every day from the one it starts on while the day begins before the event ends.
            var day = max(calendar.startOfDay(for: occurrence.start), rangeStart)
            var steps = 0
            repeat {
                if let position = index[day] { timed[position].append(event) }
                day = adding(1, to: day)
                steps += 1
            } while lasts && day < occurrence.end && day < rangeEnd && steps <= starts.count
        }
        return starts.indices.map { position in
            let day = starts[position]
            return DayColumn(
                day: day, allDay: allDay[position],
                timed: DayLayout.place(timed[position]) { self.minutes(of: $0, on: day) })
        }
    }

    /// A day as a number that sorts like the days: 20261110.
    private func dayKey(_ day: Date) -> Int {
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        return (parts.year ?? 0) * 10_000 + (parts.month ?? 0) * 100 + (parts.day ?? 0)
    }

    /// The first position whose key is at least `key` (the keys are sorted).
    private func firstIndex(in keys: [Int], atLeast key: Int) -> Int {
        var low = 0
        var high = keys.count
        while low < high {
            let middle = low + (high - low) / 2
            if keys[middle] < key { low = middle + 1 } else { high = middle }
        }
        return low
    }
}

// MARK: Calendars

extension CalendarModel {
    /// The weekdays' one-letter names, from the locale's first weekday.
    public var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        guard symbols.count == 7 else { return symbols }
        let first = min(max(calendar.firstWeekday, 1), 7) - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    /// Whether there is any calendar, an account's or a subscribed one.
    public var hasCalendars: Bool { !calendarGroups.isEmpty || !subscribedCalendars.isEmpty }

    /// Every calendar, the accounts' and the subscribed ones.
    var everyCalendar: [CalendarInfo] { calendarGroups.flatMap(\.calendars) + subscribedCalendars }

    /// Whether any calendar takes new events (not one that is read-only, such as a subscription).
    public var canAddEvents: Bool {
        calendarGroups.contains { group in group.calendars.contains { !$0.isReadOnly } }
    }

    /// A kept choice of calendars keeps only those that still exist; none left, or every one, is all.
    /// True when the choice changed, which has read the days again.
    func forgetGoneCalendars() -> Bool {
        guard let shown = shownCalendars else { return false }
        let every = Set(everyCalendar.map(\.id))
        let kept = shown.intersection(every)
        let next = kept.isEmpty || kept == every ? nil : kept
        guard next != shown else { return false }
        shownCalendars = next
        return true
    }

    /// The day chosen in Month: the anchor, with its events below the grid.
    public var chosenDay: DayColumn? { days.first { $0.day == anchor } }

    /// Today's start on the phone.
    public var today: Date { calendar.startOfDay(for: now()) }

    public func isToday(_ day: Date) -> Bool { calendar.isDate(day, inSameDayAs: now()) }

    /// A calendar was just added: it is shown, also when only some calendars are ticked.
    func added(_ calendar: CalendarID) {
        if shownCalendars != nil { shownCalendars?.insert(calendar) }
        reload()
    }
}
