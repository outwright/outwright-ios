// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightDAV
import OutwrightModel

/// iCalendar values (RFC 5545 §3.3) read and written: DATE, DATE-TIME, DURATION, UTC-OFFSET and
/// RECUR. Every reader returns nil for a malformed value; nothing here traps.
enum ICalValue {
    static let utcZone = TimeZone(identifier: "UTC") ?? .gmt

    /// A Gregorian calendar in UTC: wall times are worked out on it as if they were UTC.
    static var wallCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utcZone
        return calendar
    }

    // MARK: - Reading

    /// A calendar day.
    struct Day {
        let year: Int
        let month: Int
        let day: Int

        var time: EventTime { .date(year: year, month: month, day: day) }
    }

    /// `yyyyMMdd`, or nil.
    static func date(_ text: Substring) -> Day? {
        guard text.count == 8, let year = digits(text.prefix(4)), let month = digits(text.dropFirst(4).prefix(2)),
            let day = digits(text.dropFirst(6)), (1...9999).contains(year), (1...12).contains(month),
            (1...daysIn(year, month)).contains(day)
        else { return nil }
        return Day(year: year, month: month, day: day)
    }

    static func daysIn(_ year: Int, _ month: Int) -> Int {
        switch month {
        case 2: (year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)) ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }

    /// `yyyyMMddTHHmmss` with an optional `Z`: the wall time and whether it is UTC.
    static func dateTime(_ text: Substring) -> (wall: DateComponents, utc: Bool)? {
        let utc = text.hasSuffix("Z") || text.hasSuffix("z")
        let body = utc ? text.dropLast() : text
        guard body.count == 15, let tee = body.dropFirst(8).first, tee == "T" || tee == "t",
            let day = date(body.prefix(8)), let hour = digits(body.dropFirst(9).prefix(2)),
            let minute = digits(body.dropFirst(11).prefix(2)), let second = digits(body.dropFirst(13)),
            (0...23).contains(hour), (0...59).contains(minute), (0...60).contains(second)
        else { return nil }
        let wall = DateComponents(
            year: day.year, month: day.month, day: day.day, hour: hour, minute: minute, second: min(second, 59))
        return (wall, utc)
    }

    /// One DATE or DATE-TIME of a property: `VALUE=DATE` (or eight digits) is a date; a `Z` time is UTC; a
    /// TZID the system or the Windows table knows names that zone, one of the object's VTIMEZONEs keeps its
    /// TZID, any other is floating.
    static func time(_ text: Substring, tzid: String?, zones: [String: ZoneRules]) -> EventTime? {
        let text = text.trimmingCharacters(in: .whitespaces)[...]
        if text.count == 8 {
            return date(text)?.time
        }
        guard let (wall, utc) = dateTime(text) else { return nil }
        if utc {
            return wallCalendar.date(from: wall).map(EventTime.utc)
        }
        guard let tzid else { return .floating(wall) }
        switch ZoneResolver.resolve(tzid: tzid, given: zones) {
        case let .iana(id): return .zoned(wall, zone: id)
        case .rules: return .zoned(wall, zone: tzid)
        case .floating: return .floating(wall)
        }
    }

    static func time(_ property: ICalProperty, zones: [String: ZoneRules]) -> EventTime? {
        if property.parameter("VALUE")?.uppercased() == "DATE" {
            let text = property.value.trimmingCharacters(in: .whitespaces)[...]
            return date(text)?.time
        }
        return time(property.value[...], tzid: property.parameter("TZID"), zones: zones)
    }

    /// The times of an RDATE or EXDATE line (a PERIOD counts by its start), at most `limit`.
    static func times(_ property: ICalProperty, zones: [String: ZoneRules], limit: Int) -> [EventTime] {
        let isDate = property.parameter("VALUE")?.uppercased() == "DATE"
        let tzid = property.parameter("TZID")
        return property.value.split(separator: ",").prefix(limit).compactMap { part in
            let start = part.split(separator: "/", maxSplits: 1).first ?? part
            if isDate {
                return date(start)?.time
            }
            return time(start, tzid: tzid, zones: zones)
        }
    }

    /// A DURATION in seconds (`-P1DT2H`, `PT15M`, `P1W`), days counted as 86,400 seconds, or nil.
    static func duration(_ text: String) -> Int? {
        durationParts(text).map { $0.days * 86_400 + $0.seconds }
    }

    /// A DURATION as its nominal days (W and D: whole days on the calendar, however long the clock
    /// makes them) and its exact seconds (H, M and S), both with its sign (RFC 5545 §3.3.6). Each part
    /// is clamped to a hundred years.
    static func durationParts(_ text: String) -> (days: Int, seconds: Int)? {
        var body = Substring(text.trimmingCharacters(in: .whitespaces).uppercased())
        let sign = body.hasPrefix("-") ? -1 : 1
        if body.hasPrefix("-") || body.hasPrefix("+") { body = body.dropFirst() }
        guard body.hasPrefix("P"), body.count >= 3, body.count <= 40 else { return nil }
        var days = 0
        var seconds = 0
        var number = ""
        var inTime = false
        var any = false
        for character in body.dropFirst() {
            if character.isASCII, character.isNumber {
                number.append(character)
            } else if character == "T", number.isEmpty, !inTime {
                inTime = true
            } else {
                guard let value = Int(number), number.count <= 9, let unit = unit(character, inTime: inTime) else {
                    return nil
                }
                if inTime {
                    seconds = min(seconds + value * unit, 100 * 366 * 86_400)
                } else {
                    days = min(days + value * unit / 86_400, 100 * 366)
                }
                number = ""
                any = true
            }
        }
        guard any, number.isEmpty else { return nil }
        return (sign * days, sign * seconds)
    }

    /// The seconds of a DURATION unit: W and D before the T, H, M and S after it.
    private static func unit(_ character: Character, inTime: Bool) -> Int? {
        switch (character, inTime) {
        case ("W", false): 604_800
        case ("D", false): 86_400
        case ("H", true): 3_600
        case ("M", true): 60
        case ("S", true): 1
        default: nil
        }
    }

    /// A UTC-OFFSET (`+0100`, `-053000`) in seconds east of UTC.
    static func offset(_ text: String) -> Int? {
        let body = text.trimmingCharacters(in: .whitespaces)[...]
        guard let sign = body.first, sign == "+" || sign == "-" else { return nil }
        let rest = body.dropFirst()
        guard rest.count == 4 || rest.count == 6, let hours = digits(rest.prefix(2)),
            let minutes = digits(rest.dropFirst(2).prefix(2)), hours <= 23, minutes <= 59
        else { return nil }
        let seconds = rest.count == 6 ? digits(rest.suffix(2)) : 0
        guard let seconds, seconds <= 59 else { return nil }
        return (sign == "-" ? -1 : 1) * (hours * 3_600 + minutes * 60 + seconds)
    }

    private static func digits(_ text: Substring) -> Int? {
        guard !text.isEmpty, text.count <= 9, text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(text)
    }

    // MARK: - Writing

    static func dateText(year: Int, month: Int, day: Int) -> String {
        String(format: "%04d%02d%02d", year, month, day)
    }

    static func wallText(_ wall: DateComponents) -> String {
        String(
            format: "%04d%02d%02dT%02d%02d%02d", wall.year ?? 1970, wall.month ?? 1, wall.day ?? 1, wall.hour ?? 0,
            wall.minute ?? 0, wall.second ?? 0)
    }

    static func utcText(_ date: Date) -> String {
        let parts = wallCalendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return wallText(parts) + "Z"
    }

    /// A DTSTART, DTEND, RECURRENCE-ID or EXDATE line for `time`.
    static func property(_ name: String, _ time: EventTime) -> ICalProperty {
        switch time {
        case let .date(year, month, day):
            return ICalProperty(
                name: name, parameters: [ContentParameter(name: "VALUE", values: ["DATE"])],
                value: dateText(year: year, month: month, day: day))
        case let .floating(wall):
            return ICalProperty(name: name, value: wallText(wall))
        case let .zoned(wall, zone):
            return ICalProperty(
                name: name, parameters: [ContentParameter(name: "TZID", values: [zone])], value: wallText(wall))
        case let .utc(date):
            return ICalProperty(name: name, value: utcText(date))
        }
    }

    /// `-PT15M`: a trigger `minutes` before the start.
    static func trigger(minutes: Int) -> String {
        minutes <= 0 ? "PT0S" : "-PT\(minutes)M"
    }

    /// UNTIL's text: a date for a date, else the instant in UTC.
    private static func untilText(_ until: EventTime) -> String? {
        switch until {
        case let .date(year, month, day): dateText(year: year, month: month, day: day)
        default: until.instant(in: utcZone).map(utcText)
        }
    }

    /// The RRULE value of a rule. UNTIL is written as a date for a date, else in UTC; the parts the rule
    /// keeps as text come last, in their order.
    static func recur(_ rule: RecurrenceRule) -> String {
        var parts = ["FREQ=" + rule.freq.rawValue]
        if let scale = rule.rscale { parts.append("RSCALE=" + scale) }
        if rule.interval != 1 { parts.append("INTERVAL=\(rule.interval)") }
        if let count = rule.count { parts.append("COUNT=\(count)") }
        if let until = rule.until.flatMap(untilText) { parts.append("UNTIL=" + until) }
        let names = ["MO", "TU", "WE", "TH", "FR", "SA", "SU"]
        func list(_ name: String, _ values: [Int]) {
            if !values.isEmpty { parts.append(name + "=" + values.map(String.init).joined(separator: ",")) }
        }
        let days = rule.byDay.compactMap { day -> String? in
            guard (1...7).contains(day.weekday) else { return nil }
            return (day.ordinal == 0 ? "" : String(day.ordinal)) + names[day.weekday - 1]
        }
        if !days.isEmpty { parts.append("BYDAY=" + days.joined(separator: ",")) }
        list("BYMONTHDAY", rule.byMonthDay)
        list("BYMONTH", rule.byMonth)
        list("BYYEARDAY", rule.byYearDay)
        list("BYWEEKNO", rule.byWeekNo)
        list("BYHOUR", rule.byHour)
        list("BYMINUTE", rule.byMinute)
        list("BYSECOND", rule.bySecond)
        list("BYSETPOS", rule.bySetPos)
        if rule.weekStart != 1, (1...7).contains(rule.weekStart) { parts.append("WKST=" + names[rule.weekStart - 1]) }
        if let skip = rule.skip { parts.append("SKIP=" + skip.rawValue) }
        parts += rule.otherParts
        return parts.joined(separator: ";")
    }
}
