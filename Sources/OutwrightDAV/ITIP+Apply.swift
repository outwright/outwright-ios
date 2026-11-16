// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// Applying an iTIP message to the stored copy, and the owner's PARTSTAT.
extension ITIP {
    /// The properties that, changed, make an update ask for the owner's answer again.
    static let timing = ["DTSTART", "DTEND", "DURATION", "RRULE", "RDATE", "EXDATE"]

    /// The stored copy after `message`, without METHOD (a calendar resource carries none).
    ///
    /// REQUEST and ADD: the message's VEVENTs replace the stored ones with the same RECURRENCE-ID or
    /// are added; the owner's PARTSTAT is kept when the timing is unchanged, else NEEDS-ACTION; the
    /// owner's VALARMs are kept. With nothing stored, the message's calendar with the owner's
    /// PARTSTAT as given or NEEDS-ACTION. CANCEL: the occurrence (or, without RECURRENCE-ID, every
    /// VEVENT) gets `STATUS:CANCELLED`. A REPLY changes nothing here.
    public static func applying(_ message: ITIPMessage, to stored: ICalComponent?, ownEmail: String) -> ICalComponent {
        let incoming = events(message.calendar)
        switch message.method {
        case .request, .add:
            guard let stored else {
                var fresh = message.calendar.replacing("METHOD", with: [])
                fresh.components = fresh.components.map { $0.name == "VEVENT" ? invited($0, ownEmail) : $0 }
                return fresh
            }
            return updating(stored.replacing("METHOD", with: []), with: incoming, zones: message.calendar,
                            ownEmail: ownEmail)
        case .cancel:
            let base = (stored ?? message.calendar).replacing("METHOD", with: [])
            return cancelling(base, incoming)
        case .reply:
            return (stored ?? message.calendar).replacing("METHOD", with: [])
        }
    }

    private static func updating(_ stored: ICalComponent, with incoming: [ICalComponent], zones: ICalComponent,
                                 ownEmail: String) -> ICalComponent {
        var result = stored
        for event in incoming {
            let wanted = key(event.first("RECURRENCE-ID"))
            if let index = result.components.firstIndex(where: {
                $0.name == "VEVENT" && key($0.first("RECURRENCE-ID")) == wanted
            }), result.components.indices.contains(index) {
                result.components[index] = updated(event, from: result.components[index], ownEmail)
            } else {
                result.components.append(invited(event, ownEmail))
            }
        }
        // A zone the update names and the stored copy lacks goes in before the events.
        let have = Set(result.components.filter { $0.name == "VTIMEZONE" }.compactMap { $0.first("TZID")?.value })
        let missing = zones.components.filter {
            $0.name == "VTIMEZONE" && $0.first("TZID").map { !have.contains($0.value) } == true
        }
        let zoneEnd = result.components.firstIndex { $0.name != "VTIMEZONE" } ?? result.components.endIndex
        result.components.insert(contentsOf: missing, at: zoneEnd)
        return result
    }

    /// An update of `old`: the owner's answer kept unless the time moved, the owner's alarms kept.
    private static func updated(_ event: ICalComponent, from old: ICalComponent, _ ownEmail: String) -> ICalComponent {
        let sameTime = timing.allSatisfy { event.all($0) == old.all($0) }
        let answered = old.all("ATTENDEE").first { isOwn($0, ownEmail) }?.parameter("PARTSTAT").map(token)
        var result = event
        if sameTime, let answered, !answered.isEmpty {
            result = withOwnPartstat(result, answered, ownEmail, dropRSVP: answered != "NEEDS-ACTION")
        } else {
            result = withOwnPartstat(result, "NEEDS-ACTION", ownEmail, dropRSVP: false)
        }
        result.components = event.components.filter { $0.name != "VALARM" }
            + old.components.filter { $0.name == "VALARM" }
        return result
    }

    /// A VEVENT new to the calendar: the owner's PARTSTAT as given, or NEEDS-ACTION.
    private static func invited(_ event: ICalComponent, _ ownEmail: String) -> ICalComponent {
        guard let own = event.all("ATTENDEE").first(where: { isOwn($0, ownEmail) }), own.parameter("PARTSTAT") == nil
        else { return event }
        return withOwnPartstat(event, "NEEDS-ACTION", ownEmail, dropRSVP: false)
    }

    private static func cancelling(_ stored: ICalComponent, _ incoming: [ICalComponent]) -> ICalComponent {
        var result = stored
        if incoming.contains(where: { $0.first("RECURRENCE-ID") == nil }) {
            result.components = result.components.map { $0.name == "VEVENT" ? cancelled($0) : $0 }
            return result
        }
        for recurrenceID in incoming.compactMap({ $0.first("RECURRENCE-ID") }) {
            let wanted = key(recurrenceID)
            if let index = result.components.firstIndex(where: {
                $0.name == "VEVENT" && key($0.first("RECURRENCE-ID")) == wanted
            }), result.components.indices.contains(index) {
                result.components[index] = cancelled(result.components[index])
            } else if let series = seriesEvent(result) {
                result.components.append(cancelled(occurrence(of: series, at: recurrenceID)))
            }
        }
        return result
    }

    private static func cancelled(_ event: ICalComponent) -> ICalComponent {
        event.replacing("STATUS", with: [ICalProperty(name: "STATUS", value: "CANCELLED")])
    }

    /// The owner's PARTSTAT set to `partstat` (RSVP removed, SEQUENCE untouched): on the series, or
    /// on the override for `recurrenceID`, made from the series' occurrence when there is none.
    public static func settingPartstat(_ partstat: String, in calendar: ICalComponent, ownEmail: String,
                                       recurrenceID: ICalProperty?) -> ICalComponent {
        let answer = token(partstat)
        guard !answer.isEmpty else { return calendar }
        var result = calendar
        guard let recurrenceID else {
            // The series; an invitation to occurrences only has no series, so each of them.
            let hasBase = seriesEvent(calendar) != nil
            result.components = calendar.components.map { component in
                guard component.name == "VEVENT", !hasBase || component.first("RECURRENCE-ID") == nil
                else { return component }
                return withOwnPartstat(component, answer, ownEmail, dropRSVP: true)
            }
            return result
        }
        let wanted = key(recurrenceID)
        if let index = result.components.firstIndex(where: {
            $0.name == "VEVENT" && key($0.first("RECURRENCE-ID")) == wanted
        }), result.components.indices.contains(index) {
            result.components[index] = withOwnPartstat(result.components[index], answer, ownEmail, dropRSVP: true)
            return result
        }
        guard let series = seriesEvent(calendar), series.all("ATTENDEE").contains(where: { isOwn($0, ownEmail) })
        else { return calendar }
        result.components.append(withOwnPartstat(occurrence(of: series, at: recurrenceID), answer, ownEmail,
                                                 dropRSVP: true))
        return result
    }

    /// `event` with the owner's ATTENDEE at `partstat`, through `replacing`; unchanged without one.
    static func withOwnPartstat(_ event: ICalComponent, _ partstat: String, _ ownEmail: String,
                                dropRSVP: Bool) -> ICalComponent {
        let attendees = event.all("ATTENDEE")
        guard attendees.contains(where: { isOwn($0, ownEmail) }) else { return event }
        return event.replacing("ATTENDEE", with: attendees.map { attendee in
            guard isOwn(attendee, ownEmail) else { return attendee }
            var line = attendee
            line.parameters = line.parameters.filter { $0.name != "PARTSTAT" && (!dropRSVP || $0.name != "RSVP") }
            if let index = attendee.parameters.firstIndex(where: { $0.name == "PARTSTAT" }),
               index <= line.parameters.count {
                line.parameters.insert(ContentParameter(name: "PARTSTAT", values: [partstat]), at: index)
            } else {
                line.parameters.append(ContentParameter(name: "PARTSTAT", values: [partstat]))
            }
            return line
        })
    }

    /// One occurrence of the series as an override: the series' VEVENT without its recurrence,
    /// starting at `recurrenceID` and lasting as long.
    static func occurrence(of series: ICalComponent, at recurrenceID: ICalProperty) -> ICalComponent {
        var parameters = recurrenceID.parameters.filter { $0.name != "RANGE" }
        let start = ICalProperty(name: "DTSTART", parameters: parameters, value: recurrenceID.value)
        var override = series.replacing("RRULE", with: []).replacing("RDATE", with: []).replacing("EXDATE", with: [])
            .replacing("DTSTART", with: [start])
            .replacing("RECURRENCE-ID", with: [ICalProperty(name: "RECURRENCE-ID", parameters: parameters,
                                                            value: recurrenceID.value)])
        // A DURATION, or a DTEND that cannot be measured, stays as the series has it.
        if let from = series.first("DTSTART").flatMap({ ICalTime.parse($0.value) }),
           let to = series.first("DTEND").flatMap({ ICalTime.parse($0.value) }),
           let first = ICalTime.parse(recurrenceID.value) {
            let length = max(0, to.date.timeIntervalSince(from.date))
            if first.form == .date { parameters = parameters.filter { $0.name != "TZID" } }
            override = override.replacing("DTEND", with: [ICalProperty(
                name: "DTEND", parameters: parameters,
                value: ICalTime.format(first.date.addingTimeInterval(length), form: first.form))])
        }
        return override
    }
}

/// An iCalendar DATE or DATE-TIME value, read as its digits say (a local time as if it were UTC,
/// which is enough to measure a length and to order stamps).
enum ICalTime {
    enum Form: Equatable { case date, local, utc }

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
        return calendar
    }()

    static func parse(_ text: String) -> (date: Date, form: Form)? {
        let value = Array(text.trimmingCharacters(in: .whitespaces).uppercased().utf8)
        let form: Form
        switch value.count {
        case 8: form = .date
        case 15: form = .local
        case 16 where value.last == UInt8(ascii: "Z"): form = .utc
        default: return nil
        }
        func number(_ range: Range<Int>) -> Int? {
            guard range.upperBound <= value.count else { return nil }
            var result = 0
            for byte in value[range] {
                guard byte >= 0x30, byte <= 0x39 else { return nil }
                result = result * 10 + Int(byte - 0x30)
            }
            return result
        }
        var parts = DateComponents()
        guard let year = number(0..<4), let month = number(4..<6), let day = number(6..<8),
              (1...12).contains(month), (1...31).contains(day)
        else { return nil }
        (parts.year, parts.month, parts.day) = (year, month, day)
        if form != .date {
            guard value.count >= 15, value[8] == UInt8(ascii: "T"), let hour = number(9..<11),
                  let minute = number(11..<13), let second = number(13..<15),
                  hour < 24, minute < 60, second <= 60
            else { return nil }
            (parts.hour, parts.minute, parts.second) = (hour, minute, second)
        }
        return calendar.date(from: parts).map { ($0, form) }
    }

    static func format(_ date: Date, form: Form) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        func two(_ value: Int?) -> String {
            let number = min(max(value ?? 0, 0), 99)
            return number < 10 ? "0\(number)" : "\(number)"
        }
        let year = min(max(parts.year ?? 0, 0), 9_999)
        let day = String(repeating: "0", count: max(0, 4 - String(year).count)) + "\(year)"
            + two(parts.month) + two(parts.day)
        guard form != .date else { return day }
        return day + "T" + two(parts.hour) + two(parts.minute) + two(parts.second) + (form == .utc ? "Z" : "")
    }
}
