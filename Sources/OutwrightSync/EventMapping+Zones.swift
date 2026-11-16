// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightDAV
import OutwrightModel

extension EventMapping {
    /// VTIMEZONEs (and their observances) read per calendar object.
    static let zoneCap = 64

    /// The calendar object's VTIMEZONEs by TZID. An observance that can't be read is left out.
    static func zones(_ calendar: ICalComponent) -> [String: ZoneRules] {
        var zones: [String: ZoneRules] = [:]
        for zone in calendar.components.lazy.filter({ $0.name == "VTIMEZONE" }).prefix(zoneCap) {
            guard let tzid = zone.first("TZID")?.value, !tzid.isEmpty, zones[tzid] == nil else { continue }
            let observances = zone.components.prefix(zoneCap).compactMap(observance)
            if !observances.isEmpty { zones[tzid] = ZoneRules(observances: observances) }
        }
        return zones
    }

    private static func observance(_ part: ICalComponent) -> Observance? {
        guard part.name == "STANDARD" || part.name == "DAYLIGHT",
            let start = part.first("DTSTART").flatMap({ ICalValue.dateTime($0.value[...]) })?.wall,
            let from = part.first("TZOFFSETFROM").flatMap({ ICalValue.offset($0.value) }),
            let to = part.first("TZOFFSETTO").flatMap({ ICalValue.offset($0.value) })
        else { return nil }
        let rdates = part.all("RDATE").flatMap { line in
            line.value.split(separator: ",").prefix(listCap).compactMap { ICalValue.dateTime($0)?.wall }
        }
        return Observance(
            isDaylight: part.name == "DAYLIGHT", start: start, offsetFrom: from, offsetTo: to,
            rule: part.first("RRULE").flatMap { RecurrenceRule.parse($0.value) }, rdates: rdates)
    }

    /// The years before and after an event's year that a written VTIMEZONE covers.
    static let zoneYears = (before: 1, after: 20)

    /// A VTIMEZONE for a zone the system knows, from its clock changes in the years around `year`. Each
    /// kind of change (to daylight time, back) that falls on the same weekday, n-th or last of the same
    /// month, at the same local time, in every one of those years is written as a yearly rule; any other
    /// is written change by change (RDATE), so other years read right too. A zone without changes gets
    /// one STANDARD. Nil for a zone the system does not know.
    static func vtimezone(_ id: String, year: Int) -> ICalComponent? {
        TimeZone(identifier: id).flatMap { vtimezone(id, year: year, source: ZoneSource($0)) }
    }

    static func vtimezone(_ id: String, year: Int, source zone: ZoneSource) -> ICalComponent? {
        let years = (year - zoneYears.before)...(year + zoneYears.after)
        let calendar = ICalValue.wallCalendar
        guard let first = calendar.date(from: DateComponents(year: years.lowerBound, month: 1, day: 1)),
            let last = calendar.date(from: DateComponents(year: years.upperBound + 1, month: 1, day: 1))
        else { return nil }
        var changes: [ClockChange] = []
        var cursor = first
        while changes.count < 4 * years.count, let next = zone.next(cursor), next > cursor, next < last {
            changes.append(ClockChange(zone, at: next))
            cursor = next
        }
        var parts: [ICalComponent] = []
        var kinds: [ClockChange.Kind] = []
        for change in changes where !kinds.contains(change.kind) {
            kinds.append(change.kind)
        }
        for kind in kinds {
            let group = changes.filter { $0.kind == kind }
            parts.append(observance(group, rule: yearlyRule(group, years: years)))
        }
        if parts.isEmpty {
            let offset = ICalValue.offsetText(zone.offset(first))
            parts = [ICalComponent(name: "STANDARD", properties: [
                ICalProperty(name: "DTSTART", value: "19700101T000000"),
                ICalProperty(name: "TZOFFSETFROM", value: offset), ICalProperty(name: "TZOFFSETTO", value: offset)
            ])]
        }
        return ICalComponent(name: "VTIMEZONE", properties: [ICalProperty(name: "TZID", value: id)], components: parts)
    }

    /// The RRULE that names every change of the group, one a year in each of `years`, or nil.
    private static func yearlyRule(_ group: [ClockChange], years: ClosedRange<Int>) -> String? {
        guard group.count == years.count, group.map(\.local.year) == years.map({ Optional($0) }),
            let first = group.first,
            group.allSatisfy({
                $0.local.month == first.local.month && $0.local.weekday == first.local.weekday
                    && $0.local.hour == first.local.hour && $0.local.minute == first.local.minute
                    && $0.local.second == first.local.second
            })
        else { return nil }
        let ordinals = Set(group.map(\.ordinal))
        let ordinal: Int
        if ordinals.count == 1, let only = ordinals.first {
            ordinal = only
        } else if group.allSatisfy(\.isLast) {
            ordinal = -1
        } else {
            return nil
        }
        // Foundation's weekday is 1 = Sunday.
        let names = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]
        let index = (first.local.weekday ?? 1) - 1
        guard names.indices.contains(index), let month = first.local.month else { return nil }
        return "FREQ=YEARLY;BYMONTH=\(month);BYDAY=\(ordinal)\(names[index])"
    }

    /// One kind of change as an observance: from its first change, by the rule, or listing the others.
    private static func observance(_ group: [ClockChange], rule: String?) -> ICalComponent {
        guard let first = group.first else { return ICalComponent(name: "STANDARD") }
        var properties = [
            ICalProperty(name: "DTSTART", value: ICalValue.wallText(first.local)),
            ICalProperty(name: "TZOFFSETFROM", value: ICalValue.offsetText(first.kind.from)),
            ICalProperty(name: "TZOFFSETTO", value: ICalValue.offsetText(first.kind.to))
        ]
        if let rule {
            properties.append(ICalProperty(name: "RRULE", value: rule))
        } else if group.count > 1 {
            properties.append(ICalProperty(
                name: "RDATE", value: group.dropFirst().map { ICalValue.wallText($0.local) }.joined(separator: ",")))
        }
        return ICalComponent(name: first.kind.daylight ? "DAYLIGHT" : "STANDARD", properties: properties)
    }
}

/// One clock change of a zone: what it changes from and to, and when on the clock before it.
struct ClockChange {
    struct Kind: Equatable {
        let daylight: Bool
        let from: Int
        let to: Int
    }

    let kind: Kind
    /// The local time of the change, in the offset before it, with its weekday.
    let local: DateComponents

    init(_ zone: ZoneSource, at change: Date) {
        let from = zone.offset(change.addingTimeInterval(-1))
        kind = Kind(daylight: zone.isDaylight(change), from: from, to: zone.offset(change))
        local = ICalValue.wallCalendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .weekday], from: change.addingTimeInterval(Double(from)))
    }

    /// Which of its weekday in the month it is: 1 to 5.
    var ordinal: Int { ((local.day ?? 1) - 1) / 7 + 1 }

    /// The last of its weekday in the month.
    var isLast: Bool { (local.day ?? 1) + 7 > ICalValue.daysIn(local.year ?? 1970, local.month ?? 1) }
}

extension ICalValue {
    /// A UTC-OFFSET: `+0100`, or `+053045` with seconds.
    static func offsetText(_ seconds: Int) -> String {
        let sign = seconds < 0 ? "-" : "+"
        let value = abs(seconds)
        let text = sign + String(format: "%02d%02d", value / 3_600, value % 3_600 / 60)
        return value % 60 == 0 ? text : text + String(format: "%02d", value % 60)
    }
}

/// What a VTIMEZONE is written from: a zone's offset and daylight time at an instant, and its next clock
/// change after one.
struct ZoneSource {
    let offset: (Date) -> Int
    let isDaylight: (Date) -> Bool
    let next: (Date) -> Date?

    init(offset: @escaping (Date) -> Int, isDaylight: @escaping (Date) -> Bool, next: @escaping (Date) -> Date?) {
        self.offset = offset
        self.isDaylight = isDaylight
        self.next = next
    }

    init(_ zone: TimeZone) {
        self.init(
            offset: { zone.secondsFromGMT(for: $0) }, isDaylight: { zone.isDaylightSavingTime(for: $0) },
            next: { zone.nextDaylightSavingTimeTransition(after: $0) })
    }
}
