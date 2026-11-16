// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightFakes
import Testing

@testable import OutwrightGraph

/// A weekly series on Mondays at 08:00 UTC from 2026-03-02, ten times.
var weeklySeries: [String: Any] {
    [
        "subject": "Standup", "start": ["dateTime": "2026-03-02T08:00:00.0000000", "timeZone": "UTC"],
        "end": ["dateTime": "2026-03-02T08:15:00.0000000", "timeZone": "UTC"],
        "originalStartTimeZone": "W. Europe Standard Time",
        "recurrence": [
            "pattern": ["type": "weekly", "interval": 1, "daysOfWeek": ["monday"], "firstDayOfWeek": "monday"],
            "range": ["type": "numbered", "startDate": "2026-03-02", "numberOfOccurrences": 10],
        ],
    ]
}

var singleEvent: [String: Any] {
    [
        "subject": "Lunch", "body": ["contentType": "text", "content": "At noon"],
        "start": ["dateTime": "2026-03-04T11:00:00.0000000", "timeZone": "UTC"],
        "end": ["dateTime": "2026-03-04T12:00:00.0000000", "timeZone": "UTC"],
    ]
}

private func utc(_ text: String) throws -> Date {
    try #require(ISO8601DateFormatter().date(from: text))
}

private func calendar(_ id: String) -> GraphCalendar {
    GraphCalendar(id: id, name: "", color: nil, canEdit: true, isDefault: false)
}

/// The query items of the last request whose path contains `piece`.
private func query(of server: FakeGraphServer, _ piece: String) async throws -> [String: String] {
    let request = try #require(await server.requests.last { $0.path.contains(piece) })
    let parts = try #require(URLComponents(string: "http://x" + request.path))
    return Dictionary((parts.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
}

@Suite struct GraphCalendarsTests {
    private let createID = "0d9c7a52-5a8b-4a8e-9bb3-6b0d2f7c1e44"

    @Test func listsCalendarsWithColourAndRights() async throws {
        try await withGraph { server, client, _ in
            let main = await server.addCalendar("Calendar", color: "#2f6fdb", isDefault: true)
            let shared = await server.addCalendar("Holidays", canEdit: false)
            let calendars = try await client.calendars()
            #expect(calendars == [
                GraphCalendar(id: main, name: "Calendar", color: 0x2F6FDB, canEdit: true, isDefault: true),
                GraphCalendar(id: shared, name: "Holidays", color: nil, canEdit: false, isDefault: false),
            ])
            #expect(calendars.first?.path == "me/calendars/\(main)")
        }
    }

    @Test func calendarViewSendsTheWindow() async throws {
        try await withGraph { server, client, _ in
            let home = await server.addCalendar("Calendar")
            let single = await server.putEvent(json(singleEvent), in: home)
            let series = await server.putEvent(json(weeklySeries), in: home)
            let stubs = try await client.calendarView(
                calendar(home), from: try utc("2026-03-01T00:00:00Z"), to: try utc("2026-03-15T00:00:00Z"))
            #expect(stubs.filter { $0.type == "singleInstance" }.map(\.id) == [single])
            #expect(stubs.filter { $0.seriesID == series }.count == 2)
            let asked = try await query(of: server, "calendarView")
            #expect(asked["startDateTime"] == "2026-03-01T00:00:00Z" && asked["endDateTime"] == "2026-03-15T00:00:00Z")
            #expect(Set((asked["$select"] ?? "").split(separator: ",")) == ["id", "type", "seriesMasterId", "changeKey"])
        }
    }

    @Test func aChangeKeyAloneIsAskedFor() async throws {
        try await withGraph { server, client, _ in
            let home = await server.addCalendar("Calendar")
            let series = await server.putEvent(json(weeklySeries), in: home)
            #expect(try await client.changeKey(of: series) == "ck1")
            let asked = try await query(of: server, "events/\(series)")
            #expect(asked["$select"] == "id,changeKey")
            let gone = try await client.changeKey(of: "nope")
            #expect(gone == nil)
        }
    }

    @Test func seriesExpandsExceptionsAndAsksForCancelled() async throws {
        try await withGraph { server, client, _ in
            let home = await server.addCalendar("Calendar")
            let series = await server.putEvent(json(weeklySeries), in: home)
            await server.cancelOccurrence(of: series, on: "2026-03-09")
            await server.addException(of: series, at: try utc("2026-03-16T08:00:00Z"), json(["subject": "Moved"]))
            let held = try #require(try await client.series(id: series))
            #expect(held.id == series && held.etag == #"W/"ck1""#)
            let object = try #require(try JSONSerialization.jsonObject(with: held.data) as? [String: Any])
            #expect((object["cancelledOccurrences"] as? [String]) == ["OID.\(series).2026-03-09"])
            #expect(((object["exceptionOccurrences"] as? [[String: Any]]) ?? []).map { $0["subject"] as? String } == ["Moved"])
            let asked = try await query(of: server, "events/\(series)")
            #expect((asked["$select"] ?? "").split(separator: ",").contains("cancelledOccurrences"))
            #expect((asked["$expand"] ?? "").hasPrefix("exceptionOccurrences"))
        }
    }

    @Test func bodiesAreAskedAsText() async throws {
        try await withGraph { server, client, _ in
            let home = await server.addCalendar("Calendar")
            let single = await server.putEvent(json(singleEvent), in: home)
            _ = try await client.event(id: single)
            let request = try #require(await server.requests.last)
            #expect(request.headers["prefer"] == #"outlook.body-content-type="text""#)
        }
    }

    @Test func aMissingEventIsNil() async throws {
        try await withGraph { _, client, _ in
            let event = try await client.event(id: "nope")
            let series = try await client.series(id: "nope")
            #expect(event == nil && series == nil)
        }
    }

    @Test func createCarriesMarkerAndTransactionID() async throws {
        try await withGraph { server, client, _ in
            let home = await server.addCalendar("Calendar")
            let made = try await client.createEvent(["subject": "New"], createID: createID, in: calendar(home))
            let sent = try #require(await server.requests.last { $0.method == "POST" })
            let body = try #require(try JSONSerialization.jsonObject(with: sent.body) as? [String: Any])
            #expect(body["transactionId"] as? String == createID)
            let marker = (body["singleValueExtendedProperties"] as? [[String: Any]])?.first
            #expect(marker?["id"] as? String == GraphContacts.createMarkerID && marker?["value"] as? String == createID)
            #expect(sent.path.hasPrefix("/v1.0/me/calendars/\(home)/events"))
            #expect(!made.id.isEmpty && !made.etag.isEmpty)
        }
    }

    @Test func findEventFiltersOnTheMarker() async throws {
        try await withGraph { server, client, _ in
            let home = await server.addCalendar("Calendar")
            await server.putEvent(json(singleEvent), in: home)
            let made = try await client.createEvent(["subject": "New"], createID: createID, in: calendar(home))
            #expect(try await client.findEvent(createID: createID, in: calendar(home))?.id == made.id)
            let other = "11111111-2222-3333-4444-555555555555"
            #expect(try await client.findEvent(createID: other, in: calendar(home)) == nil)
        }
    }

    @Test func aCreateIDThatIsNotAUUIDIsRefused() async throws {
        try await withGraph { server, client, _ in
            let home = await server.addCalendar("Calendar")
            await #expect(throws: GraphError.malformed) {
                _ = try await client.findEvent(createID: "x' or 1 eq 1", in: calendar(home))
            }
        }
    }

    @Test func updateSendsIfMatch() async throws {
        try await withGraph { server, client, _ in
            let home = await server.addCalendar("Calendar")
            let single = await server.putEvent(json(singleEvent), in: home)
            let updated = try await client.updateEvent(id: single, ["subject": "Dinner"], ifMatch: #"W/"ck1""#)
            #expect(updated.etag == #"W/"ck2""#)
            await #expect(throws: GraphError.preconditionFailed) {
                _ = try await client.updateEvent(id: single, ["subject": "Late"], ifMatch: #"W/"ck1""#)
            }
        }
    }

    @Test func deleteOf404IsDone() async throws {
        try await withGraph { server, client, _ in
            let home = await server.addCalendar("Calendar")
            let single = await server.putEvent(json(singleEvent), in: home)
            try await client.deleteEvent(id: single, ifMatch: #"W/"ck1""#)
            try await client.deleteEvent(id: single, ifMatch: #"W/"ck1""#)
            #expect(await server.allEventsJSON().isEmpty)
        }
    }

    @Test func instancesOfADay() async throws {
        try await withGraph { server, client, _ in
            let home = await server.addCalendar("Calendar")
            let series = await server.putEvent(json(weeklySeries), in: home)
            let found = try await client.instances(
                of: series, from: try utc("2026-03-09T00:00:00Z"), to: try utc("2026-03-10T00:00:00Z"))
            let ninth = try utc("2026-03-09T08:00:00Z")
            #expect(found.map(\.originalStart) == [ninth])
            #expect(found.first?.id == "occ.\(series).2026-03-09")
        }
    }
}
