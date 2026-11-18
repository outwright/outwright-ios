// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
import OutwrightGraph
public import OutwrightModel

/// Between Graph's event JSON and the series the calendar keeps. Times come as the instant Graph names
/// and are held as wall time in the event's own zone (`originalStartTimeZone`), so a series keeps its
/// local hour across daylight saving; an unknown zone keeps them in UTC. Nothing is trusted to have its
/// type: a wrong one reads as absent.
public enum GraphEventMapping {
    static let maxText = 64 * 1024
    static let maxAttendees = 500
    static let maxDates = 5_000

    // MARK: Reading

    /// The series an event's JSON (a single event, or a series master with its exceptions and
    /// cancelled occurrences) says; nil when it is not one, or its times or pattern can't be read.
    /// On an invitation, `ownEmail`'s answer is the copy's `responseStatus` (Graph leaves the
    /// invitee's own status in the attendee list unset).
    public static func series(_ json: Data, ownEmail: String? = nil) -> EventSeries? {
        guard let object = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
            let id = text(object["id"], cap: 1024), !id.isEmpty,
            let base = details(object, ownEmail: ownEmail)
        else { return nil }
        let uid = text(object["iCalUId"], cap: 4096).flatMap { $0.isEmpty ? nil : GraphGlobalObjectID.uid($0) } ?? id
        var series = EventSeries(uid: uid, base: base)
        guard let recurrence = object["recurrence"] as? [String: Any] else {
            return series
        }
        guard let rule = GraphRecurrence.rule(recurrence) else { return nil }
        series.rule = rule
        let zone = zoneID(object["originalStartTimeZone"])
        for entry in ((object["exceptionOccurrences"] as? [Any]) ?? []).prefix(maxDates) {
            guard let entry = entry as? [String: Any], let details = details(entry, zoneOf: object, ownEmail: ownEmail),
                let original = GraphCalendars.instant(entry["originalStart"])
            else { continue }
            let recurrenceID = same(as: base.start, at: original, zone: zone)
            series.overrides.append(EventOverride(recurrenceID: recurrenceID, details: details))
        }
        for entry in ((object["cancelledOccurrences"] as? [Any]) ?? []).prefix(maxDates) {
            guard let entry = entry as? String, entry.utf8.count <= 2048,
                let day = GraphRecurrence.date(String(entry.suffix(10))), let exdate = on(day, like: base.start)
            else { continue }
            series.exdates.append(exdate)
        }
        return series
    }

    /// What one event (a single one, a master or an exception) says; nil without readable times. An
    /// exception that names no zone of its own is in its series' (`zoneOf`).
    static func details(
        _ object: [String: Any], zoneOf series: [String: Any]? = nil, ownEmail: String? = nil
    ) -> EventDetails? {
        let allDay = (object["isAllDay"] as? Bool) ?? false
        let startZone = zoneID(object["originalStartTimeZone"]) ?? zoneID(series?["originalStartTimeZone"])
        let endZone = zoneID(object["originalEndTimeZone"]) ?? zoneID(series?["originalEndTimeZone"]) ?? startZone
        guard let start = time(object["start"], allDay: allDay, zone: startZone),
            let end = time(object["end"], allDay: allDay, zone: endZone)
        else { return nil }
        let body = object["body"] as? [String: Any]
        let location = object["location"] as? [String: Any]
        var details = EventDetails(
            title: text(object["subject"]) ?? "", place: text(location?["displayName"]) ?? "",
            notes: text(body?["content"]) ?? "", start: start, end: end)
        if (object["isReminderOn"] as? Bool) == true {
            details.reminder = GraphRecurrence.int(object["reminderMinutesBeforeStart"]).map { min(max($0, 0), 40_320) }
        }
        let isOrganizer = (object["isOrganizer"] as? Bool) == true
        let organizer = (object["organizer"] as? [String: Any])?["emailAddress"] as? [String: Any]
        details.organizer = isOrganizer ? nil : text(organizer?["address"], cap: 512).flatMap { $0.isEmpty ? nil : $0 }
        details.attendees = ((object["attendees"] as? [Any]) ?? []).prefix(maxAttendees).compactMap(attendee)
        if !isOrganizer, let ownEmail, !ownEmail.isEmpty, let own = ownResponse(object["responseStatus"]) {
            answer(&details, own, ownEmail: ownEmail)
        }
        let showAs = object["showAs"] as? String
        if (object["isCancelled"] as? Bool) == true {
            details.status = .cancelled
        } else if showAs == "tentative" {
            details.status = .tentative
        }
        details.showAs = switch showAs {
        case "free": .free
        case "tentative": .tentative
        case "oof": .away
        // workingElsewhere, unknown and absent: the time is taken.
        default: .busy
        }
        let sensitivity = object["sensitivity"] as? String
        details.isPrivate = sensitivity == "private" || sensitivity == "confidential"
        return details
    }

    /// The invitee's own answer in a `responseStatus`; nil when there is none to read.
    private static func ownResponse(_ value: Any?) -> Attendee.Response? {
        switch (value as? [String: Any])?["response"] as? String {
        case "accepted": .accepted
        case "tentativelyAccepted": .tentative
        case "declined": .declined
        case "none", "notResponded": .needsAction
        default: nil
        }
    }

    /// Sets the account's answer on its attendee entry. An entry the list lacks is added only for an
    /// answer given: someone else's event in a shared calendar says "none" too, and is no invitation.
    private static func answer(_ details: inout EventDetails, _ response: Attendee.Response, ownEmail: String) {
        let own = ownEmail.lowercased()
        let listed = details.attendees.indices.filter { details.attendees[$0].email.lowercased() == own }
        guard !listed.isEmpty else {
            guard response != .needsAction else { return }
            details.attendees.append(Attendee(email: ownEmail, name: "", response: response, role: "REQ-PARTICIPANT"))
            return
        }
        for index in listed { details.attendees[index].response = response }
    }

    private static func attendee(_ value: Any) -> Attendee? {
        guard let object = value as? [String: Any], let email = object["emailAddress"] as? [String: Any],
            let address = text(email["address"], cap: 512), !address.isEmpty
        else { return nil }
        let response: Attendee.Response = switch (object["status"] as? [String: Any])?["response"] as? String {
        case "accepted", "organizer": .accepted
        case "tentativelyAccepted": .tentative
        case "declined": .declined
        default: .needsAction
        }
        let role = switch object["type"] as? String {
        case "optional": "OPT-PARTICIPANT"
        case "resource": "NON-PARTICIPANT"
        default: "REQ-PARTICIPANT"
        }
        return Attendee(email: address, name: text(email["name"], cap: 512) ?? "", response: response, role: role)
    }

    /// A Graph DateTimeTimeZone as the event holds it: an all-day date, wall time in `zone`, or UTC.
    static func time(_ value: Any?, allDay: Bool, zone: String?) -> EventTime? {
        guard let object = value as? [String: Any], let wall = wallTime(object["dateTime"]) else { return nil }
        let source = zoneID(object["timeZone"]).flatMap(TimeZone.init(identifier:))
            ?? TimeZone(identifier: "UTC") ?? .current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = source
        guard let instant = calendar.date(from: wall) else { return nil }
        let own = zone.flatMap(TimeZone.init(identifier:))
        if allDay {
            guard let own else {
                // Midnight in a zone not known here: the nearest midnight UTC is that day's (offsets
                // within twelve hours of UTC).
                let day = (instant.timeIntervalSince1970 / 86_400).rounded() * 86_400
                calendar.timeZone = TimeZone(identifier: "UTC") ?? source
                let parts = calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: day))
                guard let year = parts.year, let month = parts.month, let date = parts.day else { return nil }
                return .date(year: year, month: month, day: date)
            }
            calendar.timeZone = own
            let day = calendar.dateComponents([.year, .month, .day], from: instant)
            guard let year = day.year, let month = day.month, let date = day.day else { return nil }
            return .date(year: year, month: month, day: date)
        }
        guard let own, let zone else { return .utc(instant) }
        calendar.timeZone = own
        let local = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: instant)
        return .zoned(local, zone: zone)
    }

    /// `yyyy-MM-ddTHH:mm:ss` with up to seven fraction digits, as wall-time components.
    static func wallTime(_ value: Any?) -> DateComponents? {
        guard let text = value as? String, text.utf8.count <= 40 else { return nil }
        let bare = text.split(separator: ".", maxSplits: 1).first.map(String.init) ?? text
        let halves = bare.split(separator: "T")
        guard halves.count == 2 else { return nil }
        let date = halves[0].split(separator: "-").compactMap { Int($0) }
        let clock = halves[1].split(separator: ":").compactMap { Int($0) }
        guard date.count == 3, clock.count == 3, (1...9999).contains(date[0]), (1...12).contains(date[1]),
            (1...31).contains(date[2]), (0...23).contains(clock[0]), (0...59).contains(clock[1]),
            (0...60).contains(clock[2])
        else { return nil }
        return DateComponents(
            year: date[0], month: date[1], day: date[2], hour: clock[0], minute: clock[1], second: clock[2])
    }

    /// The IANA id a Graph zone name (Windows or IANA) resolves to; nil when unknown.
    static func zoneID(_ value: Any?) -> String? {
        guard let name = value as? String, !name.isEmpty, name.utf8.count <= 128,
            case let .iana(id) = ZoneResolver.resolve(tzid: name, given: [:])
        else { return nil }
        return id
    }

    /// An instant as the same kind of time as `start` (for a RECURRENCE-ID).
    private static func same(as start: EventTime, at instant: Date, zone: String?) -> EventTime {
        var calendar = Calendar(identifier: .gregorian)
        switch start {
        case .date:
            calendar.timeZone = zone.flatMap(TimeZone.init(identifier:)) ?? TimeZone(identifier: "UTC") ?? .current
            let day = calendar.dateComponents([.year, .month, .day], from: instant)
            return .date(year: day.year ?? 1970, month: day.month ?? 1, day: day.day ?? 1)
        case let .zoned(_, id):
            calendar.timeZone = TimeZone(identifier: id) ?? .current
            let wall = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: instant)
            return .zoned(wall, zone: id)
        case .floating, .utc:
            return .utc(instant)
        }
    }

    /// The series' start moved to another day, its time of day kept.
    private static func on(_ day: EventTime, like start: EventTime) -> EventTime? {
        guard case let .date(year, month, date) = day else { return nil }
        switch start {
        case .date:
            return day
        case let .zoned(wall, zone):
            return .zoned(DateComponents(
                year: year, month: month, day: date, hour: wall.hour, minute: wall.minute, second: wall.second),
                zone: zone)
        case let .floating(wall):
            return .floating(DateComponents(
                year: year, month: month, day: date, hour: wall.hour, minute: wall.minute, second: wall.second))
        case let .utc(instant):
            // The series' zone isn't known here, so the date names the occurrence in a clock up to
            // twelve hours off UTC: it is the one at the series' time of day nearest that date's midnight.
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
            var parts = calendar.dateComponents([.hour, .minute, .second], from: instant)
            (parts.year, parts.month, parts.day) = (year, month, date)
            guard let sameDay = calendar.date(from: parts),
                let midnight = calendar.date(from: DateComponents(year: year, month: month, day: date))
            else { return nil }
            let candidates = [-86_400.0, 0, 86_400].map { sameDay.addingTimeInterval($0) }
            let nearest = candidates.min {
                abs($0.timeIntervalSince(midnight)) < abs($1.timeIntervalSince(midnight))
            } ?? sameDay
            return .utc(nearest)
        }
    }

    static func text(_ value: Any?, cap: Int = maxText) -> String? {
        guard let string = value as? String else { return nil }
        return string.count > cap ? String(string.prefix(cap)) : string
    }
}
