// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// How the fake calendar expands its series, and its JSON.
extension FakeGraphCalendars {
    // MARK: Expansion

    /// An occurrence id's series and day, when the series exists.
    func occurrence(_ id: String) -> (series: String, day: String)? {
        let pieces = id.split(separator: ".").map(String.init)
        guard pieces.count == 3, pieces[0] == "occ", events.contains(where: { $0.id == pieces[1] }) else { return nil }
        return (pieces[1], pieces[2])
    }

    /// Turns an occurrence into an exception event; its index.
    mutating func materialise(_ occurrence: (series: String, day: String)) -> Int? {
        guard let series = events.first(where: { $0.id == occurrence.series }),
            let start = Self.starts(of: series, from: .distantPast, to: .distantFuture).first(where: {
                Self.day($0) == occurrence.day
            })
        else { return nil }
        var json = series.json
        json.removeValue(forKey: "recurrence")
        json.removeValue(forKey: "cancelledOccurrences")
        json.removeValue(forKey: "singleValueExtendedProperties")
        let length = Self.length(of: series)
        json["type"] = "exception"
        json["seriesMasterId"] = series.id
        json["originalStart"] = Self.text(start) + "Z"
        json["start"] = ["dateTime": Self.text(start), "timeZone": "UTC"]
        json["end"] = ["dateTime": Self.text(start.addingTimeInterval(length)), "timeZone": "UTC"]
        counter += 1
        events.append(Event(id: "event-\(counter)", calendar: series.calendar, json: json, version: 1))
        return events.count - 1
    }

    /// Singles, occurrences and exceptions in `calendar` (of `series` alone, when given) that overlap.
    func instancesIn(calendar: String, series only: String?, from: Date, to: Date) -> [Event] {
        var found: [Event] = []
        for event in events where event.calendar == calendar {
            switch Self.type(of: event) {
            case "seriesMaster":
                guard only == nil || only == event.id else { continue }
                found += occurrences(of: event, from: from, to: to)
            case "exception":
                guard only == nil || only == event.json["seriesMasterId"] as? String else { continue }
                if Self.overlaps(event, from: from, to: to) { found.append(event) }
            default:
                if only == nil, Self.overlaps(event, from: from, to: to) { found.append(event) }
            }
        }
        return found
    }

    /// The occurrences of a series that overlap, less its cancelled days and its exceptions' days.
    func occurrences(of event: Event, from: Date, to: Date) -> [Event] {
        var found: [Event] = []
        let calendar = event.calendar
        let cancelled = Set((event.json["cancelledOccurrences"] as? [String]) ?? [])
        let moved = Set(events.compactMap { other -> String? in
            guard other.json["seriesMasterId"] as? String == event.id,
                let start = (other.json["originalStart"] as? String).flatMap(Self.instant)
            else { return nil }
            return Self.day(start)
        })
        let length = Self.length(of: event)
        for start in Self.starts(of: event, from: from.addingTimeInterval(-length), to: to) {
            let day = Self.day(start)
            guard !cancelled.contains("OID.\(event.id).\(day)"), !moved.contains(day) else { continue }
            var json = event.json
            json["type"] = "occurrence"
            json["seriesMasterId"] = event.id
            json["originalStart"] = Self.text(start) + "Z"
            found.append(Event(
                id: "occ.\(event.id).\(day)", calendar: calendar, json: json, version: event.version))
        }
        return found
    }

    static func starts(of series: Event, from: Date, to: Date) -> [Date] {
        guard let first = time(series.json["start"]),
            let recurrence = series.json["recurrence"] as? [String: any Sendable],
            let pattern = recurrence["pattern"] as? [String: any Sendable]
        else { return [] }
        let range = recurrence["range"] as? [String: any Sendable]
        let interval = max(1, Int((pattern["interval"] as? Double) ?? 1))
        let count = (range?["type"] as? String) == "numbered"
            ? Int((range?["numberOfOccurrences"] as? Double) ?? 0) : nil
        let until = (range?["type"] as? String) == "endDate"
            ? (range?["endDate"] as? String).flatMap { instant($0 + "T23:59:59Z") } : nil
        let names = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        let days = Set(((pattern["daysOfWeek"] as? [String]) ?? []).compactMap { names.firstIndex(of: $0) })
        let weekly = (pattern["type"] as? String) == "weekly"
        var utc = Foundation.Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? .current
        var found: [Date] = []
        var made = 0
        for offset in 0..<(366 * 4) {
            guard let day = utc.date(byAdding: .day, value: offset, to: first) else { break }
            if let until, day > until { break }
            let weeks = offset / 7
            let isOne = weekly
                ? days.contains(utc.component(.weekday, from: day) - 1) && weeks % interval == 0
                : offset % interval == 0
            guard isOne else { continue }
            made += 1
            if let count, made > count { break }
            if day > to { break }
            if day >= from { found.append(day) }
        }
        return found
    }

    static func overlaps(_ event: Event, from: Date, to: Date) -> Bool {
        guard let start = time(event.json["start"]), let end = time(event.json["end"]) else { return false }
        return start < to && end > from
    }

    static func length(of event: Event) -> TimeInterval {
        guard let start = time(event.json["start"]), let end = time(event.json["end"]) else { return 3600 }
        return end.timeIntervalSince(start)
    }

    // MARK: JSON

    static func type(of event: Event) -> String {
        (event.json["type"] as? String) ?? "singleInstance"
    }

    static func etag(_ event: Event) -> String {
        #"W/"ck\#(event.version)""#
    }

    static func marker(of event: Event) -> String? {
        let properties = event.json["singleValueExtendedProperties"] as? [[String: any Sendable]]
        return properties?.first?["value"] as? String
    }

    static func calendarObject(_ calendar: Calendar) -> [String: Any] {
        ["id": calendar.id, "name": calendar.name, "hexColor": calendar.color, "canEdit": calendar.canEdit,
         "isDefaultCalendar": calendar.isDefault]
    }

    static func stub(_ event: Event) -> [String: Any] {
        var object: [String: Any] = ["id": event.id, "type": type(of: event), "changeKey": "ck\(event.version)"]
        if let series = event.json["seriesMasterId"] as? String { object["seriesMasterId"] = series }
        if let start = event.json["originalStart"] as? String { object["originalStart"] = start }
        return object
    }

    func object(_ event: Event, expand: Bool) -> [String: Any] {
        var object: [String: Any] = event.json
        object.removeValue(forKey: "singleValueExtendedProperties")
        object["id"] = event.id
        object["changeKey"] = "ck\(event.version)"
        object["@odata.etag"] = Self.etag(event)
        if Self.type(of: event) == "seriesMaster" {
            object["cancelledOccurrences"] = (event.json["cancelledOccurrences"] as? [String]) ?? []
            if expand {
                object["exceptionOccurrences"] = events.filter { $0.json["seriesMasterId"] as? String == event.id }
                    .map { self.object($0, expand: false) }
            }
        }
        return object
    }

    static func time(_ value: (any Sendable)?) -> Date? {
        guard let object = value as? [String: any Sendable], let text = object["dateTime"] as? String else {
            return nil
        }
        return instant(text)
    }

    /// `yyyy-MM-ddTHH:mm:ss`, with fractions and a `Z` or none, read as UTC.
    static func instant(_ text: String) -> Date? {
        var trimmed = text.hasSuffix("Z") ? String(text.dropLast()) : text
        if let dot = trimmed.firstIndex(of: ".") { trimmed = String(trimmed[..<dot]) }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(identifier: "UTC")
        format.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return format.date(from: trimmed)
    }

    static func text(_ date: Date) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(identifier: "UTC")
        format.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return format.string(from: date)
    }

    static func day(_ date: Date) -> String {
        String(text(date).prefix(10))
    }
}
