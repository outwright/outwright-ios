// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation

/// The calendar half of `FakeGraphServer`: calendars `me/calendars/<id>`, events `me/events/<id>`.
/// Times are read as UTC whatever their `timeZone` says. A series expands daily or weekly (by
/// `daysOfWeek`) only; its occurrences are `occ.<series>.<yyyy-MM-dd>` and carry the series's change
/// key. Patching an occurrence makes it an exception; deleting one cancels its day. Change keys are
/// `ck<n>`, ETags `W/"ck<n>"`.
struct FakeGraphCalendars {
    struct Calendar {
        var id: String
        var name: String
        var color: String
        var canEdit: Bool
        var isDefault: Bool
    }

    struct Event {
        var id: String
        var calendar: String
        var json: [String: any Sendable]
        var version: Int
    }

    var calendars: [Calendar] = []
    var events: [Event] = []
    var counter = 0

    // MARK: Serving

    mutating func handle(
        _ request: FakeHTTPRequest, _ parts: [String], _ query: [String: String], port: UInt16, dropPost: inout Bool
    ) -> FakeHTTPResponse? {
        switch (request.method, parts.count) {
        case ("GET", 2) where parts == ["me", "calendars"]:
            return FakeGraphServer.ok(["value": calendars.map(Self.calendarObject)])
        case ("GET", 4) where parts[1] == "calendars" && parts[3] == "calendarView":
            return view(calendar: parts[2], query)
        case ("GET", 4) where parts[1] == "calendars" && parts[3] == "events":
            return list(calendar: parts[2], query)
        case ("POST", 4) where parts[1] == "calendars" && parts[3] == "events":
            return create(request, calendar: parts[2], dropPost: &dropPost)
        case ("GET", 3) where parts[1] == "events":
            return get(parts[2], query)
        case ("GET", 4) where parts[1] == "events" && parts[3] == "instances":
            return instances(parts[2], query)
        case ("POST", 4) where parts[1] == "events" && Self.answers[parts[3]] != nil:
            return answer(request, parts[2], Self.answers[parts[3]] ?? "")
        case ("PATCH", 3) where parts[1] == "events":
            return update(request, id: parts[2])
        case ("DELETE", 3) where parts[1] == "events":
            return delete(request, id: parts[2])
        default:
            return nil
        }
    }

    func view(calendar: String, _ query: [String: String]) -> FakeHTTPResponse {
        guard calendars.contains(where: { $0.id == calendar }),
            let from = query["startDateTime"].flatMap(Self.instant), let to = query["endDateTime"].flatMap(Self.instant)
        else { return FakeHTTPResponse(status: 400) }
        let found = instancesIn(calendar: calendar, series: nil, from: from, to: to)
        return FakeGraphServer.ok(["value": found.map { Self.stub($0) }])
    }

    func list(calendar: String, _ query: [String: String]) -> FakeHTTPResponse {
        guard calendars.contains(where: { $0.id == calendar }) else { return FakeHTTPResponse(status: 404) }
        var held = events.filter { $0.calendar == calendar && Self.type(of: $0) != "exception" }
        if let filter = query["$filter"] {
            // Only the create-marker lookup is understood: `... ep/value eq '<value>')`.
            let value = filter.components(separatedBy: "ep/value eq '").last?.components(separatedBy: "'").first ?? ""
            held = held.filter { Self.marker(of: $0) == value }
        }
        return FakeGraphServer.ok(["value": held.map { object($0, expand: false) }])
    }

    func get(_ id: String, _ query: [String: String]) -> FakeHTTPResponse {
        if let occurrence = occurrence(id), let series = events.first(where: { $0.id == occurrence.series }) {
            // An occurrence never changed has no version of its own: no ETag.
            return FakeGraphServer.ok([
                "id": id, "type": "occurrence", "seriesMasterId": series.id,
                "subject": (series.json["subject"] as? String) ?? ""
            ])
        }
        guard let event = events.first(where: { $0.id == id }) else { return FakeHTTPResponse(status: 404) }
        let expand = (query["$expand"] ?? "").contains("exceptionOccurrences")
        return FakeGraphServer.ok(object(event, expand: expand))
    }

    func instances(_ series: String, _ query: [String: String]) -> FakeHTTPResponse {
        guard let event = events.first(where: { $0.id == series }),
            let from = query["startDateTime"].flatMap(Self.instant), let to = query["endDateTime"].flatMap(Self.instant)
        else { return FakeHTTPResponse(status: 404) }
        let found = instancesIn(calendar: event.calendar, series: series, from: from, to: to)
        return FakeGraphServer.ok(["value": found.map { Self.stub($0) }])
    }

    mutating func create(
        _ request: FakeHTTPRequest, calendar: String, dropPost: inout Bool
    ) -> FakeHTTPResponse {
        guard let home = calendars.first(where: { $0.id == calendar }) else { return FakeHTTPResponse(status: 404) }
        guard home.canEdit else { return FakeHTTPResponse(status: 403) }
        guard let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] else {
            return FakeHTTPResponse(status: 400)
        }
        let id = put(FakeGraphServer.sendable(body), in: calendar)
        if dropPost {
            dropPost = false
            return .dropped
        }
        guard let made = events.first(where: { $0.id == id }) else { return FakeHTTPResponse(status: 500) }
        return FakeGraphServer.ok(object(made, expand: false), status: 201)
    }

    mutating func update(_ request: FakeHTTPRequest, id: String) -> FakeHTTPResponse {
        guard let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] else {
            return FakeHTTPResponse(status: 400)
        }
        var index = events.firstIndex { $0.id == id }
        if index == nil, let occurrence = occurrence(id) {
            index = materialise(occurrence)
        }
        guard let index else { return FakeHTTPResponse(status: 404) }
        if let match = request.headers["if-match"], match != Self.etag(events[index]) {
            return FakeHTTPResponse(status: 412)
        }
        let changes = FakeGraphServer.sendable(body)
        for (key, value) in changes {
            events[index].json[key] = value
        }
        events[index].version += 1
        if Self.type(of: events[index]) == "seriesMaster",
            changes.keys.contains(where: { ["start", "end", "recurrence"].contains($0) }) {
            // Graph drops the exceptions and cancellations when the series' times or pattern change.
            let series = events[index].id
            events.removeAll { $0.json["seriesMasterId"] as? String == series }
            if let held = events.firstIndex(where: { $0.id == series }) {
                events[held].json["cancelledOccurrences"] = [String]()
            }
        }
        guard let updated = events.first(where: { $0.id == (events[index].id) }) else {
            return FakeHTTPResponse(status: 500)
        }
        return FakeGraphServer.ok(object(updated, expand: false))
    }

    /// Graph's answer actions and the `responseStatus` each leaves.
    static let answers = ["accept": "accepted", "tentativelyAccept": "tentativelyAccepted", "decline": "declined"]

    /// An invitee's answer: held as the event's `responseStatus`, with a new change key. A declined
    /// event leaves the calendar (Graph moves it to Deleted Items); a declined occurrence's day is
    /// cancelled. A response sent to a meeting whose organiser asked for none is refused with 400.
    mutating func answer(_ request: FakeHTTPRequest, _ id: String, _ response: String) -> FakeHTTPResponse {
        let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]
        let held = events.first { $0.id == id || $0.id == occurrence(id)?.series }
        if body?["sendResponse"] as? Bool == true, held?.json["responseRequested"] as? Bool == false {
            return FakeHTTPResponse(status: 400)
        }
        if response == "declined" {
            if let occurrence = occurrence(id) {
                cancel(series: occurrence.series, day: occurrence.day)
                return FakeHTTPResponse(status: 202)
            }
            guard events.contains(where: { $0.id == id }) else { return FakeHTTPResponse(status: 404) }
            events.removeAll { $0.id == id || $0.json["seriesMasterId"] as? String == id }
            return FakeHTTPResponse(status: 202)
        }
        var index = events.firstIndex { $0.id == id }
        if index == nil, let occurrence = occurrence(id) {
            index = materialise(occurrence)
        }
        guard let index else { return FakeHTTPResponse(status: 404) }
        events[index].json["responseStatus"] = ["response": response]
        events[index].version += 1
        return FakeHTTPResponse(status: 202)
    }

    mutating func delete(_ request: FakeHTTPRequest, id: String) -> FakeHTTPResponse {
        if let occurrence = occurrence(id) {
            cancel(series: occurrence.series, day: occurrence.day)
            return FakeHTTPResponse(status: 204)
        }
        guard let index = events.firstIndex(where: { $0.id == id }) else { return FakeHTTPResponse(status: 404) }
        if let match = request.headers["if-match"], match != Self.etag(events[index]) {
            return FakeHTTPResponse(status: 412)
        }
        let event = events.remove(at: index)
        if let series = event.json["seriesMasterId"] as? String,
            let start = (event.json["originalStart"] as? String).flatMap(Self.instant) {
            cancel(series: series, day: Self.day(start))
        }
        events.removeAll { $0.json["seriesMasterId"] as? String == id }
        return FakeHTTPResponse(status: 204)
    }

    // MARK: Controls

    mutating func put(_ json: [String: any Sendable], in calendar: String) -> String {
        counter += 1
        let id = "event-\(counter)"
        var json = json
        if json["type"] == nil {
            json["type"] = json["recurrence"] == nil ? "singleInstance" : "seriesMaster"
        }
        events.append(Event(id: id, calendar: calendar, json: json, version: 1))
        return id
    }

    mutating func cancel(series: String, day: String) {
        guard let index = events.firstIndex(where: { $0.id == series }) else { return }
        var cancelled = (events[index].json["cancelledOccurrences"] as? [String]) ?? []
        cancelled.append("OID.\(series).\(day)")
        // The series event's change key stays: a cancelled occurrence shows only in the listings.
        events[index].json["cancelledOccurrences"] = cancelled
    }

    /// Makes the occurrence an exception holding `json` over the series's properties.
    mutating func addException(of series: String, at start: Date, _ json: [String: any Sendable]) -> String? {
        guard let made = materialise((series, Self.day(start))) else { return nil }
        for (key, value) in json {
            events[made].json[key] = value
        }
        return events[made].id
    }

}

extension FakeGraphServer {
    /// A calendar; its path for the client is `me/calendars/<id>`. `color` is `#RRGGBB` or empty.
    @discardableResult
    public func addCalendar(
        _ name: String, color: String = "", canEdit: Bool = true, isDefault: Bool = false
    ) -> String {
        calendarState.counter += 1
        let id = "calendar-\(calendarState.counter)"
        calendarState.calendars.append(.init(id: id, name: name, color: color, canEdit: canEdit, isDefault: isDefault))
        return id
    }

    /// Stores an event (Graph JSON without `id`); one with `recurrence` is a series series.
    @discardableResult
    public func putEvent(_ json: Data, in calendar: String) -> String {
        let object = ((try? JSONSerialization.jsonObject(with: json)) as? [String: Any]) ?? [:]
        return calendarState.put(Self.sendable(object), in: calendar)
    }

    /// The event's JSON as Graph holds it, nil when there is none.
    public func eventJSON(_ id: String) -> Data? {
        guard let event = calendarState.events.first(where: { $0.id == id }) else { return nil }
        var object: [String: Any] = event.json
        object["id"] = event.id
        return try? JSONSerialization.data(withJSONObject: object)
    }

    /// Every event Graph holds (masters, singles and exceptions), as JSON.
    public func allEventsJSON() -> [Data] {
        calendarState.events.compactMap { eventJSON($0.id) }
    }

    /// Cancels a series' occurrence on `day` (`yyyy-MM-dd`), as another client would.
    public func cancelOccurrence(of series: String, on day: String) {
        calendarState.cancel(series: series, day: day)
    }

    /// Makes the series' occurrence starting at `start` an exception with `json` over it; its id.
    @discardableResult
    public func addException(of series: String, at start: Date, _ json: Data) -> String? {
        let object = ((try? JSONSerialization.jsonObject(with: json)) as? [String: Any]) ?? [:]
        return calendarState.addException(of: series, at: start, Self.sendable(object))
    }

    /// Changes an event's property as another client would (its change key moves).
    public func editEvent(_ id: String, _ key: String, _ value: String) {
        guard let index = calendarState.events.firstIndex(where: { $0.id == id }) else { return }
        calendarState.events[index].json[key] = value
        calendarState.events[index].version += 1
    }

    public func removeEvent(_ id: String) {
        calendarState.events.removeAll { $0.id == id }
    }
}
