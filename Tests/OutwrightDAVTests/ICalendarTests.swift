// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Testing

@testable import OutwrightDAV

@Suite struct ICalendarTests {
    func ics(_ lines: [String], eol: String = "\r\n") -> Data {
        Data((lines.joined(separator: eol) + eol).utf8)
    }

    @Test func readsEventWithAlarmAndTimezone() throws {
        let data = ics([
            "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Example//EN",
            "BEGIN:VTIMEZONE", "TZID:Europe/Stockholm",
            "BEGIN:STANDARD", "DTSTART:19701025T030000", "TZOFFSETFROM:+0200", "TZOFFSETTO:+0100", "END:STANDARD",
            "BEGIN:DAYLIGHT", "DTSTART:19700329T020000", "TZOFFSETFROM:+0100", "TZOFFSETTO:+0200", "END:DAYLIGHT",
            "END:VTIMEZONE",
            "BEGIN:VEVENT", "UID:a1@example.org", "DTSTART;TZID=Europe/Stockholm:20261109T090000",
            "SUMMARY:Möte\\, med Bo",
            "BEGIN:VALARM", "ACTION:DISPLAY", "TRIGGER:-PT15M", "END:VALARM",
            "END:VEVENT", "END:VCALENDAR",
        ])
        let calendar = try ICalendarReader.calendar(data)
        #expect(calendar.name == "VCALENDAR")
        let events = calendar.components.filter { $0.name == "VEVENT" }
        #expect(events.count == 1)
        let event = try #require(events.first)
        #expect(event.first("SUMMARY")?.text == "Möte, med Bo")
        #expect(event.first("DTSTART")?.parameter("TZID") == "Europe/Stockholm")
        #expect(event.components.filter { $0.name == "VALARM" }.count == 1)
        let zone = try #require(calendar.components.first { $0.name == "VTIMEZONE" })
        #expect(zone.components.map(\.name) == ["STANDARD", "DAYLIGHT"])
    }

    @Test func readsSeriesWithOverrides() throws {
        let data = ics([
            "BEGIN:VCALENDAR", "VERSION:2.0",
            "BEGIN:VEVENT", "UID:s@example.org", "DTSTART:20261109T090000Z", "RRULE:FREQ=WEEKLY", "END:VEVENT",
            "BEGIN:VEVENT", "UID:s@example.org", "RECURRENCE-ID:20261116T090000Z", "DTSTART:20261116T100000Z",
            "END:VEVENT",
            "BEGIN:VEVENT", "UID:s@example.org", "RECURRENCE-ID:20261123T090000Z", "DTSTART:20261123T110000Z",
            "END:VEVENT",
            "END:VCALENDAR",
        ])
        let calendar = try ICalendarReader.calendar(data)
        let events = calendar.components.filter { $0.name == "VEVENT" }
        #expect(events.count == 3)
        #expect(events.map { $0.first("UID")?.value } == Array(repeating: "s@example.org", count: 3))
        #expect(events[0].first("RECURRENCE-ID") == nil)
        #expect(events[2].first("RECURRENCE-ID")?.value == "20261123T090000Z")
    }

    @Test func quotedParameterWithColonIsOneValue() throws {
        let data = ics([
            "BEGIN:VCALENDAR", "BEGIN:VEVENT",
            "ATTENDEE;CN=\"Lind: Bo\";PARTSTAT=ACCEPTED:mailto:bo@example.org",
            "END:VEVENT", "END:VCALENDAR",
        ])
        let event = try #require(ICalendarReader.calendar(data).components.first)
        let attendee = try #require(event.first("ATTENDEE"))
        #expect(attendee.parameter("CN") == "Lind: Bo")
        #expect(attendee.parameter("PARTSTAT") == "ACCEPTED")
        #expect(attendee.value == "mailto:bo@example.org")
    }

    @Test func unfoldsAndAcceptsBareLF() throws {
        let data = Data("BEGIN:VCALENDAR\nBEGIN:VEVENT\nSUMMARY:Hello\n  wor\n\tld\nEND:VEVENT\nEND:VCALENDAR\n".utf8)
        let event = try #require(ICalendarReader.calendar(data).components.first)
        #expect(event.first("SUMMARY")?.text == "Hello world")
    }

    @Test func editKeepsEverythingElse() throws {
        let data = ics([
            "BEGIN:VCALENDAR", "VERSION:2.0",
            "BEGIN:VEVENT", "UID:e@example.org", "SUMMARY:Old", "X-MS-OLK-APPTSEQTIME:20261101T080000Z",
            "ATTACH;FMTTYPE=text/plain:https://example.org/a.txt", "CATEGORIES:Work,Home",
            "BEGIN:VALARM", "TRIGGER:-PT15M", "ACTION:DISPLAY", "END:VALARM",
            "BEGIN:VALARM", "TRIGGER:-P1D", "ACTION:AUDIO", "END:VALARM",
            "DESCRIPTION:Last", "END:VEVENT", "END:VCALENDAR",
        ])
        let calendar = try ICalendarReader.calendar(data)
        let event = try #require(calendar.components.first)
        let edited = event.replacing("SUMMARY", with: [ICalProperty(name: "SUMMARY", value: "New")])
        #expect(edited.properties.map(\.name) == event.properties.map(\.name))
        var changed = calendar
        changed.components = [edited]
        let back = try ICalendarReader.calendar(ICalendarWriter.write(changed))
        let result = try #require(back.components.first)
        #expect(result.first("SUMMARY")?.text == "New")
        #expect(result.properties.filter { $0.name != "SUMMARY" } == event.properties.filter { $0.name != "SUMMARY" })
        #expect(result.components == event.components)
        #expect(back.properties == calendar.properties)
    }

    @Test func replacingKeepsPositionOfFirstAndDropsOthers() {
        let event = ICalComponent(
            name: "VEVENT",
            properties: [
                ICalProperty(name: "A", value: "1"), ICalProperty(name: "X", value: "a"),
                ICalProperty(name: "B", value: "2"), ICalProperty(name: "X", value: "b"),
            ], components: [])
        let out = event.replacing("X", with: [ICalProperty(name: "X", value: "z")])
        #expect(out.properties.map(\.value) == ["1", "z", "2"])
        let added = event.replacing("Y", with: [ICalProperty(name: "Y", value: "y")])
        #expect(added.properties.last?.name == "Y")
        #expect(event.replacing("X", with: []).properties.map(\.name) == ["A", "B"])
    }

    @Test func writeFoldsAt75OctetsWithCRLF() throws {
        let long = String(repeating: "ö", count: 100)
        let event = ICalComponent(
            name: "VEVENT", properties: [ICalProperty(name: "SUMMARY", value: long)], components: [])
        let calendar = ICalComponent(name: "VCALENDAR", properties: [], components: [event])
        let data = ICalendarWriter.write(calendar)
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false).dropLast()
        #expect(lines.allSatisfy { $0.last == 0x0D })
        #expect(lines.allSatisfy { $0.count - 1 <= 75 })
        #expect(lines.count > 4)
        let back = try ICalendarReader.calendar(data)
        #expect(back.components.first?.first("SUMMARY")?.value == long)
    }

    @Test func unbalancedBeginEndIsMalformed() {
        let cases: [[String]] = [
            ["BEGIN:VCALENDAR", "BEGIN:VEVENT", "END:VCALENDAR"],
            ["BEGIN:VCALENDAR", "BEGIN:VEVENT", "END:VEVENT"],
            ["BEGIN:VCALENDAR", "END:VCALENDAR", "END:VCALENDAR"],
            ["BEGIN:VEVENT", "END:VEVENT"],
            ["SUMMARY:x"],
            [],
        ]
        for lines in cases {
            #expect(throws: ICalError.malformed) { try ICalendarReader.calendar(ics(lines)) }
        }
    }

    @Test func componentFloodIsTooLarge() {
        let events = Array(repeating: ["BEGIN:VEVENT", "END:VEVENT"], count: 1_001).flatMap { $0 }
        let data = ics(["BEGIN:VCALENDAR"] + events + ["END:VCALENDAR"])
        #expect(throws: ICalError.tooLarge) { try ICalendarReader.calendar(data) }
    }

    @Test func deepNestingIsTooLarge() {
        let data = ics(Array(repeating: "BEGIN:VCALENDAR", count: 20))
        #expect(throws: ICalError.tooLarge) { try ICalendarReader.calendar(data) }
    }

    @Test func oversizedResourceIsTooLarge() {
        let data = Data(count: DAVLimits.iCalendarBytes + 1)
        #expect(throws: ICalError.tooLarge) { try ICalendarReader.calendar(data) }
    }

    @Test func alarmFloodIsTooLarge() {
        let alarms = Array(repeating: ["BEGIN:VALARM", "END:VALARM"], count: 11).flatMap { $0 }
        let data = ics(["BEGIN:VCALENDAR", "BEGIN:VEVENT"] + alarms + ["END:VEVENT", "END:VCALENDAR"])
        #expect(throws: ICalError.tooLarge) { try ICalendarReader.calendar(data) }
    }

    @Test func latin1ValueFallsBack() throws {
        var bytes = Array("BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nSUMMARY:M".utf8)
        bytes.append(0xF6)
        bytes.append(contentsOf: Array("te\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n".utf8))
        let event = try #require(ICalendarReader.calendar(Data(bytes)).components.first)
        #expect(event.first("SUMMARY")?.text == "Möte")
    }

    @Test func largeInlineAttachmentSurvives() throws {
        let blob = String(repeating: "QUJD", count: 256 * 1024)
        let data = ics([
            "BEGIN:VCALENDAR", "BEGIN:VEVENT", "UID:big@example.org",
            "ATTACH;VALUE=BINARY;ENCODING=BASE64:" + blob, "END:VEVENT", "END:VCALENDAR",
        ])
        #expect(data.count < DAVLimits.iCalendarBytes)
        let calendar = try ICalendarReader.calendar(data)
        let attach = try #require(calendar.components.first?.first("ATTACH"))
        #expect(attach.value == blob)
        let back = try ICalendarReader.calendar(ICalendarWriter.write(calendar))
        #expect(back == calendar)
    }

    @Test func textInitEscapesAndRoundTrips() throws {
        let text = "a, b; c \\ d\ne"
        let event = ICalComponent(
            name: "VEVENT", properties: [ICalProperty(name: "SUMMARY", text: text)], components: [])
        let calendar = ICalComponent(name: "VCALENDAR", components: [event])
        let back = try ICalendarReader.calendar(ICalendarWriter.write(calendar))
        #expect(back.components.first?.first("SUMMARY")?.text == text)
    }

    @Test func groupSurvivesRoundTrip() throws {
        let data = ics(["BEGIN:VCALENDAR", "BEGIN:VEVENT", "item1.X-FOO:x", "END:VEVENT", "END:VCALENDAR"])
        let calendar = try ICalendarReader.calendar(data)
        #expect(calendar.components.first?.first("X-FOO")?.group == "item1")
        #expect(try ICalendarReader.calendar(ICalendarWriter.write(calendar)) == calendar)
    }

    @Test func bareParameterIsNotATypeInCalendars() throws {
        let data = ics(["BEGIN:VCALENDAR", "BEGIN:VEVENT", "DTSTART;FOO:20261109", "END:VEVENT", "END:VCALENDAR"])
        let calendar = try ICalendarReader.calendar(data)
        let property = try #require(calendar.components.first?.first("DTSTART"))
        #expect(property.parameters == [ContentParameter(name: "FOO", values: [])])
        let written = String(decoding: ICalendarWriter.write(calendar), as: UTF8.self)
        #expect(written.contains("DTSTART;FOO:20261109\r\n"))
        #expect(try ICalendarReader.calendar(ICalendarWriter.write(calendar)) == calendar)
    }

    @Test func loneCRInValueIsStrippedConsistently() throws {
        let data = Data("BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nX-A:one\rtwo\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n".utf8)
        let calendar = try ICalendarReader.calendar(data)
        let written = ICalendarWriter.write(calendar)
        #expect(!String(decoding: written, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "").contains("\r"))
        let once = try ICalendarReader.calendar(written)
        #expect(once.components.first?.first("X-A")?.value == "onetwo")
        #expect(ICalendarWriter.write(once) == written)
    }

    // MARK: - Boundaries

    func nested(_ levels: Int) -> Data {
        let open = (0..<levels).map { _ in "BEGIN:X-N" }
        return ics(["BEGIN:VCALENDAR"] + open + open.map { _ in "END:X-N" } + ["END:VCALENDAR"])
    }

    @Test func componentCapBoundary() throws {
        func resource(_ events: Int) -> Data {
            ics(["BEGIN:VCALENDAR"] + Array(repeating: ["BEGIN:VEVENT", "END:VEVENT"], count: events).flatMap { $0 }
                + ["END:VCALENDAR"])
        }
        #expect(try ICalendarReader.calendar(resource(999)).components.count == 999)
        #expect(throws: ICalError.tooLarge) { try ICalendarReader.calendar(resource(1_000)) }
    }

    @Test func alarmCapBoundary() throws {
        func resource(_ alarms: Int) -> Data {
            ics(["BEGIN:VCALENDAR", "BEGIN:VEVENT"] + Array(repeating: ["BEGIN:VALARM", "END:VALARM"], count: alarms)
                .flatMap { $0 } + ["END:VEVENT", "END:VCALENDAR"])
        }
        #expect(try ICalendarReader.calendar(resource(10)).components.first?.components.count == 10)
        #expect(throws: ICalError.tooLarge) { try ICalendarReader.calendar(resource(11)) }
    }

    @Test func propertyCapBoundary() throws {
        func resource(_ count: Int) -> Data {
            ics(["BEGIN:VCALENDAR", "BEGIN:VEVENT"] + (0..<count).map { "X-P\($0):v" } + ["END:VEVENT", "END:VCALENDAR"])
        }
        #expect(try ICalendarReader.calendar(resource(2_000)).components.first?.properties.count == 2_000)
        #expect(throws: ICalError.tooLarge) { try ICalendarReader.calendar(resource(2_001)) }
    }

    @Test func depthCapBoundary() throws {
        _ = try ICalendarReader.calendar(nested(DAVLimits.componentDepth - 1))
        #expect(throws: ICalError.tooLarge) { try ICalendarReader.calendar(nested(DAVLimits.componentDepth)) }
    }
}
