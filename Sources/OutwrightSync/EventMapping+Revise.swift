// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightDAV
import OutwrightModel

extension EventMapping {
    /// The VEVENT with what changed from `old` to `new` written into it, property by property; a
    /// property that did not change stays as it came, with its parameters.
    static func revised(
        _ event: ICalComponent, from old: EventDetails?, to new: EventDetails, organizer: String
    ) -> ICalComponent {
        var event = event
        if old?.title != new.title { event = text(event, "SUMMARY", new.title) }
        if old?.place != new.place { event = text(event, "LOCATION", new.place) }
        if old?.notes != new.notes { event = text(event, "DESCRIPTION", new.notes) }
        if old?.start != new.start || old?.end != new.end {
            event = event.replacing("DTSTART", with: [ICalValue.property("DTSTART", new.start)])
                .replacing("DTEND", with: [ICalValue.property("DTEND", new.end)]).replacing("DURATION", with: [])
        }
        if old?.reminder != new.reminder { event = alarmed(event, new.reminder) }
        if old?.attendees != new.attendees { event = people(event, new.attendees, organizer: organizer) }
        return marked(event, from: old, to: new)
    }

    /// STATUS and TRANSP, when they changed.
    private static func marked(_ event: ICalComponent, from old: EventDetails?, to new: EventDetails) -> ICalComponent {
        var event = event
        if old?.status != new.status {
            let status = switch new.status {
            case .confirmed: "CONFIRMED"
            case .tentative: "TENTATIVE"
            case .cancelled: "CANCELLED"
            }
            event = event.replacing("STATUS", with: [ICalProperty(name: "STATUS", value: status)])
        }
        if old?.transparency != new.transparency {
            let transparency = new.transparency == .free ? "TRANSPARENT" : "OPAQUE"
            event = event.replacing("TRANSP", with: [ICalProperty(name: "TRANSP", value: transparency)])
        }
        return event
    }

    /// Three ways, as contacts are merged: the server's details (`theirs`), with every field the owner
    /// changed from `base` (what was first sent) taken from `ours`. A field both changed takes the
    /// owner's. Start and end go together.
    static func merged(base: EventDetails, ours: EventDetails, theirs: EventDetails) -> EventDetails {
        var result = theirs
        func take<T: Equatable>(_ path: WritableKeyPath<EventDetails, T>) {
            if ours[keyPath: path] != base[keyPath: path] { result[keyPath: path] = ours[keyPath: path] }
        }
        take(\.title)
        take(\.place)
        take(\.notes)
        take(\.reminder)
        take(\.attendees)
        take(\.status)
        take(\.transparency)
        if ours.start != base.start || ours.end != base.end {
            result.start = ours.start
            result.end = ours.end
        }
        return result
    }

    /// A TEXT property set to `value`, its group and parameters kept (but an ALTREP, which named the
    /// old text); gone when the value is empty.
    private static func text(_ event: ICalComponent, _ name: String, _ value: String) -> ICalComponent {
        guard !value.isEmpty else { return event.replacing(name, with: []) }
        let held = event.first(name)
        let parameters = (held?.parameters ?? []).filter { $0.name != "ALTREP" }
        return event.replacing(name, with: [
            ICalProperty(group: held?.group, name: name, parameters: parameters, text: value)
        ])
    }

    /// The first alarm shown (relative to the start, not after it) set to `minutes` before the start, or
    /// removed; one is added when there was none. Every other alarm stays.
    static func alarmed(_ event: ICalComponent, _ minutes: Int?) -> ICalComponent {
        var event = event
        let trigger = minutes.map { ICalProperty(name: "TRIGGER", value: ICalValue.trigger(minutes: $0)) }
        if let index = event.components.firstIndex(where: { alarmMinutes($0) != nil }) {
            if let trigger {
                event.components[index] = event.components[index].replacing("TRIGGER", with: [trigger])
            } else {
                event.components.remove(at: index)
            }
        } else if let trigger {
            event.components.append(ICalComponent(name: "VALARM", properties: [
                ICalProperty(name: "ACTION", value: "DISPLAY"), ICalProperty(name: "DESCRIPTION", text: "Reminder"),
                trigger
            ]))
        }
        return event
    }

    /// ATTENDEE lines for `attendees`: a line already held for an address stays as it came (its
    /// PARTSTAT and SCHEDULE- parameters are the server's), a new one asks for an answer. ORGANIZER is
    /// there only with attendees: the one held, else the account.
    private static func people(_ event: ICalComponent, _ attendees: [Attendee], organizer: String) -> ICalComponent {
        var held: [String: ICalProperty] = [:]
        for line in event.all("ATTENDEE") {
            let key = address(line.value).lowercased()
            if held[key] == nil { held[key] = line }
        }
        let lines = attendees.map { held[$0.email.lowercased()] ?? attendeeLine($0) }
        var result = event.replacing("ATTENDEE", with: lines)
        if attendees.isEmpty {
            result = result.replacing("ORGANIZER", with: [])
        } else if result.first("ORGANIZER") == nil {
            let line = ICalProperty(name: "ORGANIZER", value: "mailto:" + organizer)
            result = result.replacing("ATTENDEE", with: [line] + lines)
        }
        return result
    }

    private static func attendeeLine(_ person: Attendee) -> ICalProperty {
        var parameters: [ContentParameter] = []
        if !person.name.isEmpty { parameters.append(ContentParameter(name: "CN", values: [person.name])) }
        let response = switch person.response {
        case .needsAction: "NEEDS-ACTION"
        case .accepted: "ACCEPTED"
        case .tentative: "TENTATIVE"
        case .declined: "DECLINED"
        case .delegated: "DELEGATED"
        }
        parameters += [
            ContentParameter(name: "ROLE", values: [person.role.isEmpty ? "REQ-PARTICIPANT" : person.role]),
            ContentParameter(name: "PARTSTAT", values: [response]),
            ContentParameter(name: "RSVP", values: ["TRUE"])
        ]
        return ICalProperty(name: "ATTENDEE", parameters: parameters, value: "mailto:" + person.email)
    }

    /// The calendar with a VTIMEZONE for every zone its events name that the system knows and the
    /// object does not define yet (placed before the first event).
    static func withZones(_ calendar: ICalComponent) -> ICalComponent {
        let defined = Set(
            calendar.components.filter { $0.name == "VTIMEZONE" }.compactMap { $0.first("TZID")?.value })
        let timed: Set<String> = ["DTSTART", "DTEND", "RECURRENCE-ID", "EXDATE", "RDATE"]
        var needed: [(String, Int)] = []
        for event in calendar.components where event.name == "VEVENT" {
            for line in event.properties where timed.contains(line.name) {
                guard let tzid = line.parameter("TZID"), !defined.contains(tzid),
                    !needed.contains(where: { $0.0 == tzid })
                else { continue }
                let year = ICalValue.dateTime(line.value.prefix(15))?.wall.year ?? 2026
                needed.append((tzid, year))
            }
        }
        var result = calendar
        let place = result.components.firstIndex { $0.name == "VEVENT" } ?? result.components.endIndex
        let zones = needed.prefix(zoneCap).compactMap { vtimezone($0.0, year: $0.1) }
        result.components.insert(contentsOf: zones, at: place)
        return result
    }
}
