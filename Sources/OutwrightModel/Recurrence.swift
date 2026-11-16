// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation

/// Lays a series out as occurrences in a window: the rule and RDATEs, less EXDATEs, with overridden
/// occurrences replaced (or dropped when cancelled). An override for this and later occurrences
/// (RANGE=THISANDFUTURE) also gives every later occurrence its details, its length and its shift in
/// wall time, until the next such override; an override of one occurrence still wins for it. Bounded:
/// at most `occurrenceCap` occurrences, and the rule's expansion stops at `RuleExpander.budget` units of work.
public enum Recurrence {
    public static let occurrenceCap = 5_000
    static let listCap = 5_000

    /// Occurrences overlapping [from, to), sorted by start.
    public static func occurrences(_ series: EventSeries, from: Date, to: Date, phoneZone: TimeZone)
        -> [Occurrence] {
        guard from < to else { return [] }
        let firstYear = WallTime(instant: from, offset: 0)?.date.year ?? Civil.years.lowerBound
        let lastYear = max(WallTime(instant: to, offset: 0)?.date.year ?? Civil.years.upperBound, firstYear)
        let years = zoneYears(series, around: (firstYear - 1)...(lastYear + 1))
        var layout = Layout(window: from..<to, book: ClockBook(phoneZone: phoneZone, zones: series.zones, years: years))
        layout.skip(series)
        if let base = series.base { layout.addSeriesEvent(base, series: series) }
        for (key, override) in layout.overrides where override.details.status != .cancelled {
            guard !layout.excluded.contains(key) else { continue }
            layout.add(override.details, recurrenceID: override.recurrenceID)
        }
        let sorted = layout.found.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        return Array(sorted.prefix(occurrenceCap))
    }

    /// The override for this and later occurrences whose segment holds the series' occurrence at
    /// `recurrenceID`: the last one before it. Nil when none does, or when the occurrence has its own override.
    public static func range(holding recurrenceID: EventTime, in series: EventSeries, phoneZone: TimeZone)
        -> EventOverride? {
        let year = recurrenceID.wallYear ?? Civil.years.lowerBound
        let book = ClockBook(phoneZone: phoneZone, zones: series.zones,
                             years: zoneYears(series, around: (year - 1)...(year + 1)))
        var layout = Layout(window: Date.distantPast..<Date.distantFuture, book: book)
        layout.skip(series)
        guard let key = layout.key(recurrenceID), layout.overrides[key] == nil else { return nil }
        return layout.segment(after: key)?.override
    }

    /// The occurrence at `recurrenceID` as an override of its own, for a change to it alone: the
    /// override it has, else the details it is laid out with (the series event's, or the range's that
    /// holds it) at its own times, of the kind of time those details start with. Nil when the series
    /// has no event to lay it out from.
    public static func ownOverride(at recurrenceID: EventTime, in series: EventSeries, phoneZone: TimeZone)
        -> EventOverride? {
        if let kept = series.overrides.first(where: { $0.recurrenceID == recurrenceID }) {
            return EventOverride(recurrenceID: recurrenceID, details: kept.details)
        }
        guard let base = series.base else { return nil }
        let year = recurrenceID.wallYear ?? Civil.years.lowerBound
        let book = ClockBook(phoneZone: phoneZone, zones: series.zones, years: (year - 1)...(year + 1))
        var layout = Layout(window: Date.distantPast..<Date.distantFuture, book: book)
        layout.skip(series)
        guard let key = layout.key(recurrenceID) else { return nil }
        let instant = Date(timeIntervalSince1970: TimeInterval(key))
        if let segment = layout.segment(after: key) {
            return segment.details(at: instant).map { EventOverride(recurrenceID: recurrenceID, details: $0) }
        }
        guard let shape = Shape(base, book: &layout.book), let wall = shape.clock.wall(at: instant) else { return nil }
        let (last, overflow) = wall.seconds.addingReportingOverflow(shape.length)
        guard !overflow else { return nil }
        guard let start = base.start.at(wall, clock: shape.clock),
              let end = base.start.at(WallTime(seconds: last), clock: shape.clock) else { return nil }
        var details = base
        details.start = start
        details.end = end
        return EventOverride(recurrenceID: recurrenceID, details: details)
    }

    /// When the occurrence at `recurrenceID` is the start of a range (RANGE=THISANDFUTURE) and changes or
    /// goes alone, the range that carries on for the later ones: at the series' next occurrence (by its
    /// rule and RDATEs, not excluded and without an override of its own), with the range's details at the
    /// range's shift and length. Nil when that occurrence starts no range or the series has no next one.
    public static func rangeAfter(_ recurrenceID: EventTime, in series: EventSeries, phoneZone: TimeZone)
        -> EventOverride? {
        guard let base = series.base else { return nil }
        let year = recurrenceID.wallYear ?? Civil.years.lowerBound
        let book = ClockBook(phoneZone: phoneZone, zones: series.zones,
                             years: zoneYears(series, around: (year - 1)...(year + 11)))
        var layout = Layout(window: Date.distantPast..<Date.distantFuture, book: book)
        layout.skip(series)
        guard let key = layout.key(recurrenceID), let range = layout.overrides[key], range.thisAndFuture,
              let segment = layout.segments.first(where: { $0.key == key }),
              let next = layout.next(after: key, base: base, series: series),
              let details = segment.details(at: next.instant)
        else { return nil }
        return EventOverride(recurrenceID: next.recurrenceID, details: details, thisAndFuture: true)
    }

    /// How many years beyond the years asked for the series' own times can widen the zone years.
    static let yearReach = 200

    /// The years whose VTIMEZONE onsets a call needs: the years asked for, widened to the series' start
    /// and its overrides' RECURRENCE-IDs and starts, but never more than `yearReach` years beyond them.
    static func zoneYears(_ series: EventSeries, around asked: ClosedRange<Int>) -> ClosedRange<Int> {
        var times = series.base.map { [$0.start] } ?? []
        for override in series.overrides.prefix(listCap) {
            times.append(override.recurrenceID)
            times.append(override.details.start)
        }
        let years = times.compactMap(\.wallYear)
        let lower = max(min(asked.lowerBound, (years.min() ?? asked.lowerBound) - 1), asked.lowerBound - yearReach)
        let upper = min(max(asked.upperBound, (years.max() ?? asked.upperBound) + 1), asked.upperBound + yearReach)
        return lower...max(upper, lower)
    }
}

/// The work of one `Recurrence.occurrences` call.
private struct Layout {
    let window: Range<Date>
    var book: ClockBook
    var excluded: Set<Int> = []
    /// One override per RECURRENCE-ID: the highest SEQUENCE, and on a tie the later one.
    var overrides: [Int: EventOverride] = [:]
    /// The THISANDFUTURE overrides by their occurrence's identity, earliest first.
    var segments: [Segment] = []
    var seen: Set<Int> = []
    var found: [Occurrence] = []

    init(window: Range<Date>, book: ClockBook) {
        self.window = window
        self.book = book
    }

    var isFull: Bool { found.count >= Recurrence.occurrenceCap }

    /// An instance's identity: its instant, whole seconds.
    mutating func key(_ time: EventTime) -> Int? {
        guard let (wall, clock) = book.locate(time) else { return nil }
        return Int(exactly: clock.instant(of: wall).timeIntervalSince1970.rounded())
    }

    mutating func skip(_ series: EventSeries) {
        excluded = Set(series.exdates.prefix(Recurrence.listCap).compactMap { key($0) })
        for override in series.overrides.prefix(Recurrence.listCap) {
            guard let key = key(override.recurrenceID) else { continue }
            if let kept = overrides[key], kept.details.sequence > override.details.sequence { continue }
            overrides[key] = override
        }
        segments = overrides.compactMap { key, override in
            override.thisAndFuture ? Segment(key: key, override: override, book: &book) : nil
        }.sorted { $0.key < $1.key }
    }

    /// The segment an instance of the series event at `key` falls in: the last range that starts before it.
    fileprivate func segment(after key: Int) -> Segment? {
        var low = 0
        var high = segments.count
        while low < high {
            let middle = low + (high - low) / 2
            if segments.indices.contains(middle), segments[middle].key < key { low = middle + 1 } else { high = middle }
        }
        return segments.indices.contains(low - 1) ? segments[low - 1] : nil
    }

    /// How far, in seconds, the segments move instances earlier and later, and their longest length.
    private var reach: (earlier: Int, later: Int) {
        let earlier = segments.map { max(-$0.shift, 0) }.max() ?? 0
        let later = segments.map { max($0.shift, 0) + $0.shape.length }.max() ?? 0
        return (earlier, later)
    }

    /// The series event's first instance after `key` that is not excluded and has no override of its own,
    /// inside the segment of the range at `key`: before the next range begins.
    mutating func next(after key: Int, base: EventDetails, series: EventSeries)
        -> (recurrenceID: EventTime, instant: Date)? {
        guard let shape = Shape(base, book: &book) else { return nil }
        let limit = segments.first { $0.key > key }?.key
        var best: (recurrenceID: EventTime, instant: Date)?
        func candidate(_ wall: WallTime, clock: ZoneClock, recurrenceID: EventTime) -> Bool {
            let start = shape.occurrence(at: wall, clock: clock, details: base, recurrenceID: nil).start
            guard let found = Int(exactly: start.timeIntervalSince1970.rounded()), found > key,
                  limit.map({ found < $0 }) ?? true,
                  !excluded.contains(found), overrides[found] == nil else { return false }
            if best.map({ start < $0.instant }) ?? true { best = (recurrenceID, start) }
            return true
        }
        if let rule = series.rule {
            let until = rule.until.flatMap { untilWall($0, clock: shape.clock) }
            let from = Date(timeIntervalSince1970: TimeInterval(key))
            let slack = 2 * Civil.secondsPerDay
            let skipTo = shape.clock.wall(at: from)?.adding(seconds: -slack)
            // Wall times run with instants but for a clock change, so the slack covers it at the far end too.
            let stopAfter = limit.flatMap { shape.clock.wall(at: Date(timeIntervalSince1970: TimeInterval($0))) }?
                .adding(seconds: slack) ?? WallTime(seconds: Int.max / 2)
            var budget = RuleExpander.budget
            RuleExpander(rule: rule, start: shape.start, dateOnly: shape.isDate)
                .expand(until: until, stopAfter: stopAfter, skipTo: skipTo, budget: &budget) { wall in
                    if let skipTo, wall < skipTo { return true }
                    return !candidate(wall, clock: shape.clock, recurrenceID: base.start.moved(to: wall))
                }
        }
        for rdate in series.rdates.prefix(Recurrence.listCap) {
            guard let (wall, clock) = book.locate(rdate) else { continue }
            _ = candidate(wall, clock: clock, recurrenceID: rdate)
        }
        return best
    }

    mutating func addSeriesEvent(_ base: EventDetails, series: EventSeries) {
        guard let shape = Shape(base, book: &book) else { return }
        let recurs = series.rule != nil || !series.rdates.isEmpty
        if let rule = series.rule {
            expand(rule, shape: shape, base: base)
        } else {
            offer(shape.start, clock: shape.clock, shape: shape, details: base,
                  recurrenceID: recurs ? base.start : nil)
        }
        for rdate in series.rdates.prefix(Recurrence.listCap) where !isFull {
            guard let (wall, clock) = book.locate(rdate) else { continue }
            offer(wall, clock: clock, shape: shape, details: base, recurrenceID: rdate)
        }
    }

    private mutating func expand(_ rule: RecurrenceRule, shape: Shape, base: EventDetails) {
        let slack = 2 * Civil.secondsPerDay
        let reach = reach
        let stopAfter = WallTime(instant: window.upperBound, offset: slack + reach.earlier)
            ?? WallTime(seconds: Int.max / 2)
        let skipTo = WallTime(instant: window.lowerBound, offset: -slack - reach.later)?
            .adding(seconds: -shape.length)
        let until = rule.until.flatMap { untilWall($0, clock: shape.clock) }
        var budget = RuleExpander.budget
        RuleExpander(rule: rule, start: shape.start, dateOnly: shape.isDate)
            .expand(until: until, stopAfter: stopAfter, skipTo: skipTo, budget: &budget) { wall in
                // Instances counted toward COUNT long before the window need no instant.
                if let skipTo, wall < skipTo { return true }
                return offer(wall, clock: shape.clock, shape: shape, details: base,
                             recurrenceID: base.start.moved(to: wall))
            }
    }

    /// UNTIL as a wall time of the series' clock; a date includes its whole day.
    private mutating func untilWall(_ until: EventTime, clock: ZoneClock) -> WallTime? {
        switch until {
        case let .date(year, month, day):
            return WallTime(year: year, month: month, day: day, hour: 23, minute: 59, second: 59)
        case let .floating(components):
            return WallTime(components)
        case .zoned, .utc:
            guard let (wall, own) = book.locate(until) else { return nil }
            return clock.wall(at: own.instant(of: wall))
        }
    }

    /// Adds one instance of the series event unless it is a duplicate, excluded, overridden or outside the window;
    /// inside a segment it takes the segment's details, length and shift. Returns false once the window is full.
    @discardableResult
    private mutating func offer(_ wall: WallTime, clock: ZoneClock, shape: Shape, details: EventDetails,
                                recurrenceID: EventTime?) -> Bool {
        let occurrence = shape.occurrence(at: wall, clock: clock, details: details, recurrenceID: recurrenceID)
        guard let key = Int(exactly: occurrence.start.timeIntervalSince1970.rounded()),
              seen.insert(key).inserted, !excluded.contains(key), overrides[key] == nil else { return !isFull }
        guard let segment = segment(after: key) else {
            if overlaps(occurrence) { found.append(occurrence) }
            return !isFull
        }
        guard segment.override.details.status != .cancelled,
              let moved = segment.moved(occurrence, recurrenceID: recurrenceID) else { return !isFull }
        if overlaps(moved) { found.append(moved) }
        return !isFull
    }

    /// Adds an overridden occurrence at its own times.
    mutating func add(_ details: EventDetails, recurrenceID: EventTime) {
        guard !isFull, let shape = Shape(details, book: &book) else { return }
        let occurrence = shape.occurrence(at: shape.start, clock: shape.clock, details: details,
                                          recurrenceID: recurrenceID)
        if overlaps(occurrence) { found.append(occurrence) }
    }

    private func overlaps(_ occurrence: Occurrence) -> Bool {
        guard occurrence.end > occurrence.start else { return window.contains(occurrence.start) }
        return occurrence.start < window.upperBound && occurrence.end > window.lowerBound
    }
}

/// An override for its occurrence and every later one, and the shift in wall time it gives them.
private struct Segment {
    let key: Int
    let override: EventOverride
    let shape: Shape
    /// The override's start less its RECURRENCE-ID, as wall times of the override's clock.
    let shift: Int

    init?(key: Int, override: EventOverride, book: inout ClockBook) {
        guard let shape = Shape(override.details, book: &book),
              let (wall, clock) = book.locate(override.recurrenceID),
              let from = shape.clock.wall(at: clock.instant(of: wall)) else { return nil }
        let (difference, overflow) = shape.start.seconds.subtractingReportingOverflow(from.seconds)
        guard !overflow else { return nil }
        self.key = key
        self.override = override
        self.shape = shape
        shift = min(max(difference, -Shape.maxLength), Shape.maxLength)
    }

    /// The range's details for the instance of the series event that starts at `instant`: its start
    /// shifted, its end the range's length later, both the kind of time the range's start is.
    func details(at instant: Date) -> EventDetails? {
        guard let wall = shape.clock.wall(at: instant) else { return nil }
        let (seconds, overflow) = wall.seconds.addingReportingOverflow(shift)
        guard !overflow else { return nil }
        let (last, lastOverflow) = seconds.addingReportingOverflow(shape.length)
        guard !lastOverflow else { return nil }
        guard let start = override.details.start.at(WallTime(seconds: seconds), clock: shape.clock),
              let end = override.details.start.at(WallTime(seconds: last), clock: shape.clock) else { return nil }
        var details = override.details
        details.start = start
        details.end = end
        return details
    }

    /// An instance of the series event as this segment has it.
    func moved(_ instance: Occurrence, recurrenceID: EventTime?) -> Occurrence? {
        guard let wall = shape.clock.wall(at: instance.start) else { return nil }
        let (seconds, overflow) = wall.seconds.addingReportingOverflow(shift)
        guard !overflow else { return nil }
        return shape.occurrence(at: WallTime(seconds: seconds), clock: shape.clock, details: override.details,
                                recurrenceID: recurrenceID)
    }
}

/// An event's start, clock and length, from which each instance's times follow.
private struct Shape {
    let start: WallTime
    let clock: ZoneClock
    let phone: ZoneClock
    let isDate: Bool
    /// Seconds for a timed event, whole days (as seconds) for an all-day one.
    let length: Int

    static let maxLength = 3_660 * Civil.secondsPerDay

    init?(_ details: EventDetails, book: inout ClockBook) {
        guard let (start, clock) = book.locate(details.start) else { return nil }
        self.start = start
        self.clock = clock
        phone = .system(book.phoneZone)
        isDate = details.start.isDate
        let end = book.locate(details.end)
        if isDate {
            let days = end.map { $0.0.dayNumber - start.dayNumber } ?? 1
            length = min(max(days, 1), Self.maxLength / Civil.secondsPerDay) * Civil.secondsPerDay
        } else {
            let begins = clock.instant(of: start)
            let seconds = end.map { $0.1.instant(of: $0.0).timeIntervalSince(begins) } ?? 0
            length = Int(min(max(seconds.rounded(), 0), Double(Self.maxLength)))
        }
    }

    func occurrence(at wall: WallTime, clock: ZoneClock, details: EventDetails, recurrenceID: EventTime?)
        -> Occurrence {
        guard isDate else {
            let begins = clock.instant(of: wall)
            return Occurrence(recurrenceID: recurrenceID, details: details, start: begins,
                              end: begins.addingTimeInterval(TimeInterval(length)))
        }
        let first = WallTime(seconds: wall.dayNumber * Civil.secondsPerDay)
        let last = first.adding(seconds: length)
        return Occurrence(recurrenceID: recurrenceID, details: details, start: phone.instant(of: first),
                          end: phone.instant(of: last), allDayStart: first.date.yyyymmdd,
                          allDayEnd: last.date.yyyymmdd)
    }
}

private extension EventTime {
    /// The same kind of time at another wall time of `clock` (the clock this time was located with);
    /// nil outside the years a calendar date can have.
    func at(_ wall: WallTime, clock: ZoneClock) -> EventTime? {
        guard Civil.years.contains(wall.date.year) else { return nil }
        switch self {
        case .date:
            let date = wall.date
            return .date(year: date.year, month: date.month, day: date.day)
        case .floating: return .floating(wall.components)
        case let .zoned(_, zone): return .zoned(wall.components, zone: zone)
        case .utc: return .utc(clock.instant(of: wall))
        }
    }

    /// The year of its wall clock (UTC's for a UTC time); enough to pick the years whose zone rules apply.
    var wallYear: Int? {
        let wall: WallTime? = switch self {
        case let .date(year, month, day): WallTime(year: year, month: month, day: day)
        case let .floating(components), let .zoned(components, _): WallTime(components)
        case let .utc(date): WallTime(instant: date, offset: 0)
        }
        return wall?.date.year
    }
}
