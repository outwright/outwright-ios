// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

@testable import OutwrightModel

enum Cal {
    static let stockholm = TimeZone(identifier: "Europe/Stockholm") ?? .gmt
    static let newYork = TimeZone(identifier: "America/New_York") ?? .gmt

    static func wall(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> DateComponents {
        DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: 0)
    }

    static func instant(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0,
                        in zone: TimeZone = stockholm) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: wall(year, month, day, hour, minute)) ?? .distantPast
    }

    static func local(_ date: Date, in zone: TimeZone = stockholm) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    }

    static func details(_ start: EventTime, _ end: EventTime, title: String = "Standup",
                        status: EventStatus = .confirmed) -> EventDetails {
        EventDetails(title: title, start: start, end: end, status: status)
    }

    /// A one-hour event at the given wall time in Stockholm.
    static func hour(_ comps: DateComponents, zone: String = "Europe/Stockholm", title: String = "Standup",
                     status: EventStatus = .confirmed) -> EventDetails {
        var end = comps
        end.hour = (comps.hour ?? 0) + 1
        return details(.zoned(comps, zone: zone), .zoned(end, zone: zone), title: title, status: status)
    }

    static func series(_ base: EventDetails?, rule: String? = nil, rdates: [EventTime] = [],
                       exdates: [EventTime] = [],
                       overrides: [EventOverride] = [],
                       zones: [String: ZoneRules] = [:]) -> EventSeries {
        EventSeries(
            uid: "uid@example.org", base: base, rule: rule.flatMap(RecurrenceRule.parse), rdates: rdates,
            exdates: exdates, overrides: overrides, zones: zones)
    }
}
