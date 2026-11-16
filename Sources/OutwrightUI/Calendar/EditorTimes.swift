// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightModel

/// Wall-clock arithmetic for the event editor: an `EventTime` read as the wall time it names, moved by
/// seconds of wall time, and written back as the same kind of time.
enum EditorTimes {
    /// Gregorian in UTC: wall times are counted on it as if they were UTC.
    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

    /// The wall time a value names: midnight for a date, the UTC clock for a UTC time.
    static func wall(_ time: EventTime) -> DateComponents {
        switch time {
        case let .date(year, month, day):
            DateComponents(year: year, month: month, day: day, hour: 0, minute: 0, second: 0)
        case let .floating(wall), let .zoned(wall, _):
            DateComponents(
                year: wall.year, month: wall.month, day: wall.day, hour: wall.hour ?? 0, minute: wall.minute ?? 0,
                second: wall.second ?? 0)
        case let .utc(date):
            utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        }
    }

    /// Seconds of wall time from 1970, nil for a wall time that is no date.
    static func seconds(_ wall: DateComponents) -> Int? {
        guard let date = utc.date(from: wall), date.timeIntervalSince1970.magnitude < 300_000_000_000 else {
            return nil
        }
        return Int(exactly: date.timeIntervalSince1970.rounded(.down))
    }

    static func components(_ seconds: Int) -> DateComponents {
        utc.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: Date(timeIntervalSince1970: TimeInterval(seconds)))
    }

    /// The same kind of time as `template` at another wall time.
    static func make(like template: EventTime, wall: DateComponents) -> EventTime {
        switch template {
        case .date: .date(year: wall.year ?? 1970, month: wall.month ?? 1, day: wall.day ?? 1)
        case .floating: .floating(wall)
        case let .zoned(_, zone): .zoned(wall, zone: zone)
        case .utc: .utc(utc.date(from: wall) ?? Date(timeIntervalSince1970: 0))
        }
    }

    /// The same kind of time as `template` at an instant (read in `phone` for a date or floating time).
    static func make(like template: EventTime, at instant: Date, phone: Calendar) -> EventTime {
        switch template {
        case .date:
            let day = phone.dateComponents([.year, .month, .day], from: instant)
            return .date(year: day.year ?? 1970, month: day.month ?? 1, day: day.day ?? 1)
        case .floating:
            return .floating(clock(instant, in: phone.timeZone))
        case let .zoned(_, zone):
            return .zoned(clock(instant, in: zoneNamed(zone) ?? phone.timeZone), zone: zone)
        case .utc:
            return .utc(instant)
        }
    }

    /// The wall clock of an instant in a zone, to the minute.
    static func clock(_ instant: Date, in zone: TimeZone) -> DateComponents {
        var calendar = utc
        calendar.timeZone = zone
        var wall = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: instant)
        wall.second = 0
        return wall
    }

    /// `time` moved by `delta` seconds of wall time, as the kind of `template`.
    static func moved(_ time: EventTime, by delta: Int, like template: EventTime) -> EventTime? {
        guard let start = seconds(wall(time)) else { return nil }
        let (sum, overflow) = start.addingReportingOverflow(delta)
        guard !overflow else { return nil }
        return make(like: template, wall: components(sum))
    }

    /// Wall seconds from `from` to `to`, each read as the wall time it names.
    static func distance(from: EventTime, to: EventTime) -> Int? {
        guard let start = seconds(wall(from)), let end = seconds(wall(to)) else { return nil }
        let (difference, overflow) = end.subtractingReportingOverflow(start)
        return overflow ? nil : difference
    }

    /// A zone Foundation knows by the name, or by the IANA name a Windows name stands for.
    static func zoneNamed(_ tzid: String) -> TimeZone? {
        if case let .iana(id) = ZoneResolver.resolve(tzid: tzid, given: [:]) { return TimeZone(identifier: id) }
        return TimeZone(identifier: tzid)
    }

    /// ISO weekday (1 = Monday ... 7 = Sunday) of a date in the phone's calendar.
    static func isoWeekday(_ date: Date, _ phone: Calendar) -> Int {
        (phone.component(.weekday, from: date) + 5) % 7 + 1
    }
}
