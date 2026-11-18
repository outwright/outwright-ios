// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation

/// An invitee's answer, as Graph's action on the event names it.
public enum GraphAnswer: String, Sendable {
    case accept, tentativelyAccept, decline
}

/// A calendar of the signed-in user.
public struct GraphCalendar: Sendable, Equatable, Hashable {
    public var id: String
    public var name: String
    /// 0xRRGGBB from `hexColor`; nil when Graph gives none.
    public var color: Int?
    public var canEdit: Bool
    public var isDefault: Bool

    public init(id: String, name: String, color: Int?, canEdit: Bool, isDefault: Bool) {
        self.id = id
        self.name = name
        self.color = color
        self.canEdit = canEdit
        self.isDefault = isDefault
    }

    /// Its path under the Graph base URL.
    public var path: String { "me/calendars/" + GraphContacts.segment(id) }
}

/// What a listing says of an event: enough to tell whether it changed.
public struct GraphEventStub: Sendable, Equatable {
    public var id: String
    /// `singleInstance`, `occurrence`, `exception` or `seriesMaster`.
    public var type: String
    public var seriesID: String?
    public var changeKey: String

    public init(id: String, type: String, seriesID: String?, changeKey: String) {
        self.id = id
        self.type = type
        self.seriesID = seriesID
        self.changeKey = changeKey
    }
}

/// One event as Graph sent it: its id, its ETag (for `If-Match`) and its JSON.
public struct GraphEventData: Sendable, Equatable {
    public var id: String
    public var etag: String
    public var data: Data

    public init(id: String, etag: String, data: Data) {
        self.id = id
        self.etag = etag
        self.data = data
    }
}

/// The calendar calls' constants and JSON reading.
public enum GraphCalendars {
    /// The event properties the app reads.
    public static let eventProperties = [
        "id", "type", "subject", "body", "start", "end", "isAllDay", "location", "isReminderOn",
        "reminderMinutesBeforeStart", "organizer", "attendees", "isCancelled", "showAs", "sensitivity",
        "originalStartTimeZone", "originalEndTimeZone", "originalStart", "seriesMasterId", "recurrence", "changeKey",
        "isOrganizer", "iCalUId", "responseStatus", "responseRequested"
    ]
    static let textBodies = #"outlook.body-content-type="text""#
    static let maxID = 1024

    static var select: String { eventProperties.joined(separator: ",") }

    /// Whether an event's JSON asks its invitees to answer (`responseRequested`, true when absent).
    public static func wantsResponse(_ json: Data) -> Bool {
        let object = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any]
        return (object?["responseRequested"] as? Bool) ?? true
    }

    /// An event's id and ETag from its JSON, nil when it has neither.
    public static func event(_ data: Data) -> GraphEventData? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let id = string(object["id"]), let etag = string(object["@odata.etag"])
        else { return nil }
        return GraphEventData(id: id, etag: etag, data: data)
    }

    static func string(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty, text.count <= maxID else { return nil }
        return text
    }

    static func entries(_ page: Data) throws(GraphError) -> [[String: Any]] {
        guard let object = (try? JSONSerialization.jsonObject(with: page)) as? [String: Any] else {
            throw .malformed
        }
        return ((object["value"] as? [Any]) ?? []).compactMap { $0 as? [String: Any] }
    }

    static func stub(_ entry: [String: Any]) -> GraphEventStub? {
        guard let id = string(entry["id"]), let type = string(entry["type"]) else { return nil }
        return GraphEventStub(
            id: id, type: type, seriesID: string(entry["seriesMasterId"]),
            changeKey: string(entry["changeKey"]) ?? "")
    }

    /// `#RRGGBB` as 0xRRGGBB.
    static func color(_ value: Any?) -> Int? {
        guard let text = value as? String, text.count == 7, text.hasPrefix("#") else { return nil }
        return Int(text.dropFirst(), radix: 16)
    }

    /// An instant as Graph's query parameters take it.
    static func queryTime(_ date: Date) -> String {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime]
        return format.string(from: date)
    }

    /// A Graph DateTimeOffset (`2026-03-02T08:00:00Z`, with up to seven fraction digits or an offset).
    public static func instant(_ value: Any?) -> Date? {
        guard var text = value as? String, text.count <= 40 else { return nil }
        if let dot = text.firstIndex(of: ".") {
            let rest = text[text.index(after: dot)...]
            let zone = rest.drop { $0.isNumber }
            text = String(text[..<dot]) + zone
        }
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime]
        return format.date(from: text)
    }
}

extension GraphClient {
    /// The user's calendars.
    public func calendars() async throws(GraphError) -> [GraphCalendar] {
        let first = try url(
            "me/calendars", query: [("$select", "id,name,hexColor,canEdit,isDefaultCalendar"), ("$top", "500")])
        var found: [GraphCalendar] = []
        for page in try await pages(first) {
            for entry in try GraphCalendars.entries(page) {
                guard let id = GraphCalendars.string(entry["id"]) else { continue }
                found.append(GraphCalendar(
                    id: id, name: (entry["name"] as? String).map { String($0.prefix(256)) } ?? "",
                    color: GraphCalendars.color(entry["hexColor"]), canEdit: (entry["canEdit"] as? Bool) ?? false,
                    isDefault: (entry["isDefaultCalendar"] as? Bool) ?? false))
            }
        }
        return found
    }

    /// The singles, occurrences and exceptions of `calendar` that overlap `from..<to`.
    public func calendarView(
        _ calendar: GraphCalendar, from: Date, to: Date
    ) async throws(GraphError) -> [GraphEventStub] {
        let first = try url(calendar.path + "/calendarView", query: [
            ("startDateTime", GraphCalendars.queryTime(from)), ("endDateTime", GraphCalendars.queryTime(to)),
            ("$select", "id,type,seriesMasterId,changeKey"), ("$top", "500")
        ])
        return try await stubs(first)
    }

    /// An event's change key alone (a small answer); nil when Graph has no such event.
    public func changeKey(of id: String) async throws(GraphError) -> String? {
        do throws(GraphError) {
            let data = try await send(
                "GET", url("me/events/" + GraphContacts.segment(id), query: [("$select", "id,changeKey")]))
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw GraphError.malformed
            }
            return GraphCalendars.string(object["changeKey"]) ?? ""
        } catch .notFound {
            return nil
        }
    }

    private func stubs(_ first: URL) async throws(GraphError) -> [GraphEventStub] {
        var found: [GraphEventStub] = []
        for page in try await pages(first) {
            found += try GraphCalendars.entries(page).compactMap(GraphCalendars.stub)
        }
        return found
    }

    /// A single event, an occurrence or an exception; nil when Graph has none.
    public func event(id: String) async throws(GraphError) -> GraphEventData? {
        try await getEvent(id, query: [("$select", GraphCalendars.select)])
    }

    /// A series series with its cancelled occurrences and its exceptions; nil when Graph has none.
    public func series(id: String) async throws(GraphError) -> GraphEventData? {
        try await getEvent(id, query: [
            ("$select", GraphCalendars.select + ",cancelledOccurrences"),
            ("$expand", "exceptionOccurrences($select=\(GraphCalendars.select))")
        ])
    }

    private func getEvent(_ id: String, query: [(String, String)]) async throws(GraphError) -> GraphEventData? {
        do throws(GraphError) {
            let data = try await send(
                "GET", url("me/events/" + GraphContacts.segment(id), query: query), prefer: GraphCalendars.textBodies)
            guard let event = GraphCalendars.event(data) else { throw GraphError.malformed }
            return event
        } catch .notFound {
            return nil
        }
    }

    /// The occurrences and exceptions of a series that overlap `from..<to`, with their original starts.
    public func instances(
        of series: String, from: Date, to: Date
    ) async throws(GraphError) -> [(id: String, originalStart: Date)] {
        let first = try url("me/events/" + GraphContacts.segment(series) + "/instances", query: [
            ("startDateTime", GraphCalendars.queryTime(from)), ("endDateTime", GraphCalendars.queryTime(to)),
            ("$select", "id,originalStart")
        ])
        var found: [(id: String, originalStart: Date)] = []
        for page in try await pages(first) {
            for entry in try GraphCalendars.entries(page) {
                guard let id = GraphCalendars.string(entry["id"]),
                    let start = GraphCalendars.instant(entry["originalStart"])
                else { continue }
                found.append((id, start))
            }
        }
        return found
    }

    /// Creates an event in `calendar`, marked with `createID` (see `findEvent`) and sent with it as its
    /// `transactionId`.
    public func createEvent(
        _ body: [String: any Sendable], createID: String, in calendar: GraphCalendar
    ) async throws(GraphError) -> GraphEventData {
        guard GraphContacts.isSafe(createID) else { throw .malformed }
        var body = body
        body["transactionId"] = createID
        body["singleValueExtendedProperties"] = [["id": GraphContacts.createMarkerID, "value": createID]]
        let data = try await send(
            "POST", url(calendar.path + "/events"), body: Self.json(body), prefer: GraphCalendars.textBodies)
        guard let made = GraphCalendars.event(data) else { throw .malformed }
        return made
    }

    /// The event in `calendar` a create with `createID` made, nil when none did.
    public func findEvent(createID: String, in calendar: GraphCalendar) async throws(GraphError) -> GraphEventData? {
        guard GraphContacts.isSafe(createID) else { throw .malformed }
        let filter = "singleValueExtendedProperties/Any(ep: ep/id eq '\(GraphContacts.createMarkerID)' "
            + "and ep/value eq '\(createID)')"
        let data = try await send(
            "GET", url(calendar.path + "/events", query: [("$filter", filter), ("$select", GraphCalendars.select)]),
            prefer: GraphCalendars.textBodies)
        guard let entry = try GraphCalendars.entries(data).first else { return nil }
        guard let encoded = try? JSONSerialization.data(withJSONObject: entry),
            let found = GraphCalendars.event(encoded)
        else { throw .malformed }
        return found
    }

    /// Writes `body` over the event, if its ETag is still `ifMatch` (when given).
    public func updateEvent(
        id: String, _ body: [String: any Sendable], ifMatch: String?
    ) async throws(GraphError) -> GraphEventData {
        let target = try url("me/events/" + GraphContacts.segment(id))
        let data = try await send(
            "PATCH", target, body: Self.json(body), ifMatch: ifMatch, prefer: GraphCalendars.textBodies)
        if let updated = GraphCalendars.event(data) {
            return updated
        }
        guard let fresh = try await event(id: id) else { throw .notFound }
        return fresh
    }

    /// Answers an invitation (the event, or one occurrence's instance); with `sendResponse`, Graph
    /// tells the organiser, with the owner's `comment` when there is one. Graph answers 202 with no body.
    public func respond(
        id: String, _ answer: GraphAnswer, sendResponse: Bool, comment: String? = nil
    ) async throws(GraphError) {
        let target = try url("me/events/" + GraphContacts.segment(id) + "/" + answer.rawValue)
        var body: [String: any Sendable] = ["sendResponse": sendResponse]
        if let comment, !comment.isEmpty { body["comment"] = comment }
        _ = try await send("POST", target, body: Self.json(body))
    }

    /// Deletes the event (if its ETag is still `ifMatch`, when given); one already gone counts as deleted.
    public func deleteEvent(id: String, ifMatch: String?) async throws(GraphError) {
        do throws(GraphError) {
            _ = try await send("DELETE", url("me/events/" + GraphContacts.segment(id)), ifMatch: ifMatch)
        } catch .notFound {
            return
        }
    }

    private static func json(_ body: [String: any Sendable]) throws(GraphError) -> Data {
        guard JSONSerialization.isValidJSONObject(body), let data = try? JSONSerialization.data(withJSONObject: body)
        else { throw .malformed }
        return data
    }
}
