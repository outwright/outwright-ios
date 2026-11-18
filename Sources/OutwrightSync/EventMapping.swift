// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
public import OutwrightDAV
public import OutwrightModel

/// Between the iCalendar objects the DAV layer reads and the series the model keeps: what a
/// calendar object says, and the owner's edits written into it. Editing rewrites only the properties
/// the app shows and keeps every other component, property and parameter as it came.
public enum EventMapping {
    /// RDATE and EXDATE values read per series.
    static let listCap = 5_000

    /// The calendar object's events, one series per UID in the order first seen. The VEVENT without
    /// RECURRENCE-ID is the series event; the others are its overridden occurrences, of this and every
    /// later occurrence when RANGE=THISANDFUTURE (the obsolete THISANDPRIOR is read as no range). TZIDs
    /// resolve through the object's VTIMEZONEs. A VEVENT without a UID or a readable DTSTART is left out.
    public static func series(_ calendar: ICalComponent) -> [EventSeries] {
        let zones = zones(calendar)
        var order: [String] = []
        var found: [String: EventSeries] = [:]
        for event in calendar.components where event.name == "VEVENT" {
            guard let uid = event.first("UID")?.value, !uid.isEmpty,
                let details = details(event, zones: zones)
            else { continue }
            var series = found[uid] ?? EventSeries(uid: uid, base: nil, zones: zones)
            if found[uid] == nil { order.append(uid) }
            if let recurrence = event.first("RECURRENCE-ID") {
                if let time = ICalValue.time(recurrence, zones: zones) {
                    let range = recurrence.parameter("RANGE")?.trimmingCharacters(in: .whitespaces).uppercased()
                    series.overrides.append(
                        EventOverride(recurrenceID: time, details: details, thisAndFuture: range == "THISANDFUTURE"))
                }
            } else if series.base == nil {
                series.base = details
                series.rule = event.first("RRULE").flatMap { RecurrenceRule.parse($0.value) }
                series.rdates = event.all("RDATE").flatMap { ICalValue.times($0, zones: zones, limit: listCap) }
                series.exdates = event.all("EXDATE").flatMap { ICalValue.times($0, zones: zones, limit: listCap) }
            }
            found[uid] = series
        }
        return order.compactMap { found[$0] }
    }

    /// What one VEVENT says; nil without a readable DTSTART.
    static func details(_ event: ICalComponent, zones: [String: ZoneRules]) -> EventDetails? {
        guard let startLine = event.first("DTSTART"), let start = ICalValue.time(startLine, zones: zones) else {
            return nil
        }
        var details = EventDetails(
            title: event.first("SUMMARY")?.text ?? "", place: event.first("LOCATION")?.text ?? "",
            notes: event.first("DESCRIPTION")?.text ?? "", start: start, end: end(event, start: start, zones: zones))
        details.reminder = reminder(event)
        details.organizer = event.first("ORGANIZER").map { address($0.value) }
        details.attendees = event.all("ATTENDEE").map(attendee)
        switch event.first("STATUS")?.value.uppercased() {
        case "TENTATIVE": details.status = .tentative
        case "CANCELLED": details.status = .cancelled
        default: details.status = .confirmed
        }
        details.showAs = showAs(event)
        let privacy = event.first("CLASS")?.value.trimmingCharacters(in: .whitespaces).uppercased()
        details.isPrivate = privacy == "PRIVATE" || privacy == "CONFIDENTIAL"
        details.sequence = event.first("SEQUENCE").flatMap { Int($0.value.trimmingCharacters(in: .whitespaces)) }
            .map { min(max($0, 0), 1_000_000) } ?? 0
        return details
    }

    /// The vendor property X-MICROSOFT-CDO-BUSYSTATUS where it says one of its four values (the only common
    /// carrier of tentative and away), else TRANSP (RFC 5545 › 3.8.2.7).
    static func showAs(_ event: ICalComponent) -> ShowAs {
        switch event.first(busyStatus)?.value.trimmingCharacters(in: .whitespaces).uppercased() {
        case "BUSY": return .busy
        case "FREE": return .free
        case "TENTATIVE": return .tentative
        case "OOF": return .away
        default:
            let transp = event.first("TRANSP")?.value.trimmingCharacters(in: .whitespaces).uppercased()
            return transp == "TRANSPARENT" ? .free : .busy
        }
    }

    static let busyStatus = "X-MICROSOFT-CDO-BUSYSTATUS"

    /// DTEND, else DTSTART plus DURATION, else a day for an all-day event and no time at all for one
    /// with a time.
    private static func end(_ event: ICalComponent, start: EventTime, zones: [String: ZoneRules]) -> EventTime {
        if let line = event.first("DTEND"), let end = ICalValue.time(line, zones: zones) {
            return end
        }
        if let text = event.first("DURATION")?.value, let parts = ICalValue.durationParts(text), parts.days >= 0,
            parts.seconds >= 0 {
            return adding(days: parts.days, seconds: parts.seconds, to: start, zones: zones)
        }
        if case .date = start {
            return adding(days: 1, seconds: 0, to: start, zones: zones)
        }
        return start
    }

    /// The time `days` calendar days later, then `seconds` of real time later. A date moves by whole
    /// days. A zoned time keeps its zone when the system knows it, else becomes UTC; a floating time has
    /// no zone to count real time in, so its seconds move the wall clock.
    static func adding(days: Int, seconds: Int, to time: EventTime, zones: [String: ZoneRules]) -> EventTime {
        let calendar = ICalValue.wallCalendar
        switch time {
        case let .date(year, month, day):
            let start = calendar.date(from: DateComponents(year: year, month: month, day: day))
            guard let moved = start.flatMap({ calendar.date(byAdding: .day, value: days, to: $0) })
            else { return time }
            let parts = calendar.dateComponents([.year, .month, .day], from: moved)
            return .date(year: parts.year ?? year, month: parts.month ?? month, day: parts.day ?? day)
        case let .floating(wall):
            return .floating(moved(wall, days * 86_400 + seconds) ?? wall)
        case let .zoned(wall, zone):
            let shifted = moved(wall, days * 86_400) ?? wall
            guard seconds != 0 else { return .zoned(shifted, zone: zone) }
            guard let instant = EventTime.zoned(shifted, zone: zone).instant(in: ICalValue.utcZone, zones: zones)
            else { return .zoned(shifted, zone: zone) }
            let end = instant.addingTimeInterval(Double(seconds))
            guard let system = TimeZone(identifier: zone) else { return .utc(end) }
            let parts = Calendar(identifier: .gregorian).dateComponents(in: system, from: end)
            let local = EventTime.zoned(
                DateComponents(
                    year: parts.year, month: parts.month, day: parts.day, hour: parts.hour, minute: parts.minute,
                    second: parts.second), zone: zone)
            // A wall time the clock shows twice (the hour put back) reads as its first pass: an end in the
            // second stays the exact instant.
            return local.instant(in: ICalValue.utcZone, zones: zones) == end ? local : .utc(end)
        case let .utc(date):
            return .utc(date.addingTimeInterval(Double(days * 86_400 + seconds)))
        }
    }

    private static func moved(_ wall: DateComponents, _ seconds: Int) -> DateComponents? {
        let calendar = ICalValue.wallCalendar
        guard let date = calendar.date(from: wall) else { return nil }
        let parts = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date.addingTimeInterval(Double(seconds)))
        return DateComponents(
            year: parts.year, month: parts.month, day: parts.day, hour: parts.hour, minute: parts.minute,
            second: parts.second)
    }

    /// The minutes before the start of the first alarm set relative to the start and not after it.
    /// Absolute alarms and alarms after the start or relative to the end are kept but not shown.
    private static func reminder(_ event: ICalComponent) -> Int? {
        event.components.lazy.compactMap(alarmMinutes).first
    }

    static func alarmMinutes(_ alarm: ICalComponent) -> Int? {
        guard alarm.name == "VALARM", let trigger = alarm.first("TRIGGER"),
            trigger.parameter("VALUE").map({ $0.uppercased() == "DURATION" }) ?? true,
            trigger.parameter("RELATED").map({ $0.uppercased() == "START" }) ?? true,
            let seconds = ICalValue.duration(trigger.value), seconds <= 0
        else { return nil }
        return -seconds / 60
    }

    /// The address of a `mailto:` value.
    static func address(_ value: String) -> String {
        let text = value.trimmingCharacters(in: .whitespaces)
        if text.lowercased().hasPrefix("mailto:") {
            return String(text.dropFirst("mailto:".count))
        }
        return text
    }

    private static func attendee(_ line: ICalProperty) -> Attendee {
        let response: Attendee.Response
        switch line.parameter("PARTSTAT")?.uppercased() {
        case "ACCEPTED": response = .accepted
        case "TENTATIVE": response = .tentative
        case "DECLINED": response = .declined
        case "DELEGATED": response = .delegated
        default: response = .needsAction
        }
        return Attendee(
            email: address(line.value), name: line.parameter("CN") ?? "", response: response,
            role: line.parameter("ROLE")?.uppercased() ?? "REQ-PARTICIPANT",
            rsvp: line.parameter("RSVP")?.uppercased() == "TRUE")
    }
}
