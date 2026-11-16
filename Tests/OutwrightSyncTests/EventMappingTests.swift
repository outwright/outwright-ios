// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightDAV
import OutwrightModel
import Testing

@testable import OutwrightSync

/// iCalendar text from lines, CRLF ended.
func icsText(_ lines: [String]) -> String {
    lines.joined(separator: "\r\n") + "\r\n"
}

private func calendar(_ lines: [String]) throws -> ICalComponent {
    try ICalendarReader.calendar(Data(icsText(lines).utf8))
}

/// The calendar written and read back, as the server would hand it over.
private func roundTrip(_ calendar: ICalComponent) throws -> ICalComponent {
    try ICalendarReader.calendar(ICalendarWriter.write(calendar))
}

private func wall(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> DateComponents {
    DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: 0)
}

private func events(_ calendar: ICalComponent) -> [ICalComponent] {
    calendar.components.filter { $0.name == "VEVENT" }
}

private let weekly = [
    "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Example//EN",
    "BEGIN:VEVENT", "UID:w@example.org", "DTSTAMP:20261101T080000Z",
    "DTSTART;TZID=Europe/Stockholm:20261109T090000", "DTEND;TZID=Europe/Stockholm:20261109T093000",
    "RRULE:FREQ=WEEKLY;COUNT=10", "SUMMARY:Standup", "SEQUENCE:2",
    "BEGIN:VALARM", "ACTION:DISPLAY", "DESCRIPTION:Reminder", "TRIGGER:-PT10M", "END:VALARM",
    "END:VEVENT",
    "BEGIN:VEVENT", "UID:w@example.org", "RECURRENCE-ID;TZID=Europe/Stockholm:20261116T090000",
    "DTSTART;TZID=Europe/Stockholm:20261116T100000", "DTEND;TZID=Europe/Stockholm:20261116T103000",
    "SUMMARY:Standup (moved)", "END:VEVENT",
    "END:VCALENDAR",
]

@Suite struct EventMappingTests {
    @Test func mapsSeriesWithOverridesAndAlarm() throws {
        let found = EventMapping.series(try calendar(weekly))
        #expect(found.count == 1)
        let series = try #require(found.first)
        #expect(series.uid == "w@example.org")
        let base = try #require(series.base)
        #expect(base.title == "Standup")
        #expect(base.start == .zoned(wall(2026, 11, 9, 9), zone: "Europe/Stockholm"))
        #expect(base.end == .zoned(wall(2026, 11, 9, 9, 30), zone: "Europe/Stockholm"))
        #expect(base.reminder == 10)
        #expect(base.sequence == 2)
        #expect(series.rule?.freq == .weekly)
        #expect(series.rule?.count == 10)
        #expect(series.overrides.count == 1)
        #expect(series.overrides.first?.recurrenceID == .zoned(wall(2026, 11, 16, 9), zone: "Europe/Stockholm"))
        #expect(series.overrides.first?.details.title == "Standup (moved)")
        #expect(series.overrides.first?.details.start == .zoned(wall(2026, 11, 16, 10), zone: "Europe/Stockholm"))
    }

    private static let ranged = [
        "BEGIN:VCALENDAR",
        "BEGIN:VEVENT", "UID:r@example.org", "DTSTART;TZID=Europe/Stockholm:20261109T090000",
        "DTEND;TZID=Europe/Stockholm:20261109T093000", "RRULE:FREQ=WEEKLY;COUNT=3", "SUMMARY:Sync", "END:VEVENT",
        "BEGIN:VEVENT", "UID:r@example.org", "RECURRENCE-ID;RANGE=THISANDFUTURE;TZID=Europe/Stockholm:20261116T090000",
        "DTSTART;TZID=Europe/Stockholm:20261116T100000", "DTEND;TZID=Europe/Stockholm:20261116T103000",
        "SUMMARY:Sync later", "END:VEVENT",
        "END:VCALENDAR",
    ]

    /// Issue #41: RANGE=THISANDFUTURE moves its own occurrence and every later one.
    @Test func thisAndFutureMovesEveryLaterOccurrence() throws {
        let found = EventMapping.series(try calendar(Self.ranged))
        let series = try #require(found.first)
        #expect(series.overrides.map(\.thisAndFuture) == [true])
        let zone = TimeZone(identifier: "Europe/Stockholm") ?? .gmt
        let laid = Recurrence.occurrences(
            series, from: Date(timeIntervalSince1970: 1_793_000_000), to: Date(timeIntervalSince1970: 1_796_000_000),
            phoneZone: zone)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        #expect(laid.map { calendar.component(.hour, from: $0.start) } == [9, 10, 10])
        #expect(laid.map(\.details.title) == ["Sync", "Sync later", "Sync later"])
    }

    @Test func plainRecurrenceIDIsItsOwnOccurrenceOnly() throws {
        let series = try #require(EventMapping.series(try calendar(weekly)).first)
        #expect(series.overrides.map(\.thisAndFuture) == [false])
    }

    @Test func editsKeepARangeAsItCame() throws {
        let held = try calendar(Self.ranged)
        let start = EventTime.zoned(wall(2026, 11, 16, 9), zone: "Europe/Stockholm")
        let series = try #require(EventMapping.series(held).first)
        var details = try #require(series.overrides.first?.details)
        details.title = "Sync renamed"
        let renamed = try roundTrip(EventMapping.apply(
            .update(details, rule: nil, scope: .occurrence(start)), to: held, uid: "r@example.org",
            organizer: "jk@example.org"))
        // The range's own occurrence changes alone: it becomes plain, and the range moves on to the 23rd.
        let lines = events(renamed).compactMap { $0.first("RECURRENCE-ID") }
        #expect(lines.map(\.value) == ["20261116T090000", "20261123T090000"])
        #expect(lines.map { $0.parameter("RANGE") } == [nil, "THISANDFUTURE"])
        let moved = try #require(events(renamed).first { $0.first("RECURRENCE-ID")?.value == "20261123T090000" })
        #expect(moved.first("DTSTART")?.value == "20261123T100000")
        #expect(moved.first("DTEND")?.value == "20261123T103000")
        #expect(moved.first("SUMMARY")?.value == "Sync later")
        let renamedSeries = try #require(EventMapping.series(renamed).first)
        #expect(laidOut(renamedSeries).map(\.hour) == [9, 10, 10])
        #expect(laidOut(renamedSeries).map(\.title) == ["Sync", "Sync renamed", "Sync later"])

        // A "This event" edit of a later occurrence writes a plain override; the range has none left.
        let last = EventTime.zoned(wall(2026, 11, 23, 9), zone: "Europe/Stockholm")
        details.start = .zoned(wall(2026, 11, 23, 13), zone: "Europe/Stockholm")
        details.end = .zoned(wall(2026, 11, 23, 13, 30), zone: "Europe/Stockholm")
        let single = try roundTrip(EventMapping.apply(
            .update(details, rule: nil, scope: .occurrence(last)), to: renamed, uid: "r@example.org",
            organizer: "jk@example.org"))
        let overrides = try #require(EventMapping.series(single).first?.overrides)
        #expect(overrides.map(\.recurrenceID) == [start, last])
        #expect(overrides.map(\.thisAndFuture) == [false, false])
        let ranges: [String] = events(single).compactMap { $0.first("RECURRENCE-ID")?.parameter("RANGE") }
        #expect(ranges.isEmpty)
    }

    @Test func deletingTheRangeOwnOccurrenceMovesTheRangeOn() throws {
        let held = try calendar(Self.ranged)
        let start = EventTime.zoned(wall(2026, 11, 16, 9), zone: "Europe/Stockholm")
        let deleted = try roundTrip(EventMapping.apply(
            .delete(scope: .occurrence(start)), to: held, uid: "r@example.org", organizer: "jk@example.org"))
        let lines = events(deleted).compactMap { $0.first("RECURRENCE-ID") }
        #expect(lines.map(\.value) == ["20261123T090000"])
        #expect(lines.map { $0.parameter("RANGE") } == ["THISANDFUTURE"])
        let series = try #require(EventMapping.series(deleted).first)
        #expect(series.exdates == [start])
        #expect(laidOut(series).map(\.hour) == [9, 10])
        #expect(laidOut(series).map(\.title) == ["Sync", "Sync later"])
    }

    /// Two ranges: from the 16th at 10:00, and from the 23rd at 11:00.
    private static let twoRanges = [
        "BEGIN:VCALENDAR",
        "BEGIN:VEVENT", "UID:r@example.org", "DTSTART;TZID=Europe/Stockholm:20261109T090000",
        "DTEND;TZID=Europe/Stockholm:20261109T093000", "RRULE:FREQ=WEEKLY;COUNT=4", "SUMMARY:Sync", "END:VEVENT",
        "BEGIN:VEVENT", "UID:r@example.org", "RECURRENCE-ID;RANGE=THISANDFUTURE;TZID=Europe/Stockholm:20261116T090000",
        "DTSTART;TZID=Europe/Stockholm:20261116T100000", "DTEND;TZID=Europe/Stockholm:20261116T103000",
        "SUMMARY:Sync later", "END:VEVENT",
        "BEGIN:VEVENT", "UID:r@example.org", "RECURRENCE-ID;RANGE=THISANDFUTURE;TZID=Europe/Stockholm:20261123T090000",
        "DTSTART;TZID=Europe/Stockholm:20261123T110000", "DTEND;TZID=Europe/Stockholm:20261123T113000",
        "SUMMARY:Sync latest", "END:VEVENT",
        "END:VCALENDAR",
    ]

    @Test func splittingARangeStopsAtTheNextRange() throws {
        let held = try calendar(Self.twoRanges)
        let start = EventTime.zoned(wall(2026, 11, 16, 9), zone: "Europe/Stockholm")
        let series = try #require(EventMapping.series(held).first)
        var details = try #require(series.overrides.first { $0.recurrenceID == start }?.details)
        details.title = "Sync renamed"
        for edit in [EventEdit.update(details, rule: nil, scope: .occurrence(start)), .delete(scope: .occurrence(start))] {
            let written = try roundTrip(EventMapping.apply(edit, to: held, uid: "r@example.org",
                                                           organizer: "jk@example.org"))
            let lines = events(written).compactMap { $0.first("RECURRENCE-ID") }
            let ranges = lines.map { $0.parameter("RANGE") }
            if case .update = edit {
                #expect(lines.map(\.value) == ["20261116T090000", "20261123T090000"])
                #expect(ranges == [nil, "THISANDFUTURE"])
                #expect(laidOut(try #require(EventMapping.series(written).first)).map(\.title)
                    == ["Sync", "Sync renamed", "Sync latest"])
            } else {
                #expect(lines.map(\.value) == ["20261123T090000"])
                #expect(ranges == ["THISANDFUTURE"])
                #expect(laidOut(try #require(EventMapping.series(written).first)).map(\.title)
                    == ["Sync", "Sync latest"])
            }
            let latest = try #require(events(written).first { $0.first("RECURRENCE-ID")?.value == "20261123T090000" })
            #expect(latest.first("DTSTART")?.value == "20261123T110000")
            #expect(latest.first("SUMMARY")?.value == "Sync latest")
        }
    }

    @Test func aSeriesEditReachesARangeWhereItKeptTheSeriesFields() throws {
        let kept = Self.ranged.map { $0 == "SUMMARY:Sync later" ? "SUMMARY:Sync" : $0 }
        for (lines, title) in [(kept, "Daily"), (Self.ranged, "Sync later")] {
            let held = try calendar(lines)
            let series = try #require(EventMapping.series(held).first)
            var details = try #require(series.base)
            details.title = "Daily"
            details.place = "Room 1"
            let written = try roundTrip(EventMapping.apply(
                .update(details, rule: series.rule, scope: .event), to: held, uid: "r@example.org",
                organizer: "jk@example.org"))
            let range = try #require(events(written).first { $0.first("RECURRENCE-ID") != nil })
            #expect(range.first("SUMMARY")?.value == title)
            #expect(range.first("LOCATION")?.value == "Room 1")
            #expect(range.first("RECURRENCE-ID")?.parameter("RANGE") == "THISANDFUTURE")
            let laid = laidOut(try #require(EventMapping.series(written).first))
            #expect(laid.map(\.title) == ["Daily", title, title])
            #expect(laid.map(\.hour) == [9, 10, 10])
        }
    }

    @Test func anOccurrenceEditRewritesTheOverrideWithTheHighestSequence() throws {
        let held = try calendar([
            "BEGIN:VCALENDAR",
            "BEGIN:VEVENT", "UID:r@example.org", "DTSTART;TZID=Europe/Stockholm:20261109T090000",
            "DTEND;TZID=Europe/Stockholm:20261109T093000", "RRULE:FREQ=WEEKLY;COUNT=3", "SUMMARY:Sync", "END:VEVENT",
            "BEGIN:VEVENT", "UID:r@example.org", "RECURRENCE-ID;TZID=Europe/Stockholm:20261116T090000",
            "SEQUENCE:1", "DTSTART;TZID=Europe/Stockholm:20261116T100000",
            "DTEND;TZID=Europe/Stockholm:20261116T103000", "SUMMARY:Old", "END:VEVENT",
            "BEGIN:VEVENT", "UID:r@example.org", "RECURRENCE-ID;TZID=Europe/Stockholm:20261116T090000",
            "SEQUENCE:2", "DTSTART;TZID=Europe/Stockholm:20261116T110000",
            "DTEND;TZID=Europe/Stockholm:20261116T113000", "SUMMARY:New", "END:VEVENT",
            "END:VCALENDAR",
        ])
        let start = EventTime.zoned(wall(2026, 11, 16, 9), zone: "Europe/Stockholm")
        let series = try #require(EventMapping.series(held).first)
        #expect(laidOut(series).map(\.title) == ["Sync", "New", "Sync"])
        var details = try #require(series.overrides.first { $0.details.title == "New" }?.details)
        details.title = "Renamed"
        let written = try roundTrip(EventMapping.apply(
            .update(details, rule: nil, scope: .occurrence(start)), to: held, uid: "r@example.org",
            organizer: "jk@example.org"))
        let laid = laidOut(try #require(EventMapping.series(written).first))
        #expect(laid.map(\.title) == ["Sync", "Renamed", "Sync"])
        #expect(laid.map(\.hour) == [9, 11, 9])
        // The lower SEQUENCE's copy of the occurrence goes: one VEVENT per RECURRENCE-ID.
        let copies = events(written).filter { $0.first("RECURRENCE-ID")?.value == "20261116T090000" }
        #expect(copies.map { $0.first("SUMMARY")?.value } == ["Renamed"])
    }

    /// The hours and titles of the November occurrences of a series, in Stockholm.
    private func laidOut(_ series: EventSeries) -> [(hour: Int, title: String)] {
        let zone = TimeZone(identifier: "Europe/Stockholm") ?? .gmt
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return Recurrence.occurrences(
            series, from: Date(timeIntervalSince1970: 1_793_000_000), to: Date(timeIntervalSince1970: 1_796_000_000),
            phoneZone: zone
        ).map { (calendar.component(.hour, from: $0.start), $0.details.title) }
    }

    @Test func alarmAfterStartOrAbsoluteIsKeptButNotShown() throws {
        let found = EventMapping.series(try calendar([
            "BEGIN:VCALENDAR", "BEGIN:VEVENT", "UID:a@example.org", "DTSTART:20261109T090000Z",
            "BEGIN:VALARM", "ACTION:DISPLAY", "TRIGGER;VALUE=DATE-TIME:20261109T080000Z", "END:VALARM",
            "BEGIN:VALARM", "ACTION:DISPLAY", "TRIGGER;RELATED=END:-PT5M", "END:VALARM",
            "BEGIN:VALARM", "ACTION:DISPLAY", "TRIGGER:PT5M", "END:VALARM",
            "BEGIN:VALARM", "ACTION:AUDIO", "TRIGGER:-P1DT2H", "END:VALARM",
            "BEGIN:VALARM", "ACTION:DISPLAY", "TRIGGER:-PT15M", "END:VALARM",
            "END:VEVENT", "END:VCALENDAR",
        ]))
        #expect(found.first?.base?.reminder == 26 * 60)
        #expect(found.first?.base?.end == .utc(Date(timeIntervalSince1970: 1_794_214_800)))
    }

    @Test func outlookInvitationTimesResolve() throws {
        // An invitation as a common desktop client writes it: a Windows zone name with its own VTIMEZONE.
        let found = EventMapping.series(try calendar([
            "BEGIN:VCALENDAR", "METHOD:REQUEST", "PRODID:-//Example Corp//Desktop Mail//EN", "VERSION:2.0",
            "BEGIN:VTIMEZONE", "TZID:W. Europe Standard Time",
            "BEGIN:STANDARD", "DTSTART:16010101T030000", "TZOFFSETFROM:+0200", "TZOFFSETTO:+0100",
            "RRULE:FREQ=YEARLY;INTERVAL=1;BYDAY=-1SU;BYMONTH=10", "END:STANDARD",
            "BEGIN:DAYLIGHT", "DTSTART:16010101T020000", "TZOFFSETFROM:+0100", "TZOFFSETTO:+0200",
            "RRULE:FREQ=YEARLY;INTERVAL=1;BYDAY=-1SU;BYMONTH=3", "END:DAYLIGHT",
            "END:VTIMEZONE",
            "BEGIN:VEVENT",
            "ORGANIZER;CN=Boss:mailto:boss@example.org",
            "ATTENDEE;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE;CN=Jörgen:mailto:jk@example.org",
            "SUMMARY;LANGUAGE=sv-SE:Planering", "DTSTART;TZID=W. Europe Standard Time:20261110T140000",
            "DTEND;TZID=W. Europe Standard Time:20261110T150000", "UID:040000008200E00074C5B7101A82E008",
            "SEQUENCE:0", "STATUS:CONFIRMED", "TRANSP:OPAQUE",
            "X-EXAMPLE-BUSYSTATUS:TENTATIVE",
            "BEGIN:VALARM", "DESCRIPTION:REMINDER", "TRIGGER;RELATED=START:-PT15M", "ACTION:DISPLAY", "END:VALARM",
            "END:VEVENT", "END:VCALENDAR",
        ]))
        let base = try #require(found.first?.base)
        #expect(base.start == .zoned(wall(2026, 11, 10, 14), zone: "Europe/Berlin"))
        #expect(base.start.instant(in: .gmt) == Date(timeIntervalSince1970: 1_794_315_600))
        #expect(base.organizer == "boss@example.org")
        #expect(base.reminder == 15)
        #expect(!EventOwnership.isOrganizer(base, accountEmail: "jk@example.org"))
        let own = try #require(EventOwnership.ownAttendee(base, accountEmail: "jk@example.org"))
        #expect(own.response == .needsAction)
        #expect(own.rsvp)
        #expect(own.name == "Jörgen")
    }

    @Test func allDayAndDurationAndFloatingRead() throws {
        let found = EventMapping.series(try calendar([
            "BEGIN:VCALENDAR",
            "BEGIN:VEVENT", "UID:d@example.org", "DTSTART;VALUE=DATE:20261224", "SUMMARY:Holiday", "END:VEVENT",
            "BEGIN:VEVENT", "UID:f@example.org", "DTSTART:20261109T090000", "DURATION:PT1H30M", "END:VEVENT",
            "BEGIN:VEVENT", "UID:x@example.org", "DTSTART;TZID=Nowhere/Unknown:20261109T090000", "END:VEVENT",
            "BEGIN:VEVENT", "UID:bad@example.org", "DTSTART:not-a-time", "END:VEVENT",
            "END:VCALENDAR",
        ]))
        let byUID = Dictionary(found.map { ($0.uid, $0) }, uniquingKeysWith: { first, _ in first })
        #expect(byUID["d@example.org"]?.base?.start == .date(year: 2026, month: 12, day: 24))
        #expect(byUID["d@example.org"]?.base?.end == .date(year: 2026, month: 12, day: 25))
        #expect(byUID["f@example.org"]?.base?.end == .floating(wall(2026, 11, 9, 10, 30)))
        #expect(byUID["x@example.org"]?.base?.start == .floating(wall(2026, 11, 9, 9)))
        #expect(byUID["bad@example.org"]?.base == nil)
    }

    @Test func durationHoursAreExactAcrossTheClockChange() throws {
        // Stockholm moves its clocks from 02:00 to 03:00 on 28 March 2027.
        let found = EventMapping.series(try calendar([
            "BEGIN:VCALENDAR",
            "BEGIN:VEVENT", "UID:h@example.org", "DTSTART;TZID=Europe/Stockholm:20270328T013000", "DURATION:PT2H",
            "END:VEVENT",
            "BEGIN:VEVENT", "UID:d@example.org", "DTSTART;TZID=Europe/Stockholm:20270327T013000", "DURATION:P1D",
            "END:VEVENT",
            "END:VCALENDAR",
        ]))
        let hours = try #require(found.first { $0.uid == "h@example.org" }?.base)
        let start = try #require(hours.start.instant(in: .gmt))
        let end = try #require(hours.end.instant(in: .gmt))
        #expect(end.timeIntervalSince(start) == 7_200)
        // A day is nominal: the same wall time the next day.
        let day = try #require(found.first { $0.uid == "d@example.org" }?.base)
        #expect(day.end == .zoned(wall(2027, 3, 28, 1, 30), zone: "Europe/Stockholm"))
    }

    @Test(arguments: ["Europe/Stockholm", "America/New_York", "Australia/Sydney", "Asia/Jerusalem", "Asia/Tokyo"])
    func writtenZoneMatchesTheSystemInLaterYears(_ id: String) throws {
        let zone = try #require(EventMapping.vtimezone(id, year: 2026))
        let rules = try #require(EventMapping.zones(ICalComponent(name: "VCALENDAR", components: [zone]))[id])
        // Around the months the clocks change in, here and south of the equator. (Reading a zone back is
        // slow: a few samples only.)
        for year in [2031, 2045] {
            for month in [3, 4, 10, 11] {
                for day in [1, 15, 29] {
                    let own = EventTime.zoned(wall(year, month, day, 12), zone: "Own").instant(in: .gmt, zones: ["Own": rules])
                    let system = EventTime.zoned(wall(year, month, day, 12), zone: id).instant(in: .gmt)
                    #expect(own == system, "\(id) \(year)-\(month)-\(day)")
                }
            }
        }
    }

    @Test func durationEndingInTheRepeatedHourIsExact() throws {
        // Stockholm turns 03:00 back to 02:00 on 25 October 2026: the hour from 02:00 comes twice. An hour
        // from the first 02:30 ends at the second.
        let start = EventTime.zoned(wall(2026, 10, 25, 2, 30), zone: "Europe/Stockholm")
        let end = EventMapping.adding(days: 0, seconds: 3_600, to: start, zones: [:])
        let first = try #require(start.instant(in: .gmt))
        let last = try #require(end.instant(in: .gmt))
        #expect(last.timeIntervalSince(first) == 3_600)
    }

    @Test func writtenZoneFollowsAFourthSundayRuleInOtherYears() throws {
        let zone = try #require(EventMapping.vtimezone("Test/Fourth", year: 2026, source: FourthSundayZone.source))
        let rules = try #require(EventMapping.zones(ICalComponent(name: "VCALENDAR", components: [zone]))["Test/Fourth"])
        func utcHour(_ year: Int, _ month: Int, _ day: Int) -> Int? {
            EventTime.zoned(wall(year, month, day, 12), zone: "Test/Fourth").instant(in: .gmt, zones: ["Test/Fourth": rules])
                .map { Calendar(identifier: .gregorian).dateComponents(in: .gmt, from: $0).hour ?? -1 }
        }
        // 2026: the change back is on 25 October (the fourth Sunday, and the last).
        #expect(utcHour(2026, 10, 24) == 10)
        #expect(utcHour(2026, 10, 26) == 11)
        // 2028: the fourth Sunday is 22 October, the last is the 29th.
        #expect(utcHour(2028, 10, 21) == 10)
        #expect(utcHour(2028, 10, 25) == 11)
        // 2028: daylight from 26 March (the fourth Sunday).
        #expect(utcHour(2028, 3, 25) == 11)
        #expect(utcHour(2028, 3, 27) == 10)
        // The written zone gives what the source does.
        for (year, month, day) in [(2026, 7, 1), (2030, 1, 15), (2031, 10, 27), (2029, 3, 24)] {
            let local = try #require(utcHour(year, month, day))
            let instant = try #require(
                ICalValue.wallCalendar.date(from: DateComponents(year: year, month: month, day: day, hour: local)))
            #expect(FourthSundayZone.offset(instant) / 3_600 == 12 - local)
        }
    }

    @Test func createWritesUidTimezoneAndAlarm() throws {
        let details = EventDetails(
            title: "Lunch, with Bo", place: "Café", notes: "Line one\nline two",
            start: .zoned(wall(2026, 11, 12, 12), zone: "Europe/Stockholm"),
            end: .zoned(wall(2026, 11, 12, 13), zone: "Europe/Stockholm"), reminder: 15,
            attendees: [Attendee(email: "bo@example.org", name: "Bo")])
        let made = try roundTrip(EventMapping.apply(
            .create(details, rule: RecurrenceRule(freq: .weekly, count: 3)), to: nil, uid: "",
            organizer: "jk@example.org"))
        #expect(made.first("PRODID")?.value == "-//Outwright//Outwright//EN")
        #expect(made.first("VERSION")?.value == "2.0")
        let event = try #require(events(made).first)
        let uid = try #require(event.first("UID")?.value)
        #expect(uid.hasPrefix("urn:uuid:"))
        #expect(UUID(uuidString: String(uid.dropFirst("urn:uuid:".count))) != nil)
        #expect(event.first("DTSTAMP")?.value.hasSuffix("Z") == true)
        #expect(event.first("DTSTART")?.parameter("TZID") == "Europe/Stockholm")
        #expect(event.first("ORGANIZER")?.value == "mailto:jk@example.org")
        let zone = try #require(made.components.first { $0.name == "VTIMEZONE" })
        #expect(zone.first("TZID")?.value == "Europe/Stockholm")
        #expect(Set(zone.components.map(\.name)) == ["STANDARD", "DAYLIGHT"])

        // Read back, it is the event that was made.
        let series = try #require(EventMapping.series(made).first)
        #expect(series.uid == uid)
        #expect(series.base?.title == details.title)
        #expect(series.base?.place == details.place)
        #expect(series.base?.notes == details.notes)
        #expect(series.base?.start == details.start)
        #expect(series.base?.end == details.end)
        #expect(series.base?.reminder == 15)
        #expect(series.base?.attendees.map(\.email) == ["bo@example.org"])
        #expect(series.rule == RecurrenceRule(freq: .weekly, count: 3))
        // The VTIMEZONE written gives the same instants as the system's zone.
        let rules = try #require(series.zones["Europe/Stockholm"])
        for month in [1, 4, 7, 10, 12] {
            let time = EventTime.zoned(wall(2027, month, 15, 9), zone: "Own")
            let system = EventTime.zoned(wall(2027, month, 15, 9), zone: "Europe/Stockholm")
            #expect(time.instant(in: .gmt, zones: ["Own": rules]) == system.instant(in: .gmt))
        }
    }

    @Test func createWithoutPeopleHasNoOrganizer() throws {
        let details = EventDetails(
            title: "Alone", start: .date(year: 2026, month: 11, day: 12), end: .date(year: 2026, month: 11, day: 13))
        let made = try roundTrip(EventMapping.apply(
            .create(details, rule: nil), to: nil, uid: "", organizer: "jk@example.org"))
        let event = try #require(events(made).first)
        #expect(event.first("ORGANIZER") == nil)
        #expect(event.first("DTSTART")?.parameter("VALUE") == "DATE")
        #expect(made.components.first { $0.name == "VTIMEZONE" } == nil)
        #expect(event.components.isEmpty)
    }

    @Test func occurrenceEditWritesRecurrenceIdEvent() throws {
        let held = try calendar(weekly)
        let recurrence = EventTime.zoned(wall(2026, 11, 23, 9), zone: "Europe/Stockholm")
        let base = try #require(EventMapping.series(held).first?.base)
        var moved = base
        moved.title = "Standup at noon"
        moved.start = .zoned(wall(2026, 11, 23, 12), zone: "Europe/Stockholm")
        moved.end = .zoned(wall(2026, 11, 23, 12, 30), zone: "Europe/Stockholm")
        let edited = try roundTrip(EventMapping.apply(
            .update(moved, rule: nil, scope: .occurrence(recurrence)), to: held, uid: "w@example.org",
            organizer: "jk@example.org"))
        #expect(events(edited).count == 3)
        let series = try #require(EventMapping.series(edited).first)
        #expect(series.rule == RecurrenceRule.parse("FREQ=WEEKLY;COUNT=10"))
        #expect(series.base?.title == "Standup")
        let override = try #require(series.overrides.first { $0.recurrenceID == recurrence })
        #expect(override.details.title == "Standup at noon")
        #expect(override.details.start == moved.start)
        // The override starts from the series event: its alarm comes along.
        #expect(override.details.reminder == 10)
        let written = try #require(events(edited).first { $0.first("RECURRENCE-ID")?.value == "20261123T090000" })
        #expect(written.first("RRULE") == nil)
        #expect(written.first("RECURRENCE-ID")?.parameter("TZID") == "Europe/Stockholm")

        // Edited again, the same override is replaced, not doubled.
        moved.title = "Standup again"
        let again = try roundTrip(EventMapping.apply(
            .update(moved, rule: nil, scope: .occurrence(recurrence)), to: edited, uid: "w@example.org",
            organizer: "jk@example.org"))
        #expect(events(again).count == 3)
        #expect(EventMapping.series(again).first?.overrides.first { $0.recurrenceID == recurrence }?.details.title
            == "Standup again")
    }

    @Test func occurrenceDeleteAddsExdate() throws {
        let held = try calendar(weekly)
        let moved = EventTime.zoned(wall(2026, 11, 16, 9), zone: "Europe/Stockholm")
        let other = EventTime.zoned(wall(2026, 11, 30, 9), zone: "Europe/Stockholm")
        var edited = EventMapping.apply(
            .delete(scope: .occurrence(moved)), to: held, uid: "w@example.org", organizer: "jk@example.org")
        edited = try roundTrip(EventMapping.apply(
            .delete(scope: .occurrence(other)), to: edited, uid: "w@example.org", organizer: "jk@example.org"))
        let series = try #require(EventMapping.series(edited).first)
        #expect(series.exdates == [moved, other])
        // The override of the deleted occurrence goes with it.
        #expect(series.overrides.isEmpty)
        #expect(events(edited).count == 1)
        #expect(series.base?.sequence == 4)
    }

    @Test func seriesTimeChangeRemovesOverrides() throws {
        let held = try calendar(weekly)
        let base = try #require(EventMapping.series(held).first?.base)
        var renamed = base
        renamed.title = "Daily sync"
        let titled = try roundTrip(EventMapping.apply(
            .update(renamed, rule: RecurrenceRule.parse("FREQ=WEEKLY;COUNT=10"), scope: .event), to: held,
            uid: "w@example.org", organizer: "jk@example.org"))
        // A new title keeps the moved occurrence.
        #expect(EventMapping.series(titled).first?.overrides.count == 1)
        #expect(EventMapping.series(titled).first?.base?.sequence == 3)

        var later = renamed
        later.start = .zoned(wall(2026, 11, 9, 10), zone: "Europe/Stockholm")
        later.end = .zoned(wall(2026, 11, 9, 10, 30), zone: "Europe/Stockholm")
        let moved = try roundTrip(EventMapping.apply(
            .update(later, rule: RecurrenceRule.parse("FREQ=WEEKLY;COUNT=10"), scope: .event), to: titled,
            uid: "w@example.org", organizer: "jk@example.org"))
        let series = try #require(EventMapping.series(moved).first)
        #expect(series.overrides.isEmpty)
        #expect(series.base?.start == later.start)
        #expect(events(moved).count == 1)

        let daily = try roundTrip(EventMapping.apply(
            .update(later, rule: RecurrenceRule(freq: .daily, count: 5), scope: .event), to: titled,
            uid: "w@example.org", organizer: "jk@example.org"))
        #expect(EventMapping.series(daily).first?.overrides.isEmpty == true)
        #expect(EventMapping.series(daily).first?.rule == RecurrenceRule(freq: .daily, count: 5))
    }

    @Test func editKeepsUnknownPropertiesAndAlarms() throws {
        let held = try calendar([
            "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Other//EN", "METHOD:PUBLISH",
            "BEGIN:VEVENT", "UID:k@example.org", "DTSTAMP:20261101T080000Z", "DTSTART:20261109T090000Z",
            "DTEND:20261109T100000Z", "SUMMARY:Old", "X-OTHER-APP-COLOR:teal",
            "ORGANIZER;CN=Jörgen;SCHEDULE-AGENT=SERVER:mailto:jk@example.org",
            "ATTENDEE;CN=Bo;PARTSTAT=ACCEPTED;ROLE=OPT-PARTICIPANT;SCHEDULE-STATUS=2.0:mailto:bo@example.org",
            "BEGIN:VALARM", "ACTION:DISPLAY", "TRIGGER;VALUE=DATE-TIME:20261109T070000Z", "END:VALARM",
            "BEGIN:VALARM", "ACTION:AUDIO", "TRIGGER:-PT15M", "X-ALARM-SOUND:bell", "END:VALARM",
            "END:VEVENT",
            "BEGIN:VTODO", "UID:t@example.org", "SUMMARY:A task", "END:VTODO",
            "END:VCALENDAR",
        ])
        var details = try #require(EventMapping.series(held).first?.base)
        details.title = "New"
        let edited = try roundTrip(EventMapping.apply(
            .update(details, rule: nil, scope: .event), to: held, uid: "k@example.org", organizer: "jk@example.org"))
        let event = try #require(events(edited).first)
        #expect(event.first("SUMMARY")?.text == "New")
        #expect(event.first("X-OTHER-APP-COLOR")?.value == "teal")
        #expect(event.first("DTSTAMP")?.value == "20261101T080000Z")
        #expect(event.first("DTSTART")?.value == "20261109T090000Z")
        #expect(event.first("SEQUENCE")?.value == "1")
        #expect(event.first("ORGANIZER")?.parameter("SCHEDULE-AGENT") == "SERVER")
        let attendee = try #require(event.first("ATTENDEE"))
        #expect(attendee.parameter("PARTSTAT") == "ACCEPTED")
        #expect(attendee.parameter("ROLE") == "OPT-PARTICIPANT")
        #expect(attendee.parameter("SCHEDULE-STATUS") == "2.0")
        #expect(event.components.count == 2)
        #expect(event.components.last?.first("X-ALARM-SOUND")?.value == "bell")
        #expect(edited.first("METHOD")?.value == "PUBLISH")
        #expect(edited.components.contains { $0.name == "VTODO" })

        // A new reminder changes the shown alarm only.
        details.reminder = 30
        let reminded = try roundTrip(EventMapping.apply(
            .update(details, rule: nil, scope: .event), to: edited, uid: "k@example.org", organizer: "jk@example.org"))
        let alarms = try #require(events(reminded).first?.components)
        #expect(alarms.map { $0.first("TRIGGER")?.value } == ["20261109T070000Z", "-PT30M"])
        #expect(alarms.last?.first("X-ALARM-SOUND")?.value == "bell")
    }

    @Test func peopleAddedGetOrganizerAndKeepKnownLines() throws {
        let held = try calendar([
            "BEGIN:VCALENDAR", "BEGIN:VEVENT", "UID:p@example.org", "DTSTART:20261109T090000Z",
            "DTEND:20261109T100000Z", "SUMMARY:Plan", "END:VEVENT", "END:VCALENDAR",
        ])
        var details = try #require(EventMapping.series(held).first?.base)
        details.attendees = [Attendee(email: "bo@example.org", name: "Bo")]
        let invited = try roundTrip(EventMapping.apply(
            .update(details, rule: nil, scope: .event), to: held, uid: "p@example.org", organizer: "jk@example.org"))
        let event = try #require(events(invited).first)
        #expect(event.first("ORGANIZER")?.value == "mailto:jk@example.org")
        #expect(event.first("ATTENDEE")?.value == "mailto:bo@example.org")
        #expect(event.first("ATTENDEE")?.parameter("CN") == "Bo")

        details.attendees = []
        let alone = try roundTrip(EventMapping.apply(
            .update(details, rule: nil, scope: .event), to: invited, uid: "p@example.org",
            organizer: "jk@example.org"))
        #expect(events(alone).first?.first("ORGANIZER") == nil)
        #expect(events(alone).first?.first("ATTENDEE") == nil)
    }

    /// Writing a rule back keeps every part it was read with: seconds, RFC 7529's scale and skip, and
    /// parts this app does not know, as they came.
    @Test func aRuleIsWrittenBackWithEveryPart() throws {
        for text in [
            "FREQ=MONTHLY;RSCALE=GREGORIAN;SKIP=FORWARD;INTERVAL=2;COUNT=5;BYMONTHDAY=31;BYHOUR=9;BYMINUTE=30;"
                + "BYSECOND=15,45;X-OWN=Mixed-Case;X-TWO=a,b",
            "FREQ=YEARLY;RSCALE=HEBREW;BYMONTH=5L;BYMONTHDAY=8;SKIP=BACKWARD",
            "FREQ=WEEKLY;X-FIRST=1;BYDAY=MO;X-SECOND=2;WKST=SU",
        ] {
            let rule = try #require(RecurrenceRule.parse(text))
            let written = ICalValue.recur(rule)
            #expect(Set(written.split(separator: ";")) == Set(text.split(separator: ";")), "\(written)")
            #expect(RecurrenceRule.parse(written) == rule)
        }
    }
}

/// A made-up zone at +1 that keeps +2 from the fourth Sunday of March to the fourth Sunday of October,
/// both at 01:00 UTC.
enum FourthSundayZone {
    static var source: ZoneSource { ZoneSource(offset: offset, isDaylight: { offset($0) == 7_200 }, next: next) }

    static func fourthSunday(_ year: Int, _ month: Int) -> Date {
        let calendar = ICalValue.wallCalendar
        let first = calendar.date(from: DateComponents(year: year, month: month, day: 1)) ?? .distantPast
        let weekday = calendar.component(.weekday, from: first)
        let day = 1 + (8 - weekday) % 7 + 21
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 1)) ?? .distantPast
    }

    static func changes(_ year: Int) -> [Date] {
        [fourthSunday(year, 3), fourthSunday(year, 10)]
    }

    static func offset(_ date: Date) -> Int {
        let year = ICalValue.wallCalendar.component(.year, from: date)
        let change = changes(year)
        return date >= change[0] && date < change[1] ? 7_200 : 3_600
    }

    static func next(_ date: Date) -> Date? {
        let year = ICalValue.wallCalendar.component(.year, from: date)
        return (changes(year) + changes(year + 1)).first { $0 > date }
    }
}
