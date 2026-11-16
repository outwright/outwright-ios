// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
public import OutwrightModel

/// The owner's edits as Graph event JSON.
extension GraphEventMapping {
    /// The JSON to send for `details` (with `rule`, for a series or a new event). Over a held server
    /// copy only what differs from it goes, so an unedited HTML body and unedited attendees (and their
    /// invitations) are left alone; with none, everything goes (a create). Times are written as wall
    /// time in the event's zone by its Windows name (else its IANA id, else UTC).
    public static func body(
        _ details: EventDetails, rule: RecurrenceRule?, over held: (base: EventDetails?, rule: RecurrenceRule?)?,
        phoneZone: TimeZone
    ) -> [String: any Sendable] {
        let old = held?.base
        var body: [String: any Sendable] = [:]
        // The editor trims what it saves; Graph's text often has line breaks around it.
        let trim = { (text: String?) in text?.trimmingCharacters(in: .whitespacesAndNewlines) }
        if trim(old?.title) != trim(details.title) { body["subject"] = details.title }
        if trim(old?.notes) != trim(details.notes) { body["body"] = ["contentType": "text", "content": details.notes] }
        if trim(old?.place) != trim(details.place) { body["location"] = ["displayName": details.place] }
        let zone = zoneName(details.start, phoneZone: phoneZone)
        let moved = old?.start != details.start || old?.end != details.end
        if moved {
            body["start"] = graphTime(details.start, zone: zone, phoneZone: phoneZone)
            let endZone = zoneName(details.end, phoneZone: phoneZone)
            body["end"] = graphTime(details.end, zone: endZone, phoneZone: phoneZone)
            body["isAllDay"] = details.start.isAllDay
        }
        if held == nil || old?.reminder != details.reminder {
            body["isReminderOn"] = details.reminder != nil
            if let reminder = details.reminder { body["reminderMinutesBeforeStart"] = reminder }
        }
        if old?.attendees != details.attendees, !(old == nil && details.attendees.isEmpty) {
            body["attendees"] = details.attendees.map(attendee)
        }
        if rule != held?.rule || (moved && rule != nil) {
            let pattern = rule.flatMap { GraphRecurrence.recurrence($0, start: details.start, zone: zone) }
            if let pattern {
                body["recurrence"] = pattern
            } else if held?.rule != nil {
                body["recurrence"] = NSNull()
            }
        }
        return body
    }

    /// Whether Graph's patterns hold `rule` for a series starting at `start`.
    public static func canHold(_ rule: RecurrenceRule, start: EventTime) -> Bool {
        GraphRecurrence.recurrence(rule, start: start, zone: "UTC") != nil
    }

    private static func attendee(_ attendee: Attendee) -> [String: any Sendable] {
        let type = switch attendee.role {
        case "OPT-PARTICIPANT": "optional"
        case "NON-PARTICIPANT": "resource"
        default: "required"
        }
        var address: [String: String] = ["address": attendee.email]
        if !attendee.name.isEmpty { address["name"] = attendee.name }
        return ["emailAddress": address, "type": type]
    }

    /// The zone a time is written in, as Exchange names it.
    private static func zoneName(_ time: EventTime, phoneZone: TimeZone) -> String {
        switch time {
        case let .zoned(_, id):
            WindowsZones.windowsName(forIANA: id) ?? id
        case .date, .floating:
            WindowsZones.windowsName(forIANA: phoneZone.identifier) ?? phoneZone.identifier
        case .utc:
            "UTC"
        }
    }

    private static func graphTime(_ time: EventTime, zone: String, phoneZone: TimeZone) -> [String: String] {
        let wall: DateComponents
        switch time {
        case let .date(year, month, day):
            wall = DateComponents(year: year, month: month, day: day, hour: 0, minute: 0, second: 0)
        case let .floating(parts), let .zoned(parts, _):
            wall = parts
        case let .utc(instant):
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC") ?? phoneZone
            wall = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: instant)
        }
        let text = String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d", wall.year ?? 1970, wall.month ?? 1, wall.day ?? 1,
            wall.hour ?? 0, wall.minute ?? 0, wall.second ?? 0)
        return ["dateTime": text, "timeZone": zone]
    }
}

extension EventTime {
    var isAllDay: Bool {
        if case .date = self { return true }
        return false
    }
}
