// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// A BYDAY entry: a weekday, with an ordinal for "the second Monday" or "the last Friday".
public struct WeekdayNum: Sendable, Equatable, Codable {
    /// ISO weekday: 1 = Monday ... 7 = Sunday.
    public var weekday: Int
    /// 0 for every such weekday; ±1...53 counts from the start or the end of the month or year.
    public var ordinal: Int

    public init(weekday: Int, ordinal: Int = 0) {
        self.weekday = weekday
        self.ordinal = ordinal
    }
}

/// An RRULE (RFC 5545 §3.3.10), with RFC 7529's RSCALE and SKIP. SECONDLY and MINUTELY are refused.
/// Parts it does not know are kept as text, so a rule written back says what it said.
public struct RecurrenceRule: Sendable, Equatable, Codable {
    public enum Frequency: String, Sendable, Equatable, Codable {
        case yearly = "YEARLY", monthly = "MONTHLY", weekly = "WEEKLY", daily = "DAILY", hourly = "HOURLY"
    }

    /// What RFC 7529's SKIP does with a date the month does not have, such as 31 April.
    public enum Skip: String, Sendable, Equatable, Codable {
        case omit = "OMIT", backward = "BACKWARD", forward = "FORWARD"
    }

    public var freq: Frequency
    public var interval: Int
    public var count: Int?
    public var until: EventTime?
    public var byDay: [WeekdayNum]
    public var byMonthDay: [Int]
    public var byMonth: [Int]
    public var bySetPos: [Int]
    public var byYearDay: [Int]
    public var byWeekNo: [Int]
    public var byHour: [Int]
    public var byMinute: [Int]
    /// 0...60; 60, a leap second, expands as 59.
    public var bySecond: [Int]
    /// WKST as an ISO weekday, Monday when absent.
    public var weekStart: Int
    /// RFC 7529's calendar scale, uppercased; nil when absent (Gregorian).
    public var rscale: String?
    /// RFC 7529's SKIP; nil when absent (OMIT).
    public var skip: Skip?
    /// Every other part as its text (`NAME=value`), in the order it came.
    public var otherParts: [String]

    public init(freq: Frequency, interval: Int = 1, count: Int? = nil, until: EventTime? = nil,
                byDay: [WeekdayNum] = [], byMonthDay: [Int] = [], byMonth: [Int] = [], bySetPos: [Int] = [],
                byYearDay: [Int] = [], byWeekNo: [Int] = [], byHour: [Int] = [], byMinute: [Int] = [],
                bySecond: [Int] = [], weekStart: Int = 1, rscale: String? = nil, skip: Skip? = nil,
                otherParts: [String] = []) {
        self.freq = freq
        self.interval = min(max(interval, 1), RuleText.maxInterval)
        self.count = count.map { min(max($0, 1), RuleText.maxCount) }
        self.until = until
        self.byDay = RuleText.kept(byDay)
        self.byMonthDay = RuleText.kept(byMonthDay, magnitude: 1...31)
        self.byMonth = RuleText.kept(byMonth, in: 1...12)
        self.bySetPos = RuleText.kept(bySetPos, magnitude: 1...366)
        self.byYearDay = RuleText.kept(byYearDay, magnitude: 1...366)
        self.byWeekNo = RuleText.kept(byWeekNo, magnitude: 1...53)
        self.byHour = RuleText.kept(byHour, in: 0...23)
        self.byMinute = RuleText.kept(byMinute, in: 0...59)
        self.bySecond = RuleText.kept(bySecond, in: 0...60)
        self.weekStart = (1...7).contains(weekStart) ? weekStart : 1
        self.rscale = rscale.flatMap(RuleText.scale)
        self.skip = skip
        let otherScale = self.rscale.map { $0 != RuleText.gregorian } ?? false
        self.otherParts = RuleText.kept(otherParts, leapMonths: otherScale && self.byMonth.isEmpty)
    }

    /// The rule can be laid out: it has no calendar scale, or the Gregorian one.
    var isGregorian: Bool { rscale == nil || rscale == RuleText.gregorian }

    /// The rule passed through `init` again, for fields set directly after it was made.
    var clamped: RecurrenceRule {
        RecurrenceRule(
            freq: freq, interval: interval, count: count, until: until, byDay: byDay, byMonthDay: byMonthDay,
            byMonth: byMonth, bySetPos: bySetPos, byYearDay: byYearDay, byWeekNo: byWeekNo, byHour: byHour,
            byMinute: byMinute, bySecond: bySecond, weekStart: weekStart, rscale: rscale, skip: skip,
            otherParts: otherParts)
    }

    /// Saved rules are hostile too: decoding goes through the same clamps and range checks as `init`.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func list<T: Decodable>(_ key: CodingKeys) throws -> [T] {
            try values.decodeIfPresent([T].self, forKey: key) ?? []
        }
        self.init(
            freq: try values.decode(Frequency.self, forKey: .freq),
            interval: try values.decodeIfPresent(Int.self, forKey: .interval) ?? 1,
            count: try values.decodeIfPresent(Int.self, forKey: .count),
            until: try values.decodeIfPresent(EventTime.self, forKey: .until),
            byDay: try list(.byDay), byMonthDay: try list(.byMonthDay), byMonth: try list(.byMonth),
            bySetPos: try list(.bySetPos), byYearDay: try list(.byYearDay), byWeekNo: try list(.byWeekNo),
            byHour: try list(.byHour), byMinute: try list(.byMinute), bySecond: try list(.bySecond),
            weekStart: try values.decodeIfPresent(Int.self, forKey: .weekStart) ?? 1,
            rscale: try values.decodeIfPresent(String.self, forKey: .rscale),
            skip: try? values.decodeIfPresent(Skip.self, forKey: .skip),
            otherParts: try list(.otherParts))
    }

    /// Nil when the text is malformed, a value is out of range, or FREQ is SECONDLY or MINUTELY.
    public static func parse(_ text: String) -> RecurrenceRule? {
        guard let parts = RuleText.parts(text) else { return nil }
        var fields: [String: String] = [:]
        var others: [String] = []
        let scale = parts.last { $0.name == "RSCALE" }.map { $0.value.uppercased() }
        for part in parts {
            let leapMonth = part.name == "BYMONTH" && part.value.uppercased().contains("L")
            if RuleText.known.contains(part.name), !(leapMonth && scale != nil && scale != RuleText.gregorian) {
                fields[part.name] = part.value.uppercased()
            } else {
                others.append(part.name + "=" + part.value)
            }
        }
        guard let freqText = fields["FREQ"], let freq = Frequency(rawValue: freqText) else { return nil }
        guard let interval = RuleText.number(fields["INTERVAL"], in: -RuleText.maxInterval...RuleText.maxInterval),
              let count = RuleText.number(fields["COUNT"], in: 0...Int(Int32.max)),
              let byMonthDay = RuleText.list(fields["BYMONTHDAY"], magnitude: 1...31),
              let byMonth = RuleText.list(fields["BYMONTH"], in: 1...12),
              let bySetPos = RuleText.list(fields["BYSETPOS"], magnitude: 1...366),
              let byYearDay = RuleText.list(fields["BYYEARDAY"], magnitude: 1...366),
              let byWeekNo = RuleText.list(fields["BYWEEKNO"], magnitude: 1...53),
              let byHour = RuleText.list(fields["BYHOUR"], in: 0...23),
              let byMinute = RuleText.list(fields["BYMINUTE"], in: 0...59),
              let bySecond = RuleText.list(fields["BYSECOND"], in: 0...60),
              let byDay = RuleText.weekdays(fields["BYDAY"]),
              let weekStart = RuleText.weekStart(fields["WKST"]),
              let until = RuleText.until(fields["UNTIL"]),
              scale.map({ RuleText.scale($0) != nil }) ?? true,
              let skip = RuleText.skip(fields["SKIP"])
        else { return nil }
        return RecurrenceRule(
            freq: freq, interval: interval.first ?? 1, count: count.first, until: until.first, byDay: byDay,
            byMonthDay: byMonthDay, byMonth: byMonth, bySetPos: bySetPos, byYearDay: byYearDay, byWeekNo: byWeekNo,
            byHour: byHour, byMinute: byMinute, bySecond: bySecond, weekStart: weekStart, rscale: scale,
            skip: skip.first, otherParts: others)
    }
}

/// The text form of an RRULE. Each reader returns nil for a malformed value, and wraps a present
/// optional value in a one-element array so that "absent" and "malformed" stay apart.
enum RuleText {
    static let maxLength = 2_048
    static let maxList = 400
    static let maxInterval = 10_000
    static let maxCount = 100_000
    static let weekdayNames = ["MO", "TU", "WE", "TH", "FR", "SA", "SU"]

    static let gregorian = "GREGORIAN"
    static let maxOtherParts = 16
    static let maxPartLength = 256
    /// The parts this type reads into its fields.
    static let known: Set<String> = [
        "FREQ", "INTERVAL", "COUNT", "UNTIL", "BYDAY", "BYMONTHDAY", "BYMONTH", "BYSETPOS", "BYYEARDAY",
        "BYWEEKNO", "BYHOUR", "BYMINUTE", "BYSECOND", "WKST", "RSCALE", "SKIP"
    ]

    /// The parts in order, each name uppercased and its value trimmed as it came; nil when one has no `=`.
    static func parts(_ text: String) -> [(name: String, value: String)]? {
        guard text.utf8.count <= maxLength else { return nil }
        var body = Substring(text)
        if body.utf8.count >= 6, body.prefix(6).uppercased() == "RRULE:" { body = body.dropFirst(6) }
        var parts: [(name: String, value: String)] = []
        for part in body.split(separator: ";", omittingEmptySubsequences: true).prefix(64) {
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, let name = pair.first, let value = pair.last else { return nil }
            parts.append((name.trimmingCharacters(in: .whitespaces).uppercased(),
                          value.trimmingCharacters(in: .whitespaces)))
        }
        return parts
    }

    /// An other part fit to keep: a name of letters, digits and hyphens, and a value without control
    /// characters, `;` or `"`, capped in length.
    static func isPart(_ text: String) -> Bool {
        guard text.utf8.count <= maxPartLength else { return false }
        let pair = text.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard pair.count == 2, let name = pair.first, let value = pair.last, !name.isEmpty else { return false }
        return name.unicodeScalars.allSatisfy(isNameScalar) && value.unicodeScalars.allSatisfy(isValueScalar)
    }

    private static func isNameScalar(_ scalar: Unicode.Scalar) -> Bool {
        ("A"..."Z").contains(scalar) || ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) || scalar == "-"
    }

    private static func isValueScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .unassigned: false
        default: scalar != ";" && scalar != "\""
        }
    }

    /// Other parts fit to keep, deduplicated in order and capped, with none that a field holds:
    /// BYMONTH only as a leap month (RFC 7529's `5L`) of another calendar.
    static func kept(_ parts: [String], leapMonths: Bool) -> [String] {
        var kept: [String] = []
        for part in parts.prefix(64) where isPart(part) && kept.count < maxOtherParts {
            let name = String(part.prefix { $0 != "=" }).uppercased()
            let text = name + part.drop { $0 != "=" }
            guard !kept.contains(text),
                  !known.contains(name) || (name == "BYMONTH" && leapMonths && part.uppercased().contains("L"))
            else { continue }
            kept.append(text)
        }
        return kept
    }

    /// A calendar scale's name, uppercased: letters, digits and hyphens, at most 64.
    static func scale(_ text: String) -> String? {
        let name = text.uppercased()
        guard !name.isEmpty, name.utf8.count <= 64,
              name.unicodeScalars.allSatisfy(isNameScalar)
        else { return nil }
        return name
    }

    static func skip(_ text: String?) -> [RecurrenceRule.Skip]? {
        guard let text else { return [] }
        return RecurrenceRule.Skip(rawValue: text).map { [$0] }
    }

    static func integer(_ text: Substring) -> Int? {
        let digits = text.drop { $0 == "+" || $0 == "-" }
        guard text.count - digits.count <= 1, !digits.isEmpty, digits.count <= 9,
              digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber), let magnitude = Int(digits)
        else { return nil }
        return text.hasPrefix("-") ? -magnitude : magnitude
    }

    static func number(_ text: String?, in range: ClosedRange<Int>) -> [Int]? {
        guard let text else { return [] }
        guard let value = integer(Substring(text)), range.contains(value) else { return nil }
        return [value]
    }

    static func list(_ text: String?, in range: ClosedRange<Int>) -> [Int]? {
        list(text) { range.contains($0) }
    }

    /// Values whose magnitude lies in the range, either sign.
    static func list(_ text: String?, magnitude range: ClosedRange<Int>) -> [Int]? {
        list(text) { range.contains(Int($0.magnitude)) }
    }

    private static func list(_ text: String?, valid: (Int) -> Bool) -> [Int]? {
        guard let text else { return [] }
        var values: [Int] = []
        for item in text.split(separator: ",", omittingEmptySubsequences: false).prefix(maxList) {
            guard let value = integer(item), valid(value) else { return nil }
            if !values.contains(value) { values.append(value) }
        }
        return values.sorted()
    }

    /// The values in range, deduplicated, sorted and capped; `magnitude` allows either sign.
    static func kept(_ values: [Int], in range: ClosedRange<Int>) -> [Int] {
        Array(Set(values.prefix(maxList)).filter { range.contains($0) }).sorted()
    }

    static func kept(_ values: [Int], magnitude range: ClosedRange<UInt>) -> [Int] {
        Array(Set(values.prefix(maxList)).filter { range.contains($0.magnitude) }).sorted()
    }

    /// Weekdays 1...7 with ordinals within ±53, deduplicated in order and capped.
    static func kept(_ days: [WeekdayNum]) -> [WeekdayNum] {
        var kept: [WeekdayNum] = []
        for day in days.prefix(maxList) where (1...7).contains(day.weekday) && day.ordinal.magnitude <= 53 {
            if !kept.contains(day) { kept.append(day) }
        }
        return kept
    }

    static func weekdays(_ text: String?) -> [WeekdayNum]? {
        guard let text else { return [] }
        var days: [WeekdayNum] = []
        for item in text.split(separator: ",", omittingEmptySubsequences: false).prefix(maxList) {
            guard let day = weekday(item) else { return nil }
            if !days.contains(day) { days.append(day) }
        }
        return days
    }

    private static func weekday(_ item: Substring) -> WeekdayNum? {
        let name = String(item.suffix(2))
        guard let index = weekdayNames.firstIndex(of: name) else { return nil }
        let prefix = item.dropLast(2)
        guard !prefix.isEmpty else { return WeekdayNum(weekday: index + 1) }
        guard let ordinal = integer(prefix), (1...53).contains(ordinal.magnitude) else { return nil }
        return WeekdayNum(weekday: index + 1, ordinal: ordinal)
    }

    static func weekStart(_ text: String?) -> Int? {
        guard let text else { return 1 }
        return weekdayNames.firstIndex(of: text).map { $0 + 1 }
    }

    /// UNTIL as a date, a floating date-time or a UTC date-time.
    static func until(_ text: String?) -> [EventTime]? {
        guard let text else { return [] }
        let bytes = Array(text.utf8)
        guard [8, 15, 16].contains(bytes.count) else { return nil }
        guard let year = digits(bytes, 0, 4), let month = digits(bytes, 4, 2), let day = digits(bytes, 6, 2),
              WallTime(year: year, month: month, day: day) != nil else { return nil }
        if bytes.count == 8 { return [.date(year: year, month: month, day: day)] }
        guard bytes.dropFirst(8).first == UInt8(ascii: "T"), let hour = digits(bytes, 9, 2),
              let minute = digits(bytes, 11, 2), let second = digits(bytes, 13, 2),
              let wall = WallTime(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        else { return nil }
        if bytes.count == 15 { return [.floating(wall.components)] }
        guard bytes.last == UInt8(ascii: "Z") else { return nil }
        return [.utc(Date(timeIntervalSince1970: TimeInterval(wall.seconds)))]
    }

    private static func digits(_ bytes: [UInt8], _ offset: Int, _ length: Int) -> Int? {
        let slice = bytes.dropFirst(offset).prefix(length)
        guard slice.count == length, slice.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return slice.reduce(0) { $0 * 10 + Int($1 - 48) }
    }
}
