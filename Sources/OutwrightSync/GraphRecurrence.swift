// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightModel

/// Between Graph's `patternedRecurrence` and an RRULE, as [MS-OXICAL] maps Exchange's patterns:
/// daily, weekly, absolute and relative monthly and yearly, with an end date, a count or no end.
enum GraphRecurrence {
    /// A date in a time's own clock, with its ISO weekday (1 = Monday).
    struct WallDate {
        let year: Int
        let month: Int
        let day: Int
        let weekday: Int
    }

    static let weekdays = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
    static let indexes: [String: Int] = ["first": 1, "second": 2, "third": 3, "fourth": 4, "last": -1]

    // MARK: Reading

    /// The rule a recurrence says; nil when its pattern or range cannot be read.
    static func rule(_ recurrence: [String: Any]) -> RecurrenceRule? {
        guard let pattern = recurrence["pattern"] as? [String: Any], let range = recurrence["range"] as? [String: Any],
            var rule = patternRule(pattern)
        else { return nil }
        switch range["type"] as? String {
        case "endDate":
            guard let end = date(range["endDate"]) else { return nil }
            rule.until = end
        case "numbered":
            guard let count = int(range["numberOfOccurrences"]), count > 0 else { return nil }
            rule.count = count
        case "noEnd":
            break
        default:
            return nil
        }
        return RecurrenceRule(
            freq: rule.freq, interval: rule.interval, count: rule.count, until: rule.until, byDay: rule.byDay,
            byMonthDay: rule.byMonthDay, byMonth: rule.byMonth, bySetPos: rule.bySetPos, weekStart: rule.weekStart)
    }

    /// The rule of a pattern, without its range.
    private static func patternRule(_ pattern: [String: Any]) -> RecurrenceRule? {
        guard let type = pattern["type"] as? String else { return nil }
        let interval = int(pattern["interval"]) ?? 1
        let days = ((pattern["daysOfWeek"] as? [Any]) ?? []).prefix(7).compactMap { day in
            (day as? String).flatMap { weekdays.firstIndex(of: $0.lowercased()) }.map { $0 + 1 }
        }
        let index = (pattern["index"] as? String).flatMap { indexes[$0.lowercased()] } ?? 1
        let dayOfMonth = int(pattern["dayOfMonth"]).map { [$0] } ?? []
        let month = int(pattern["month"]).map { [$0] } ?? []
        switch type {
        case "daily":
            return RecurrenceRule(freq: .daily, interval: interval)
        case "weekly":
            guard !days.isEmpty else { return nil }
            let weekStart = (pattern["firstDayOfWeek"] as? String)
                .flatMap { weekdays.firstIndex(of: $0.lowercased()) }.map { $0 + 1 } ?? 1
            return RecurrenceRule(
                freq: .weekly, interval: interval, byDay: days.map { WeekdayNum(weekday: $0) }, weekStart: weekStart)
        case "absoluteMonthly", "absoluteYearly":
            let yearly = type == "absoluteYearly"
            guard !dayOfMonth.isEmpty, !yearly || !month.isEmpty else { return nil }
            return RecurrenceRule(
                freq: yearly ? .yearly : .monthly, interval: interval, byMonthDay: dayOfMonth,
                byMonth: yearly ? month : [])
        case "relativeMonthly", "relativeYearly":
            let yearly = type == "relativeYearly"
            guard !yearly || !month.isEmpty, let relative = relative(days, index: index) else { return nil }
            return RecurrenceRule(
                freq: yearly ? .yearly : .monthly, interval: interval, byDay: relative.byDay,
                byMonth: yearly ? month : [],
                bySetPos: relative.setPos)
        default:
            return nil
        }
    }

    /// One day with an ordinal, or several with BYSETPOS.
    private static func relative(_ days: [Int], index: Int) -> (byDay: [WeekdayNum], setPos: [Int])? {
        if days.count == 1, let day = days.first {
            return ([WeekdayNum(weekday: day, ordinal: index)], [])
        }
        guard !days.isEmpty else { return nil }
        return (days.map { WeekdayNum(weekday: $0) }, [index])
    }

    static func int(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double >= -1_000_000, double <= 1_000_000 else { return nil }
        return Int(double)
    }

    /// `yyyy-MM-dd` as a date.
    static func date(_ value: Any?) -> EventTime? {
        guard let text = value as? String, text.utf8.count == 10 else { return nil }
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...9999).contains(parts[0]), (1...12).contains(parts[1]), (1...31).contains(parts[2])
        else { return nil }
        return .date(year: parts[0], month: parts[1], day: parts[2])
    }

    // MARK: Writing

    /// The recurrence for a rule over a series starting at `start`, in the Windows (or IANA) zone
    /// `zone`; nil when Graph's patterns cannot hold the rule.
    static func recurrence(_ rule: RecurrenceRule, start: EventTime, zone: String) -> [String: any Sendable]? {
        guard rule.byHour.isEmpty, rule.byMinute.isEmpty, rule.byYearDay.isEmpty, rule.byWeekNo.isEmpty,
            let wall = wallDate(start)
        else { return nil }
        guard var pattern = pattern(rule, wall: wall) else { return nil }
        pattern["interval"] = rule.interval
        var range: [String: any Sendable] = ["startDate": text(wall), "recurrenceTimeZone": zone]
        if let count = rule.count {
            range["type"] = "numbered"
            range["numberOfOccurrences"] = count
        } else if let until = rule.until {
            guard let end = wallDate(until, in: clock(of: start, zone: zone)) else { return nil }
            range["type"] = "endDate"
            range["endDate"] = text(end)
        } else {
            range["type"] = "noEnd"
        }
        return ["pattern": pattern, "range": range]
    }

    private static func pattern(
        _ rule: RecurrenceRule, wall: WallDate
    ) -> [String: any Sendable]? {
        let plain = rule.byDay.allSatisfy { $0.ordinal == 0 }
        switch rule.freq {
        case .daily:
            guard rule.byDay.isEmpty, rule.byMonthDay.isEmpty, rule.byMonth.isEmpty, rule.bySetPos.isEmpty else {
                return nil
            }
            return ["type": "daily"]
        case .weekly:
            guard plain, rule.byMonthDay.isEmpty, rule.byMonth.isEmpty, rule.bySetPos.isEmpty else { return nil }
            let days = rule.byDay.isEmpty ? [wall.weekday] : rule.byDay.map(\.weekday)
            return ["type": "weekly", "daysOfWeek": names(days), "firstDayOfWeek": weekdays[rule.weekStart - 1]]
        case .monthly, .yearly:
            return calendarPattern(rule, wall: wall)
        case .hourly:
            return nil
        }
    }

    /// A monthly or yearly rule as a relative or absolute pattern.
    private static func calendarPattern(_ rule: RecurrenceRule, wall: WallDate) -> [String: any Sendable]? {
        let yearly = rule.freq == .yearly
        guard yearly ? rule.byMonth.count <= 1 : rule.byMonth.isEmpty else { return nil }
        let month = rule.byMonth.first ?? wall.month
        if var relative = relativePattern(rule) {
            relative["type"] = yearly ? "relativeYearly" : "relativeMonthly"
            if yearly { relative["month"] = month }
            return relative
        }
        guard var absolute = absolute(rule, day: wall.day) else { return nil }
        if yearly {
            absolute["type"] = "absoluteYearly"
            absolute["month"] = month
        }
        return absolute
    }

    /// `absoluteMonthly` on one day of the month (the start's when the rule names none).
    private static func absolute(_ rule: RecurrenceRule, day: Int) -> [String: any Sendable]? {
        guard rule.byDay.isEmpty, rule.bySetPos.isEmpty, rule.byMonthDay.count <= 1 else { return nil }
        let chosen = rule.byMonthDay.first ?? day
        guard (1...31).contains(chosen) else { return nil }
        return ["type": "absoluteMonthly", "dayOfMonth": chosen]
    }

    /// Days with an index, from one ordinal day or plain days with one BYSETPOS; nil when the rule is
    /// not relative (or is, past what Graph holds).
    private static func relativePattern(_ rule: RecurrenceRule) -> [String: any Sendable]? {
        guard !rule.byDay.isEmpty, rule.byMonthDay.isEmpty else { return nil }
        let index: Int
        let days: [Int]
        if rule.byDay.count == 1, let only = rule.byDay.first, only.ordinal != 0, rule.bySetPos.isEmpty {
            (index, days) = (only.ordinal, [only.weekday])
        } else if rule.byDay.allSatisfy({ $0.ordinal == 0 }), rule.bySetPos.count == 1,
            let position = rule.bySetPos.first {
            (index, days) = (position, rule.byDay.map(\.weekday))
        } else {
            return nil
        }
        guard let name = indexes.first(where: { $0.value == index })?.key else { return nil }
        return ["daysOfWeek": names(days), "index": name]
    }

    private static func names(_ days: [Int]) -> [String] {
        days.filter { (1...7).contains($0) }.map { weekdays[$0 - 1] }
    }

    /// The zone a series starting at `start` keeps its dates in: the start's own, else Graph's
    /// `zone`; UTC when neither is known.
    private static func clock(of start: EventTime, zone: String) -> TimeZone? {
        let tzid: String
        switch start {
        case let .zoned(_, own): tzid = own
        case .utc: return TimeZone(identifier: "UTC")
        case .date, .floating: tzid = zone
        }
        for candidate in [tzid, zone] {
            if case let .iana(id) = ZoneResolver.resolve(tzid: candidate, given: [:]) {
                return TimeZone(identifier: id)
            }
        }
        return nil
    }

    /// The date a time falls on in its own clock, with its ISO weekday; an instant's date is
    /// taken in `clock` (UTC when nil).
    static func wallDate(_ time: EventTime, in clock: TimeZone? = nil) -> WallDate? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = clock ?? TimeZone(identifier: "UTC") ?? .current
        let parts: DateComponents
        switch time {
        case let .date(year, month, day):
            parts = DateComponents(year: year, month: month, day: day)
        case let .floating(wall), let .zoned(wall, _):
            parts = DateComponents(year: wall.year, month: wall.month, day: wall.day)
        case let .utc(instant):
            parts = calendar.dateComponents([.year, .month, .day], from: instant)
        }
        guard let year = parts.year, let month = parts.month, let day = parts.day,
            let noon = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))
        else { return nil }
        let weekday = (calendar.component(.weekday, from: noon) + 5) % 7 + 1
        return WallDate(year: year, month: month, day: day, weekday: weekday)
    }

    private static func text(_ wall: WallDate) -> String {
        String(format: "%04d-%02d-%02d", wall.year, wall.month, wall.day)
    }
}
