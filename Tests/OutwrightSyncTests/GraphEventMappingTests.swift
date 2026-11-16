// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightModel
import Testing

@testable import OutwrightSync


private func time(_ text: String, _ zone: String = "UTC") -> [String: Any] {
    ["dateTime": text, "timeZone": zone]
}

/// A Graph event: ten Mondays at 08:00 UTC (09:00 in Stockholm) from 2026-03-02, unless changed.
private func weekly(_ changes: [String: Any] = [:], pattern: [String: Any]? = nil, range: [String: Any]? = nil)
    -> [String: Any] {
    var object: [String: Any] = [
        "id": "series-1", "@odata.etag": #"W/"ck1""#, "type": "seriesMaster", "subject": "Standup",
        "start": time("2026-03-02T08:00:00.0000000"), "end": time("2026-03-02T08:15:00.0000000"),
        "originalStartTimeZone": "W. Europe Standard Time", "originalEndTimeZone": "W. Europe Standard Time",
        "recurrence": [
            "pattern": pattern ?? ["type": "weekly", "interval": 1, "daysOfWeek": ["monday"], "firstDayOfWeek": "monday"],
            "range": range ?? ["type": "numbered", "startDate": "2026-03-02", "numberOfOccurrences": 10],
        ] as [String: Any],
    ]
    for (key, value) in changes { object[key] = value }
    return object
}

private func single(_ changes: [String: Any] = [:]) -> [String: Any] {
    var object: [String: Any] = [
        "id": "single-1", "@odata.etag": #"W/"ck1""#, "type": "singleInstance", "subject": "Lunch",
        "body": ["contentType": "text", "content": "At noon"], "location": ["displayName": "Café"],
        "start": time("2026-03-04T11:00:00.0000000"), "end": time("2026-03-04T12:00:00.0000000"),
        "originalStartTimeZone": "W. Europe Standard Time",
    ]
    for (key, value) in changes { object[key] = value }
    return object
}

private func occurrences(_ series: EventSeries) -> [Occurrence] {
    Recurrence.occurrences(
        series, from: Date(timeIntervalSince1970: 1_767_225_600), to: Date(timeIntervalSince1970: 1_830_297_600),
        phoneZone: stockholm)
}

private func localHours(_ found: [Occurrence]) -> [Int] {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = stockholm
    return found.map { calendar.component(.hour, from: $0.start) }
}

private func days(_ found: [Occurrence]) -> [String] {
    let format = DateFormatter()
    format.locale = Locale(identifier: "en_US_POSIX")
    format.timeZone = stockholm
    format.dateFormat = "yyyy-MM-dd"
    return found.map { format.string(from: $0.start) }
}

@Suite struct GraphEventMappingTests {
    @Test func utcTimesBecomeWallTimeInTheEventsZone() throws {
        let series = try #require(GraphEventMapping.series(graphJSON(weekly())))
        let found = occurrences(series)
        #expect(found.count == 10)
        // 2026-03-29 moves the clocks: every Monday stays at nine.
        #expect(localHours(found) == Array(repeating: 9, count: 10))
        #expect(series.base?.start == .zoned(
            DateComponents(year: 2026, month: 3, day: 2, hour: 9, minute: 0, second: 0), zone: "Europe/Berlin"))
    }

    @Test func allDayEastOfUTCKeepsItsDay() throws {
        let event = single([
            "isAllDay": true, "start": time("2026-03-03T23:00:00.0000000"), "end": time("2026-03-04T23:00:00.0000000"),
        ])
        let series = try #require(GraphEventMapping.series(graphJSON(event)))
        #expect(series.base?.start == .date(year: 2026, month: 3, day: 4))
        #expect(series.base?.end == .date(year: 2026, month: 3, day: 5))
    }

    /// An all-day event in a zone not known here still keeps its day, east or west of UTC.
    @Test(arguments: ["2026-03-03T23:00:00.0000000", "2026-03-04T05:00:00.0000000", "2026-03-04T00:00:00.0000000"])
    func allDayInAnUnknownZoneKeepsItsDay(_ start: String) throws {
        let event = single([
            "isAllDay": true, "originalStartTimeZone": "tzone://Microsoft/Custom", "start": time(start),
            "end": time(start),
        ])
        let series = try #require(GraphEventMapping.series(graphJSON(event)))
        #expect(series.base?.start == .date(year: 2026, month: 3, day: 4))
    }

    @Test func unknownZoneStaysUTC() throws {
        let series = try #require(GraphEventMapping.series(graphJSON(single(["originalStartTimeZone": "tzone://Microsoft/Custom"]))))
        #expect(series.base?.start == .utc(Date(timeIntervalSince1970: 1_772_622_000)))
    }

    @Test func timesGivenInAnotherZoneAreReadInIt() throws {
        let event = single(["start": time("2026-03-04T12:00:00", "W. Europe Standard Time"),
                            "end": time("2026-03-04T13:00:00", "W. Europe Standard Time")])
        let found = occurrences(try #require(GraphEventMapping.series(graphJSON(event))))
        #expect(found.first?.start == Date(timeIntervalSince1970: 1_772_622_000))
    }

    @Test func singleEventsDetails() throws {
        let event = single([
            "isReminderOn": true, "reminderMinutesBeforeStart": 15, "showAs": "tentative",
            "organizer": ["emailAddress": ["address": "boss@example.org", "name": "Boss"]],
            "attendees": [
                ["emailAddress": ["address": "a@example.org", "name": "A"], "type": "required",
                 "status": ["response": "accepted"]],
                ["emailAddress": ["address": "b@example.org"], "type": "optional", "status": ["response": "tentativelyAccepted"]],
                ["emailAddress": ["address": "c@example.org"], "type": "required", "status": ["response": "declined"]],
                ["emailAddress": ["address": "d@example.org"], "type": "resource", "status": ["response": "none"]],
            ],
        ])
        let series = try #require(GraphEventMapping.series(graphJSON(event)))
        let base = try #require(series.base)
        #expect(series.rule == nil && series.uid == "single-1")
        #expect(base.title == "Lunch" && base.place == "Café" && base.notes == "At noon")
        #expect(base.reminder == 15 && base.organizer == "boss@example.org" && base.status == .tentative)
        #expect(base.attendees.map(\.response) == [.accepted, .tentative, .declined, .needsAction])
        #expect(base.attendees.map(\.role) == ["REQ-PARTICIPANT", "OPT-PARTICIPANT", "REQ-PARTICIPANT", "NON-PARTICIPANT"])
        #expect(base.attendees.first?.name == "A")
    }

    @Test func theInviteesOwnAnswerComesFromItsResponseStatus() throws {
        let event = single([
            "isOrganizer": false, "organizer": ["emailAddress": ["address": "boss@example.org"]],
            "attendees": [["emailAddress": ["address": "Me@Example.org"], "status": ["response": "none"]]],
            "responseStatus": ["response": "tentativelyAccepted"],
        ])
        let series = try #require(GraphEventMapping.series(graphJSON(event), ownEmail: "me@example.org"))
        #expect(series.base?.attendees.map(\.response) == [.tentative])
        let unlisted = single([
            "isOrganizer": false, "organizer": ["emailAddress": ["address": "boss@example.org"]],
            "responseStatus": ["response": "accepted"],
        ])
        let added = try #require(GraphEventMapping.series(graphJSON(unlisted), ownEmail: "me@example.org"))
        #expect(added.base?.attendees.map(\.email) == ["me@example.org"])
        #expect(added.base?.attendees.map(\.response) == [.accepted])
        // Someone else's event in a shared calendar says "none": the account is not made an invitee.
        let shared = single([
            "isOrganizer": false, "organizer": ["emailAddress": ["address": "boss@example.org"]],
            "responseStatus": ["response": "none"],
        ])
        let unanswered = try #require(GraphEventMapping.series(graphJSON(shared), ownEmail: "me@example.org"))
        #expect(unanswered.base?.attendees.isEmpty == true)
    }

    /// A GlobalObjectId ([MS-OXCICAL] 2.1.3.1.1.20.26) as hex: the class id, the instance date,
    /// eight bytes of creation time, eight zero, then the data's length and the data.
    private static func goid(date: [UInt8] = [0, 0, 0, 0], data: [UInt8]) -> String {
        let classID: [UInt8] = [
            0x04, 0x00, 0x00, 0x00, 0x82, 0x00, 0xE0, 0x00, 0x74, 0xC5, 0xB7, 0x10, 0x1A, 0x82, 0xE0, 0x08,
        ]
        let size = UInt32(data.count)
        let length: [UInt8] = [UInt8(size & 0xFF), UInt8((size >> 8) & 0xFF), UInt8((size >> 16) & 0xFF), UInt8(size >> 24)]
        let bytes = classID + date + [UInt8](repeating: 7, count: 8) + [UInt8](repeating: 0, count: 8) + length + data
        return bytes.map { String(format: "%02X", $0) }.joined()
    }

    @Test func aMeetingFromOutsideKeepsTheUIDItsInvitationNamed() throws {
        let data = Array("vCal-Uid".utf8) + [1, 0, 0, 0] + Array("meeting1@example.org".utf8) + [0]
        let series = try #require(GraphEventMapping.series(graphJSON(single(["iCalUId": Self.goid(data: data)]))))
        #expect(series.uid == "meeting1@example.org")
    }

    @Test func anExchangeMeetingIsItsCleanGlobalObjectID() throws {
        let data: [UInt8] = [0xAA, 0xBB, 0xCC]
        let occurrence = Self.goid(date: [0x07, 0xEA, 0x03, 0x04], data: data)
        let series = try #require(GraphEventMapping.series(graphJSON(single(["iCalUId": occurrence]))))
        #expect(series.uid == Self.goid(data: data))
    }

    @Test func aUIDThatIsNoGlobalObjectIDStaysAsItIs() throws {
        let classID = "040000008200E00074C5B7101A82E008"
        for uid in ["plain@example.org", classID, classID + "00", classID + "0000000007070707070707070000000000000000FFFFFFFF"] {
            let series = try #require(GraphEventMapping.series(graphJSON(single(["iCalUId": uid]))))
            #expect(series.uid == uid)
        }
    }

    @Test func reminderOffIsNone() throws {
        let series = try #require(GraphEventMapping.series(graphJSON(single(["isReminderOn": false, "reminderMinutesBeforeStart": 15]))))
        #expect(series.base?.reminder == nil)
    }

    @Test func showAsFreeAndCancelled() throws {
        let free = try #require(GraphEventMapping.series(graphJSON(single(["showAs": "free"]))))
        #expect(free.base?.transparency == .free && free.base?.status == .confirmed)
        let cancelled = try #require(GraphEventMapping.series(graphJSON(single(["isCancelled": true]))))
        #expect(cancelled.base?.status == .cancelled)
    }

    @Test func theAccountsOwnEventHasNoOtherOrganizer() throws {
        let event = single(["isOrganizer": true, "organizer": ["emailAddress": ["address": "alias@example.org"]]])
        let series = try #require(GraphEventMapping.series(graphJSON(event)))
        #expect(series.base?.organizer == nil)
    }

    @Test func iCalUIDIsTheSeriesUID() throws {
        let series = try #require(GraphEventMapping.series(graphJSON(single(["iCalUId": "040000008200E00074C5B7101A82E008"]))))
        #expect(series.uid == "040000008200E00074C5B7101A82E008")
    }

    // MARK: Patterns

    @Test func daily() throws {
        let series = try #require(GraphEventMapping.series(graphJSON(weekly(pattern: ["type": "daily", "interval": 2]))))
        #expect(series.rule == RecurrenceRule(freq: .daily, interval: 2, count: 10))
    }

    @Test func weeklyOnSeveralDays() throws {
        let pattern: [String: Any] = ["type": "weekly", "interval": 1, "daysOfWeek": ["monday", "thursday"],
                                      "firstDayOfWeek": "sunday"]
        let series = try #require(GraphEventMapping.series(graphJSON(weekly(pattern: pattern))))
        #expect(series.rule == RecurrenceRule(
            freq: .weekly, count: 10, byDay: [WeekdayNum(weekday: 1), WeekdayNum(weekday: 4)], weekStart: 7))
    }

    @Test func absoluteMonthly() throws {
        let series = try #require(GraphEventMapping.series(graphJSON(weekly(pattern: ["type": "absoluteMonthly", "interval": 1, "dayOfMonth": 2]))))
        #expect(series.rule == RecurrenceRule(freq: .monthly, count: 10, byMonthDay: [2]))
    }

    @Test func relativeMonthlyLastFriday() throws {
        let pattern: [String: Any] = ["type": "relativeMonthly", "interval": 1, "daysOfWeek": ["friday"], "index": "last"]
        let series = try #require(GraphEventMapping.series(graphJSON(weekly(pattern: pattern))))
        #expect(series.rule == RecurrenceRule(freq: .monthly, count: 10, byDay: [WeekdayNum(weekday: 5, ordinal: -1)]))
    }

    @Test func relativeMonthlySeveralDaysUsesSetPos() throws {
        let pattern: [String: Any] = ["type": "relativeMonthly", "interval": 1, "daysOfWeek": ["saturday", "sunday"],
                                      "index": "first"]
        let series = try #require(GraphEventMapping.series(graphJSON(weekly(pattern: pattern))))
        #expect(series.rule == RecurrenceRule(
            freq: .monthly, count: 10, byDay: [WeekdayNum(weekday: 6), WeekdayNum(weekday: 7)], bySetPos: [1]))
    }

    @Test func absoluteYearly() throws {
        let pattern: [String: Any] = ["type": "absoluteYearly", "interval": 1, "month": 3, "dayOfMonth": 2]
        let series = try #require(GraphEventMapping.series(graphJSON(weekly(pattern: pattern))))
        #expect(series.rule == RecurrenceRule(freq: .yearly, count: 10, byMonthDay: [2], byMonth: [3]))
    }

    @Test func relativeYearly() throws {
        let pattern: [String: Any] = ["type": "relativeYearly", "interval": 1, "month": 11, "daysOfWeek": ["thursday"],
                                      "index": "fourth"]
        let series = try #require(GraphEventMapping.series(graphJSON(weekly(pattern: pattern))))
        #expect(series.rule == RecurrenceRule(freq: .yearly, count: 10, byDay: [WeekdayNum(weekday: 4, ordinal: 4)], byMonth: [11]))
    }

    @Test func endDateIsInclusive() throws {
        let range: [String: Any] = ["type": "endDate", "startDate": "2026-03-02", "endDate": "2026-03-16"]
        let series = try #require(GraphEventMapping.series(graphJSON(weekly(range: range))))
        #expect(days(occurrences(series)) == ["2026-03-02", "2026-03-09", "2026-03-16"])
    }

    @Test func noEnd() throws {
        let series = try #require(GraphEventMapping.series(graphJSON(weekly(range: ["type": "noEnd", "startDate": "2026-03-02"]))))
        #expect(series.rule?.count == nil && series.rule?.until == nil)
    }

    @Test func anUnknownPatternIsUnreadable() {
        #expect(GraphEventMapping.series(graphJSON(weekly(pattern: ["type": "lunar", "interval": 1]))) == nil)
    }

    // MARK: Exceptions and cancellations

    @Test func exceptionsBecomeOverridesAtOriginalStart() throws {
        let exception: [String: Any] = [
            "id": "exception-1", "type": "exception", "subject": "Standup, later",
            "originalStart": "2026-03-16T08:00:00Z",
            "start": time("2026-03-16T10:00:00.0000000"), "end": time("2026-03-16T10:15:00.0000000"),
        ]
        let series = try #require(GraphEventMapping.series(graphJSON(weekly(["exceptionOccurrences": [exception]]))))
        let found = occurrences(series)
        #expect(found.count == 10)
        let moved = try #require(found.first { $0.details.title == "Standup, later" })
        #expect(localHours([moved]) == [11])
        #expect(days(found).filter { $0 == "2026-03-16" }.count == 1)
    }

    @Test func cancelledOccurrencesBecomeExdates() throws {
        let series = try #require(GraphEventMapping.series(graphJSON(weekly([
            "cancelledOccurrences": ["OID.series-1.2026-03-09", "OID.series-1.2026-04-06", "nonsense"],
        ]))))
        let found = days(occurrences(series))
        #expect(found.count == 8 && !found.contains("2026-03-09") && !found.contains("2026-04-06"))
    }

    /// A series held in UTC (its zone not known here) at 23:30 UTC: a day east of UTC names its
    /// occurrences by the next date, and the cancelled one is the one at 23:30 the evening before.
    @Test func aCancelledDayOfAUTCSeriesIsTheNearestOccurrence() throws {
        let series = try #require(GraphEventMapping.series(graphJSON(weekly([
            "originalStartTimeZone": "tzone://Microsoft/Custom", "originalEndTimeZone": "tzone://Microsoft/Custom",
            "start": time("2026-03-01T23:30:00"), "end": time("2026-03-01T23:45:00"),
            "cancelledOccurrences": ["OID.series-1.2026-03-09"],
        ], pattern: ["type": "weekly", "interval": 1, "daysOfWeek": ["sunday"]]))))
        let starts = occurrences(series).map(\.start)
        let cancelled = Date(timeIntervalSince1970: 1_773_012_600) // 2026-03-08 23:30 UTC
        #expect(starts.count == 9 && !starts.contains(cancelled))
    }

    // MARK: Writing

    @Test func createBodyCarriesEverything() throws {
        let details = EventDetails(
            title: "Plan", place: "Room 1", notes: "Agenda",
            start: .zoned(DateComponents(year: 2026, month: 3, day: 5, hour: 10, minute: 0, second: 0), zone: "Europe/Stockholm"),
            end: .zoned(DateComponents(year: 2026, month: 3, day: 5, hour: 11, minute: 0, second: 0), zone: "Europe/Stockholm"),
            reminder: 15, attendees: [Attendee(email: "a@example.org", name: "A")])
        let body = GraphEventMapping.body(details, rule: RecurrenceRule(freq: .weekly), over: nil, phoneZone: stockholm)
        #expect(body["subject"] as? String == "Plan")
        #expect((body["body"] as? [String: String]) == ["contentType": "text", "content": "Agenda"])
        #expect((body["location"] as? [String: String]) == ["displayName": "Room 1"])
        let start = try #require(body["start"] as? [String: String])
        #expect(start["dateTime"] == "2026-03-05T10:00:00")
        // A Windows name whose clock is Stockholm's, winter and summer.
        guard case let .iana(id) = ZoneResolver.resolve(tzid: start["timeZone"] ?? "", given: [:]),
            let named = TimeZone(identifier: id)
        else { Issue.record("not a known zone"); return }
        for instant in [1_767_225_600.0, 1_783_000_000.0] {
            let date = Date(timeIntervalSince1970: instant)
            #expect(named.secondsFromGMT(for: date) == stockholm.secondsFromGMT(for: date))
        }
        #expect(start["timeZone"]?.hasSuffix("Standard Time") == true)
        #expect(body["isAllDay"] as? Bool == false)
        #expect(body["isReminderOn"] as? Bool == true && body["reminderMinutesBeforeStart"] as? Int == 15)
        let attendees = try #require(body["attendees"] as? [[String: any Sendable]])
        #expect((attendees.first?["emailAddress"] as? [String: String]) == ["address": "a@example.org", "name": "A"])
        let recurrence = try #require(body["recurrence"] as? [String: any Sendable])
        let pattern = try #require(recurrence["pattern"] as? [String: any Sendable])
        #expect(pattern["type"] as? String == "weekly" && (pattern["daysOfWeek"] as? [String]) == ["thursday"])
        #expect(JSONSerialization.isValidJSONObject(body))
    }

    @Test func updateBodyCarriesOnlyChangedProperties() throws {
        let held = try #require(GraphEventMapping.series(graphJSON(single([
            "body": ["contentType": "html", "content": "<b>At noon</b>"],
            "attendees": [["emailAddress": ["address": "a@example.org"], "type": "required"]],
        ]))))
        var edited = try #require(held.base)
        edited.title = "Dinner"
        let body = GraphEventMapping.body(edited, rule: nil, over: (held.base, held.rule), phoneZone: stockholm)
        #expect(Set(body.keys) == ["subject"])
    }

    /// The editor trims what is typed; Graph's text often ends in a line break: not an edit.
    @Test func surroundingWhitespaceIsNotAChange() throws {
        let held = try #require(GraphEventMapping.series(graphJSON(single([
            "subject": " Lunch", "body": ["contentType": "text", "content": "At noon\r\n"],
            "location": ["displayName": "Café\n"],
        ]))))
        var edited = try #require(held.base)
        (edited.title, edited.notes, edited.place) = ("Dinner", "At noon", "Café")
        let body = GraphEventMapping.body(edited, rule: nil, over: (held.base, held.rule), phoneZone: stockholm)
        #expect(Set(body.keys) == ["subject"])
    }

    /// A note longer than the app holds, untouched by an edit of the title, is not sent (so not cut).
    @Test func aLongNoteIsNotSentWhenTheTitleChanges() throws {
        let long = String(repeating: "Agenda ", count: 20_000)
        let held = try #require(GraphEventMapping.series(graphJSON(single(["body": ["contentType": "text", "content": long]]))))
        var edited = try #require(held.base)
        edited.title = "Dinner"
        let body = GraphEventMapping.body(edited, rule: nil, over: (held.base, held.rule), phoneZone: stockholm)
        #expect(Set(body.keys) == ["subject"])
    }

    @Test func removingTheRepeatSendsNull() throws {
        let held = try #require(GraphEventMapping.series(graphJSON(weekly())))
        let body = GraphEventMapping.body(try #require(held.base), rule: nil, over: (held.base, held.rule), phoneZone: stockholm)
        #expect(Set(body.keys) == ["recurrence"] && body["recurrence"] is NSNull)
    }

    @Test func allDayIsWrittenAsMidnights() throws {
        let details = EventDetails(title: "Off", start: .date(year: 2026, month: 3, day: 5), end: .date(year: 2026, month: 3, day: 6))
        let body = GraphEventMapping.body(details, rule: nil, over: nil, phoneZone: stockholm)
        #expect(body["isAllDay"] as? Bool == true)
        #expect((body["start"] as? [String: String])?["dateTime"] == "2026-03-05T00:00:00")
        #expect((body["end"] as? [String: String])?["dateTime"] == "2026-03-06T00:00:00")
    }

    /// Every repeat the editor offers survives a trip through Graph's pattern: the same occurrences.
    @Test(arguments: [
        RecurrenceRule(freq: .daily), RecurrenceRule(freq: .weekly), RecurrenceRule(freq: .weekly, interval: 2),
        RecurrenceRule(freq: .monthly), RecurrenceRule(freq: .yearly),
        RecurrenceRule(freq: .weekly, count: 5), RecurrenceRule(freq: .monthly, until: .date(year: 2026, month: 12, day: 31)),
    ])
    func roundTripOfEveryOfferedRepeat(_ rule: RecurrenceRule) throws {
        let start = EventTime.zoned(DateComponents(year: 2026, month: 3, day: 5, hour: 10, minute: 0, second: 0), zone: "Europe/Stockholm")
        let end = EventTime.zoned(DateComponents(year: 2026, month: 3, day: 5, hour: 11, minute: 0, second: 0), zone: "Europe/Stockholm")
        let details = EventDetails(title: "R", start: start, end: end)
        let recurrence = try #require(GraphRecurrence.recurrence(rule, start: start, zone: "W. Europe Standard Time"))
        let back = try #require(GraphRecurrence.rule(recurrence))
        let original = occurrences(EventSeries(uid: "u", base: details, rule: rule)).map(\.start)
        let tripped = occurrences(EventSeries(uid: "u", base: details, rule: back)).map(\.start)
        #expect(!original.isEmpty && original == tripped)
    }

    /// A UTC UNTIL ends the series on its date in the start's zone, not on its UTC date.
    @Test func utcUntilEndsOnItsDateInTheStartsZone() throws {
        let start = EventTime.zoned(
            DateComponents(year: 2026, month: 5, day: 1, hour: 20, minute: 0, second: 0), zone: "America/New_York")
        let until = try #require(ISO8601DateFormatter().date(from: "2026-05-11T03:59:59Z"))
        let rule = RecurrenceRule(freq: .daily, until: .utc(until))
        let recurrence = try #require(GraphRecurrence.recurrence(rule, start: start, zone: "Eastern Standard Time"))
        let range = try #require(recurrence["range"] as? [String: any Sendable])
        #expect(range["endDate"] as? String == "2026-05-10")
    }

    @Test func whatGraphCannotHold() {
        let start = EventTime.date(year: 2026, month: 3, day: 5)
        #expect(!GraphEventMapping.canHold(RecurrenceRule(freq: .hourly), start: start))
        #expect(!GraphEventMapping.canHold(RecurrenceRule(freq: .yearly, byMonth: [3, 6]), start: start))
        #expect(!GraphEventMapping.canHold(RecurrenceRule(freq: .monthly, byDay: [WeekdayNum(weekday: 1, ordinal: 5)]), start: start))
        #expect(GraphEventMapping.canHold(RecurrenceRule(freq: .weekly, interval: 3), start: start))
    }
}
