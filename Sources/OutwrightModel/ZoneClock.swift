// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// Turns wall times of one zone into instants and back.
enum ZoneClock: Sendable {
    case system(TimeZone)
    case rules(RulesTable)

    static let utc = ZoneClock.system(TimeZone(secondsFromGMT: 0) ?? .gmt)

    /// A nonexistent wall time (a spring gap) moves forward by the gap; an ambiguous one takes the first.
    func instant(of wall: WallTime) -> Date {
        switch self {
        case let .rules(table):
            return Self.date(wall.seconds - table.offset(atWall: wall))
        case let .system(zone):
            let before = zone.secondsFromGMT(for: Self.date(wall.seconds - Civil.secondsPerDay))
            let after = zone.secondsFromGMT(for: Self.date(wall.seconds + Civil.secondsPerDay))
            let valid = [before, after].filter { zone.secondsFromGMT(for: Self.date(wall.seconds - $0)) == $0 }
            guard let offset = valid.max() else { return Self.date(wall.seconds - before) }
            return Self.date(wall.seconds - offset)
        }
    }

    func wall(at instant: Date) -> WallTime? {
        switch self {
        case let .system(zone):
            return WallTime(instant: instant, offset: zone.secondsFromGMT(for: instant))
        case let .rules(table):
            let seconds = instant.timeIntervalSince1970.rounded(.down)
            guard let whole = Int(exactly: seconds) else { return nil }
            return WallTime(instant: instant, offset: table.offset(atInstant: whole))
        }
    }

    private static func date(_ seconds: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(seconds)) }
}

/// A VTIMEZONE's onsets in the years asked for, expanded once, as wall time → UTC offset.
/// Before the first onset the earliest observance's TZOFFSETFROM holds.
struct RulesTable: Sendable {
    private struct Onset {
        let wall: WallTime
        let from: Int
        let to: Int
        /// The onset's instant (seconds since 1970): its wall time read with the offset before the change.
        var instant: Int { wall.seconds - from }
    }

    private let onsets: [Onset]
    /// The same onsets in order of their instants.
    private let byInstant: [Onset]
    private let initialOffset: Int

    static let onsetCap = 1_000
    /// UTC offsets are clamped to ±18 hours.
    static let offsets = -64_800...64_800

    init(_ rules: ZoneRules, years: ClosedRange<Int>) {
        let first = WallTime(year: min(max(years.lowerBound, 1), Civil.years.upperBound), month: 1, day: 1)
        let horizon = WallTime(year: min(max(years.upperBound, 1), Civil.years.upperBound), month: 12, day: 31,
                               hour: 23, minute: 59, second: 59) ?? WallTime(seconds: 0)
        var found: [Onset] = []
        for observance in rules.observances.prefix(64) {
            let from = Self.clamped(observance.offsetFrom)
            let to = Self.clamped(observance.offsetTo)
            found += Self.onsets(of: observance, offsetFrom: from, from: first, through: horizon)
                .map { Onset(wall: $0, from: from, to: to) }
        }
        found.sort { $0.wall < $1.wall }
        onsets = found
        byInstant = found.sorted { $0.instant < $1.instant }
        initialOffset = found.first?.from ?? 0
    }

    private static func clamped(_ offset: Int) -> Int { min(max(offset, offsets.lowerBound), offsets.upperBound) }

    /// The offset of the latest onset at or before `wall`. A wall time in the gap an onset skips (when
    /// the clock springs forward) keeps the offset before it, so it moves forward by the gap.
    func offset(atWall wall: WallTime?) -> Int {
        guard let wall else { return initialOffset }
        var low = 0
        var high = onsets.count
        while low < high {
            let middle = (low + high) / 2
            if onsets.indices.contains(middle), onsets[middle].wall <= wall { low = middle + 1 } else { high = middle }
        }
        guard low > 0, onsets.indices.contains(low - 1) else { return initialOffset }
        let onset = onsets[low - 1]
        let inGap = onset.to > onset.from && wall.seconds < onset.wall.seconds + (onset.to - onset.from)
        return inGap ? onset.from : onset.to
    }

    /// The offset in force at an instant (seconds since 1970): that of the latest onset at or before it.
    func offset(atInstant seconds: Int) -> Int {
        var low = 0
        var high = byInstant.count
        while low < high {
            let middle = (low + high) / 2
            if byInstant.indices.contains(middle), byInstant[middle].instant <= seconds {
                low = middle + 1
            } else {
                high = middle
            }
        }
        guard low > 0, byInstant.indices.contains(low - 1) else { return initialOffset }
        return byInstant[low - 1].to
    }

    /// Onsets up to `horizon`; a rule without COUNT starts expanding near `first`.
    private static func onsets(of observance: Observance, offsetFrom: Int, from first: WallTime?,
                               through horizon: WallTime) -> [WallTime] {
        guard let start = WallTime(observance.start) else { return [] }
        var walls = [start] + observance.rdates.prefix(onsetCap).compactMap(WallTime.init)
        if let rule = observance.rule {
            let until = rule.until.flatMap { Self.wall(of: $0, offset: offsetFrom) }
            var budget = RuleExpander.budget
            RuleExpander(rule: rule, start: start, dateOnly: false)
                .expand(until: until, stopAfter: horizon, skipTo: first, budget: &budget) { wall in
                    walls.append(wall)
                    return walls.count < onsetCap
                }
        }
        return walls.filter { $0 <= horizon }
    }

    private static func wall(of time: EventTime, offset: Int) -> WallTime? {
        switch time {
        case let .date(year, month, day): WallTime(year: year, month: month, day: day, hour: 23, minute: 59, second: 59)
        case let .floating(components), let .zoned(components, _): WallTime(components)
        case let .utc(date): WallTime(instant: date, offset: offset)
        }
    }
}

/// Finds the clock of each EventTime in a series, building each VTIMEZONE's table once.
struct ClockBook {
    let phoneZone: TimeZone
    let zones: [String: ZoneRules]
    let years: ClosedRange<Int>
    private var tables: [String: ZoneClock] = [:]

    /// `years` bounds the VTIMEZONE onsets expanded.
    init(phoneZone: TimeZone, zones: [String: ZoneRules], years: ClosedRange<Int>) {
        self.phoneZone = phoneZone
        self.zones = zones
        self.years = years
    }

    /// The wall time and clock of a time; nil when it is not a valid date.
    mutating func locate(_ time: EventTime) -> (WallTime, ZoneClock)? {
        switch time {
        case let .date(year, month, day):
            return WallTime(year: year, month: month, day: day).map { ($0, .system(phoneZone)) }
        case let .floating(components):
            return WallTime(components).map { ($0, .system(phoneZone)) }
        case let .zoned(components, zone):
            guard let wall = WallTime(components) else { return nil }
            return (wall, clock(zone))
        case let .utc(date):
            return WallTime(instant: date, offset: 0).map { ($0, ZoneClock.utc) }
        }
    }

    private mutating func clock(_ zone: String) -> ZoneClock {
        if let known = tables[zone] { return known }
        let clock: ZoneClock = switch ZoneResolver.resolve(tzid: zone, given: zones) {
        case let .iana(identifier): .system(TimeZone(identifier: identifier) ?? phoneZone)
        case let .rules(rules): .rules(RulesTable(rules, years: years))
        case .floating: .system(phoneZone)
        }
        if tables.count < 64 { tables[zone] = clock }
        return clock
    }
}
