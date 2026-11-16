// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightFakes
import OutwrightGraph
import OutwrightModel
import OutwrightStore
import Testing

@testable import OutwrightSync

/// 2026-03-01 12:00 UTC: the window runs from 2025-03-01 to 2028-03-01.
let graphNow = Date(timeIntervalSince1970: 1_772_366_400)

extension GraphHarness {
    func calendarSyncer() -> GraphCalendarSyncer {
        GraphCalendarSyncer(
            account: account, store: store, credentials: microsoft.credentials, lock: AccountLock(), base: base,
            session: URLSession(configuration: .ephemeral), now: { graphNow }, phoneZone: { stockholm })
    }

    /// Every held occurrence in the window: title and start.
    func held() throws -> [(title: String, start: Date)] {
        try store.occurrences(
            from: graphNow.addingTimeInterval(-400 * 86_400), to: graphNow.addingTimeInterval(800 * 86_400), in: nil
        ).map { ($0.occurrence.details.title, $0.occurrence.start) }
    }

    /// How many times Graph was asked for one whole event by id (not its change key alone).
    func eventGets(_ id: String) async -> Int {
        await graph.requests.filter {
            $0.method == "GET" && $0.path.hasPrefix("/v1.0/me/events/\(id)?") && !$0.path.contains("id%2CchangeKey")
                && !$0.path.contains("id,changeKey")
        }.count
    }
}

func graphEvent(_ subject: String, _ start: String, _ end: String, _ more: [String: Any] = [:]) -> Data {
    var object: [String: Any] = [
        "subject": subject, "start": ["dateTime": start, "timeZone": "UTC"], "end": ["dateTime": end, "timeZone": "UTC"],
        "originalStartTimeZone": "W. Europe Standard Time",
    ]
    for (key, value) in more { object[key] = value }
    return graphJSON(object)
}

/// Mondays at 08:00 UTC from 2026-03-02, four times.
var graphWeekly: [String: Any] {
    [
    "recurrence": [
        "pattern": ["type": "weekly", "interval": 1, "daysOfWeek": ["monday"], "firstDayOfWeek": "monday"],
        "range": ["type": "numbered", "startDate": "2026-03-02", "numberOfOccurrences": 4],
    ] as [String: Any],
    ]
}

private func utc(_ text: String) throws -> Date {
    try #require(ISO8601DateFormatter().date(from: text))
}

@Suite(.serialized) struct GraphCalendarSyncTests {
    @Test func calendarsArriveWithColourDefaultFirstAndReadOnly() async throws {
        try await withGraphContacts { h in
            await h.graph.addCalendar("Holidays", canEdit: false)
            let main = await h.graph.addCalendar("Calendar", color: "#2f6fdb", isDefault: true)
            try await h.calendarSyncer().sync()
            let calendars = try h.store.calendars(h.account.id)
            #expect(calendars.map(\.name) == ["Calendar", "Holidays"])
            #expect(calendars.first?.href == "me/calendars/\(main)" && calendars.first?.color == 0x2F6FDB)
            #expect(calendars.map(\.isReadOnly) == [false, true])
        }
    }

    @Test func singleAndSeriesInTheWindowAreStored() async throws {
        try await withGraphContacts { h in
            let home = await h.graph.addCalendar("Calendar")
            await h.graph.putEvent(graphEvent("Lunch", "2026-03-04T11:00:00", "2026-03-04T12:00:00"), in: home)
            await h.graph.putEvent(graphEvent("Long ago", "2020-03-04T11:00:00", "2020-03-04T12:00:00"), in: home)
            await h.graph.putEvent(
                graphEvent("Standup", "2026-03-02T08:00:00", "2026-03-02T08:15:00", graphWeekly), in: home)
            try await h.calendarSyncer().sync()
            let held = try h.held()
            #expect(held.filter { $0.title == "Standup" }.count == 4)
            let noon = try utc("2026-03-04T11:00:00Z")
            #expect(held.filter { $0.title == "Lunch" }.map(\.start) == [noon])
            #expect(!held.contains { $0.title == "Long ago" })
        }
    }

    @Test func unchangedVersionsAreNotFetchedAgain() async throws {
        try await withGraphContacts { h in
            let home = await h.graph.addCalendar("Calendar")
            let lunch = await h.graph.putEvent(graphEvent("Lunch", "2026-03-04T11:00:00", "2026-03-04T12:00:00"), in: home)
            let series = await h.graph.putEvent(
                graphEvent("Standup", "2026-03-02T08:00:00", "2026-03-02T08:15:00", graphWeekly), in: home)
            let syncer = h.calendarSyncer()
            try await syncer.sync()
            try await syncer.sync()
            let first = (await h.eventGets(lunch), await h.eventGets(series))
            #expect(first == (1, 1))
            await h.graph.editEvent(lunch, "subject", "Dinner")
            try await syncer.sync()
            let second = (await h.eventGets(lunch), await h.eventGets(series))
            #expect(second == (2, 1))
            #expect(try h.held().contains { $0.title == "Dinner" })
        }
    }

    /// The series' change keys are asked for side by side, never more than Graph's four at once.
    @Test func seriesKeysAreAskedForSideBySide() async throws {
        try await withGraphContacts { h in
            let home = await h.graph.addCalendar("Calendar")
            for index in 0..<8 {
                await h.graph.putEvent(
                    graphEvent("Series \(index)", "2026-03-02T08:00:00", "2026-03-02T08:15:00", graphWeekly), in: home)
            }
            await h.graph.delayAnswers(.milliseconds(50))
            try await h.calendarSyncer().sync()
            let most = await h.graph.mostAtOnce
            #expect((2...4).contains(most))
            #expect(try h.held().count == 8 * 4)
        }
    }

    @Test func aCancelledOccurrenceRefetchesTheSeries() async throws {
        try await withGraphContacts { h in
            let home = await h.graph.addCalendar("Calendar")
            let series = await h.graph.putEvent(
                graphEvent("Standup", "2026-03-02T08:00:00", "2026-03-02T08:15:00", graphWeekly), in: home)
            let syncer = h.calendarSyncer()
            try await syncer.sync()
            await h.graph.cancelOccurrence(of: series, on: "2026-03-09")
            try await syncer.sync()
            let starts = try h.held().map(\.start)
            let ninth = try utc("2026-03-09T08:00:00Z")
            #expect(starts.count == 3 && !starts.contains(ninth))
        }
    }

    /// Only the window is listed: never every event the calendar has held.
    @Test func theCalendarsWholeHistoryIsNotListed() async throws {
        try await withGraphContacts { h in
            let home = await h.graph.addCalendar("Calendar")
            await h.graph.putEvent(
                graphEvent("Standup", "2026-03-02T08:00:00", "2026-03-02T08:15:00", graphWeekly), in: home)
            try await h.calendarSyncer().sync()
            #expect(!(await h.graph.requests.contains { $0.path.contains("calendars/\(home)/events") }))
            #expect(try h.held().count == 4)
        }
    }

    @Test func aMovedExceptionRefetchesTheSeries() async throws {
        try await withGraphContacts { h in
            let home = await h.graph.addCalendar("Calendar")
            let series = await h.graph.putEvent(
                graphEvent("Standup", "2026-03-02T08:00:00", "2026-03-02T08:15:00", graphWeekly), in: home)
            let syncer = h.calendarSyncer()
            try await syncer.sync()
            let moved: [String: Any] = [
                "subject": "Standup, later", "start": ["dateTime": "2026-03-16T10:00:00", "timeZone": "UTC"],
                "end": ["dateTime": "2026-03-16T10:15:00", "timeZone": "UTC"],
            ]
            await h.graph.addException(of: series, at: try utc("2026-03-16T08:00:00Z"), graphJSON(moved))
            try await syncer.sync()
            let held = try h.held()
            #expect(held.count == 4)
            let later = try utc("2026-03-16T10:00:00Z")
            #expect(held.first { $0.title == "Standup, later" }?.start == later)
        }
    }

    @Test func anEventGoneFromTheViewIsRemoved() async throws {
        try await withGraphContacts { h in
            let home = await h.graph.addCalendar("Calendar")
            let lunch = await h.graph.putEvent(graphEvent("Lunch", "2026-03-04T11:00:00", "2026-03-04T12:00:00"), in: home)
            let syncer = h.calendarSyncer()
            try await syncer.sync()
            await h.graph.removeEvent(lunch)
            try await syncer.sync()
            #expect(try h.held().isEmpty)
        }
    }

    @Test func anEventWithAnUnsentChangeIsKept() async throws {
        try await withGraphContacts { h in
            let home = await h.graph.addCalendar("Calendar")
            let lunch = await h.graph.putEvent(graphEvent("Lunch", "2026-03-04T11:00:00", "2026-03-04T12:00:00"), in: home)
            let syncer = h.calendarSyncer()
            try await syncer.sync()
            let held = try #require(try h.store.occurrences(
                from: graphNow, to: graphNow.addingTimeInterval(30 * 86_400), in: nil).first)
            var edited = held.occurrence.details
            edited.title = "Mine"
            try h.store.updateEvent(held.id, edited, rule: nil, scope: .event)
            await h.graph.removeEvent(lunch)
            try? await syncer.sync()
            #expect(try h.held().map(\.title).contains("Mine"))
        }
    }

    @Test func anUnreadableEventIsRefusedOnce() async throws {
        try await withGraphContacts { h in
            let home = await h.graph.addCalendar("Calendar")
            let lunar: [String: Any] = [
                "recurrence": [
                    "pattern": ["type": "lunar", "interval": 1],
                    "range": ["type": "numbered", "startDate": "2026-03-02", "numberOfOccurrences": 3],
                ] as [String: Any],
            ]
            let odd = await h.graph.putEvent(
                graphEvent("Odd", "2026-03-02T08:00:00", "2026-03-02T09:00:00", lunar), in: home)
            let syncer = h.calendarSyncer()
            try await syncer.sync()
            try await syncer.sync()
            #expect(try h.held().isEmpty)
            #expect(await h.eventGets(odd) == 1)
        }
    }

    @Test func aSecond401IsSignInAgain() async throws {
        try await withGraphContacts { h in
            await h.graph.addCalendar("Calendar")
            await h.graph.setAcceptedTokens([])
            await #expect(throws: SyncError.needsSignIn(h.account.id)) { try await h.calendarSyncer().sync() }
        }
    }

    @Test func a429StopsTheRun() async throws {
        try await withGraphContacts { h in
            await h.graph.addCalendar("Calendar")
            await h.graph.failNext(status: 429)
            await #expect(throws: SyncError.graph(.throttled)) { try await h.calendarSyncer().sync() }
        }
    }

    @Test func aPasswordAccountIsLeftAlone() async throws {
        try await withGraphContacts { h in
            var plain = h.account
            plain.auth = .password
            plain.calendarVia = .calDAV
            plain.contactsVia = .cardDAV
            let syncer = GraphCalendarSyncer(
                account: plain, store: h.store, credentials: h.microsoft.credentials, lock: AccountLock(), base: h.base,
                session: URLSession(configuration: .ephemeral), now: { graphNow }, phoneZone: { stockholm })
            try await syncer.sync()
            #expect(await h.graph.requests.isEmpty)
        }
    }
}
