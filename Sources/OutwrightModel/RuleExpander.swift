// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// Expands an RRULE in wall time (RFC 5545 §3.3.10): each period's days are filtered by the BYxxx
/// parts that apply to the frequency (which both expands and limits), crossed with the times,
/// and BYSETPOS picks from the period last. Every day and candidate looked at costs one unit of
/// `budget`; expansion stops when it runs out. A rule in another calendar scale than the Gregorian
/// (RFC 7529) gives DTSTART only; with RSCALE=GREGORIAN, SKIP moves a day the month lacks.
struct RuleExpander {
    static let budget = 200_000

    private enum OrdinalScope { case month, year, none }

    let rule: RecurrenceRule
    let start: WallTime
    let dateOnly: Bool
    private let startDate: CivilDate
    private let byMonth: [Int]
    private let byMonthDay: [Int]
    private let byDay: [WeekdayNum]
    private let hours: [Int]
    private let minutes: [Int]
    private let seconds: [Int]
    /// SKIP's move for a day of the month that a month lacks, when it applies.
    private let skipMove: RecurrenceRule.Skip?
    private let scope: OrdinalScope
    private let weekAnchor: Int

    init(rule: RecurrenceRule, start: WallTime, dateOnly: Bool) {
        let rule = rule.clamped
        self.rule = rule
        self.start = start
        self.dateOnly = dateOnly
        let date = start.date
        startDate = date
        var byMonth = rule.byMonth
        var byMonthDay = rule.byMonthDay
        var byDay = rule.byDay
        switch rule.freq {
        case .yearly where rule.byWeekNo.isEmpty && rule.byYearDay.isEmpty && byMonthDay.isEmpty && byDay.isEmpty:
            if byMonth.isEmpty { byMonth = [date.month] }
            byMonthDay = [date.day]
        case .monthly where byMonthDay.isEmpty && byDay.isEmpty: byMonthDay = [date.day]
        case .weekly where byDay.isEmpty: byDay = [WeekdayNum(weekday: date.weekday)]
        default: break
        }
        (self.byMonth, self.byMonthDay, self.byDay) = (byMonth, byMonthDay, byDay)
        hours = dateOnly ? [0] : (rule.byHour.isEmpty ? [start.hour] : rule.byHour)
        minutes = dateOnly ? [0] : (rule.byMinute.isEmpty ? [start.minute] : rule.byMinute)
        seconds = dateOnly ? [0] : (rule.bySecond.isEmpty ? [start.second]
            : Array(Set(rule.bySecond.map { min($0, 59) })).sorted())
        let skips = rule.rscale == RuleText.gregorian && [.monthly, .yearly].contains(rule.freq)
            && rule.byWeekNo.isEmpty && rule.byYearDay.isEmpty
        skipMove = skips && rule.skip != .omit ? rule.skip : nil
        scope = Self.scope(rule)
        weekAnchor = date.number - Civil.floorMod(date.weekday - rule.weekStart, 7)
    }

    private static func scope(_ rule: RecurrenceRule) -> OrdinalScope {
        switch rule.freq {
        case .monthly: .month
        case .yearly where !rule.byMonth.isEmpty: .month
        case .yearly where rule.byWeekNo.isEmpty: .year
        default: .none
        }
    }

    /// Calls `emit` with each instance in order, DTSTART first, until COUNT, UNTIL, `stopAfter`, the
    /// budget, or `emit` returning false ends it. `skipTo` lets a rule without COUNT start near a window.
    func expand(until: WallTime?, stopAfter: WallTime, skipTo: WallTime?, budget: inout Int,
                emit: (WallTime) -> Bool) {
        var last: WallTime?
        var emitted = 0
        func offer(_ wall: WallTime) -> Bool {
            if let last, wall <= last { return true }
            if let until, wall > until { return false }
            emitted += 1
            last = wall
            guard emit(wall) else { return false }
            return rule.count.map { emitted < $0 } ?? true
        }
        guard offer(start), rule.isGregorian else { return }
        var index = rule.count == nil ? firstIndex(skipTo) : 0
        while budget > 0 {
            budget -= 1
            guard let period = period(index), period.firstWall <= stopAfter,
                  let candidates = candidates(in: period, budget: &budget) else { return }
            for wall in setPositions(candidates) { guard offer(wall) else { return } }
            index += 1
        }
    }

    // MARK: Periods

    private struct Period {
        let firstDay: Int
        let dayCount: Int
        let hour: Int?
        var firstWall: WallTime { WallTime(seconds: firstDay * Civil.secondsPerDay + (hour ?? 0) * 3_600) }
    }

    private func period(_ index: Int) -> Period? {
        let step = index * rule.interval
        let found: Period
        switch rule.freq {
        case .yearly:
            let year = startDate.year + step
            guard Civil.years.contains(year) else { return nil }
            found = Period(firstDay: Civil.dayNumber(year, 1, 1), dayCount: Civil.daysInYear(year), hour: nil)
        case .monthly:
            let months = startDate.year * 12 + startDate.month - 1 + step
            let year = Civil.floorDiv(months, 12)
            let month = Civil.floorMod(months, 12) + 1
            guard Civil.years.contains(year) else { return nil }
            found = Period(firstDay: Civil.dayNumber(year, month, 1), dayCount: Civil.daysInMonth(year, month),
                           hour: nil)
        case .weekly: found = Period(firstDay: weekAnchor + step * 7, dayCount: 7, hour: nil)
        case .daily: found = Period(firstDay: startDate.number + step, dayCount: 1, hour: nil)
        case .hourly:
            let hour = Civil.floorDiv(start.seconds, 3_600) + step
            found = Period(firstDay: Civil.floorDiv(hour, 24), dayCount: 1, hour: Civil.floorMod(hour, 24))
        }
        guard Civil.years.contains(Civil.date(found.firstDay + found.dayCount - 1).year) else { return nil }
        return found
    }

    private func firstIndex(_ target: WallTime?) -> Int {
        guard let target, target > start else { return 0 }
        let date = target.date
        let periods = switch rule.freq {
        case .yearly: date.year - startDate.year
        case .monthly: (date.year - startDate.year) * 12 + date.month - startDate.month
        case .weekly: (date.number - weekAnchor) / 7
        case .daily: date.number - startDate.number
        case .hourly: Civil.floorDiv(target.seconds, 3_600) - Civil.floorDiv(start.seconds, 3_600)
        }
        return max(0, periods / rule.interval - 1)
    }

    // MARK: Candidates

    private func candidates(in period: Period, budget: inout Int) -> [WallTime]? {
        var days: [CivilDate] = []
        for number in period.firstDay..<(period.firstDay + period.dayCount) {
            budget -= 1
            guard budget > 0 else { return nil }
            let date = Civil.date(number)
            if matches(date) { days.append(date) }
        }
        if let skipMove {
            days = withSkipped(days, in: period, move: skipMove, budget: &budget)
            guard budget > 0 else { return nil }
        }
        let hours = period.hour.map { hour in
            rule.byHour.isEmpty || rule.byHour.contains(hour) ? [dateOnly ? 0 : hour] : []
        } ?? self.hours
        var walls: [WallTime] = []
        for date in days {
            for hour in hours {
                for minute in minutes {
                    for second in seconds {
                        budget -= 1
                        guard budget > 0 else { return nil }
                        let base = date.number * Civil.secondsPerDay
                        walls.append(WallTime(seconds: base + hour * 3_600 + minute * 60 + second))
                    }
                }
            }
        }
        return walls
    }

    /// `days` with the days SKIP gives added, in order and without duplicates.
    private func withSkipped(_ days: [CivilDate], in period: Period, move: RecurrenceRule.Skip,
                             budget: inout Int) -> [CivilDate] {
        let moved = skipped(in: period, move: move, budget: &budget)
        guard !moved.isEmpty else { return days }
        return Array(Dictionary((days + moved).map { ($0.number, $0) }) { first, _ in first }.values)
            .sorted { $0.number < $1.number }
    }

    /// The days SKIP gives for the days of the month the period's months lack (RFC 7529 §3.1.2). A day
    /// past the end (31 in April) goes back to the month's last day or forward to the next month's
    /// first; one counted from the end that lies before the start (−31 in April) goes back to the
    /// previous month's last day or forward to the month's first. They still pass BYDAY.
    private func skipped(in period: Period, move: RecurrenceRule.Skip, budget: inout Int) -> [CivilDate] {
        let first = Civil.date(period.firstDay)
        let months: [(year: Int, month: Int)] = switch rule.freq {
        case .monthly: byMonth.isEmpty || byMonth.contains(first.month) ? [(first.year, first.month)] : []
        default: (byMonth.isEmpty ? Array(1...12) : byMonth).map { (first.year, $0) }
        }
        var moved: [CivilDate] = []
        for (year, month) in months {
            budget -= 1
            let length = Civil.daysInMonth(year, month)
            guard budget > 0 else { continue }
            let opening = Civil.dayNumber(year, month, 1)
            let last = opening + length - 1
            var numbers: [Int] = []
            if byMonthDay.contains(where: { $0 > length }) { numbers.append(move == .forward ? last + 1 : last) }
            if byMonthDay.contains(where: { $0 < -length }) { numbers.append(move == .forward ? opening : opening - 1) }
            for number in numbers {
                let date = Civil.date(number)
                if byDay.isEmpty || byDay.contains(where: { weekdayMatches($0, date) }) { moved.append(date) }
            }
        }
        return moved
    }

    private func setPositions(_ candidates: [WallTime]) -> [WallTime] {
        guard !rule.bySetPos.isEmpty else { return candidates }
        let picked = rule.bySetPos.compactMap { position -> WallTime? in
            let index = position > 0 ? position - 1 : candidates.count + position
            return candidates.indices.contains(index) ? candidates[index] : nil
        }
        return Array(Set(picked)).sorted()
    }

    private func matches(_ date: CivilDate) -> Bool {
        (byMonth.isEmpty || byMonth.contains(date.month))
            && (rule.freq != .yearly || rule.byWeekNo.isEmpty || weekNoMatches(date))
            && (![.yearly, .hourly].contains(rule.freq) || rule.byYearDay.isEmpty || yearDayMatches(date))
            && (rule.freq == .weekly || byMonthDay.isEmpty || monthDayMatches(date))
            && (byDay.isEmpty || byDay.contains { weekdayMatches($0, date) })
    }

    private func monthDayMatches(_ date: CivilDate) -> Bool {
        let length = Civil.daysInMonth(date.year, date.month)
        return byMonthDay.contains { $0 > 0 ? $0 == date.day : length + $0 + 1 == date.day }
    }

    private func yearDayMatches(_ date: CivilDate) -> Bool {
        let length = Civil.daysInYear(date.year)
        return rule.byYearDay.contains { $0 > 0 ? $0 == date.dayOfYear : length + $0 + 1 == date.dayOfYear }
    }

    private func weekdayMatches(_ entry: WeekdayNum, _ date: CivilDate) -> Bool {
        guard entry.weekday == date.weekday else { return false }
        guard entry.ordinal != 0 else { return true }
        let (position, length): (Int, Int) = switch scope {
        case .month: (date.day, Civil.daysInMonth(date.year, date.month))
        case .year: (date.dayOfYear, Civil.daysInYear(date.year))
        case .none: (0, 0)
        }
        guard scope != .none else { return true }
        return entry.ordinal > 0
            ? (position - 1) / 7 + 1 == entry.ordinal
            : (length - position) / 7 + 1 == -entry.ordinal
    }

    // MARK: Week numbers (week 1 is the first week, starting on WKST, with four days of the year)

    private func weekNoMatches(_ date: CivilDate) -> Bool {
        var year = date.year
        var first = weekOneStart(year)
        if date.number < first {
            year -= 1
            first = weekOneStart(year)
        } else if date.number >= weekOneStart(year + 1) {
            year += 1
            first = weekOneStart(year)
        }
        let total = (weekOneStart(year + 1) - first) / 7
        let number = (date.number - first) / 7 + 1
        return rule.byWeekNo.contains { $0 > 0 ? $0 == number : total + $0 + 1 == number }
    }

    private func weekOneStart(_ year: Int) -> Int {
        let januaryFirst = Civil.dayNumber(year, 1, 1)
        let intoWeek = Civil.floorMod(Civil.weekday(januaryFirst) - rule.weekStart, 7)
        return intoWeek <= 3 ? januaryFirst - intoWeek : januaryFirst - intoWeek + 7
    }
}
