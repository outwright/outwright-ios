// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation

/// A DTSTART, DTEND, RECURRENCE-ID, RDATE or EXDATE value.
public enum EventTime: Sendable, Equatable, Codable {
    /// An all-day date.
    case date(year: Int, month: Int, day: Int)
    /// Local wall time with no zone: it follows the phone.
    case floating(DateComponents)
    /// Wall time in a zone (an IANA id, or a TZID the series' VTIMEZONEs define).
    case zoned(DateComponents, zone: String)
    case utc(Date)

    /// The instant this time names on a phone in `phoneZone`; nil when the time is not a valid date.
    /// `zones` are the calendar object's VTIMEZONEs by TZID: a `.zoned` time whose zone neither the
    /// system nor the Windows table knows is read through them, and is phone-local without them.
    public func instant(in phoneZone: TimeZone, zones: [String: ZoneRules] = [:]) -> Date? {
        // A VTIMEZONE's onsets are expanded around the time's own year only (as `Recurrence` does).
        var book = ClockBook(phoneZone: phoneZone, zones: zones, years: nearYears)
        guard let (wall, clock) = book.locate(self) else { return nil }
        return clock.instant(of: wall)
    }

    /// The year of the time and those either side, within `Civil.years`; all of them when it has none.
    private var nearYears: ClosedRange<Int> {
        let year: Int? = switch self {
        case let .date(year, _, _): year
        case let .floating(wall), let .zoned(wall, _): wall.year
        case let .utc(date): WallTime(instant: date, offset: 0)?.date.year
        }
        guard let year, Civil.years.contains(year) else { return Civil.years }
        return max(year - 1, Civil.years.lowerBound)...min(year + 1, Civil.years.upperBound)
    }

    var isDate: Bool {
        if case .date = self { return true }
        return false
    }

    /// The same kind of time at another wall time of the same clock.
    func moved(to wall: WallTime) -> EventTime {
        switch self {
        case .date:
            let date = wall.date
            return .date(year: date.year, month: date.month, day: date.day)
        case .floating: return .floating(wall.components)
        case let .zoned(_, zone): return .zoned(wall.components, zone: zone)
        case .utc: return .utc(Date(timeIntervalSince1970: TimeInterval(wall.seconds)))
        }
    }
}
