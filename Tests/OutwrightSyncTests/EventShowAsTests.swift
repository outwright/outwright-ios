// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightDAV
import OutwrightModel
import Testing

@testable import OutwrightSync

/// Show as and Private: written to iCalendar and Graph, and read back.
@Suite struct EventShowAsTests {
    private func wall(_ day: Int, _ hour: Int) -> DateComponents {
        DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: 0, second: 0)
    }

    private func details(showAs: ShowAs = .busy, isPrivate: Bool = false) -> EventDetails {
        EventDetails(
            title: "Planning", start: .zoned(wall(12, 9), zone: "Europe/Stockholm"),
            end: .zoned(wall(12, 10), zone: "Europe/Stockholm"), showAs: showAs, isPrivate: isPrivate)
    }

    private func written(_ edit: EventEdit, over held: ICalComponent? = nil) throws -> ICalComponent {
        let calendar = EventMapping.apply(edit, to: held, uid: "show@example.org", organizer: "jk@example.org")
        return try ICalendarReader.calendar(ICalendarWriter.write(calendar))
    }

    private func event(_ calendar: ICalComponent) throws -> ICalComponent {
        try #require(calendar.components.first { $0.name == "VEVENT" })
    }

    @Test func showAsRoundTripsThroughICalendar() throws {
        for showAs in ShowAs.allCases {
            let made = try written(.create(details(showAs: showAs), rule: nil))
            #expect(EventMapping.series(made).first?.base?.showAs == showAs, "\(showAs)")
            // Readers that know only TRANSP still see whether the time is taken.
            let transp = try event(made).first("TRANSP")?.value
            #expect(transp == (showAs == .free ? "TRANSPARENT" : "OPAQUE"), "\(showAs)")
        }
        // Changed from tentative to free, both properties follow.
        let tentative = try written(.create(details(showAs: .tentative), rule: nil))
        let free = try written(.update(details(showAs: .free), rule: nil, scope: .event), over: tentative)
        #expect(EventMapping.series(free).first?.base?.showAs == .free)
    }

    @Test func showAsIsReadFromTRANSPAloneAndKeepsOtherProperties() throws {
        let lines = [
            "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Example//EN",
            "BEGIN:VEVENT", "UID:show@example.org", "DTSTAMP:20261101T080000Z",
            "DTSTART:20261112T080000Z", "DTEND:20261112T090000Z", "SUMMARY:Lunch", "TRANSP:TRANSPARENT",
            "X-EXAMPLE-KEPT:yes", "END:VEVENT", "END:VCALENDAR"
        ]
        let held = try ICalendarReader.calendar(Data(icsText(lines).utf8))
        let base = try #require(EventMapping.series(held).first?.base)
        #expect(base.showAs == .free)
        var renamed = base
        renamed.title = "Long lunch"
        let edited = try written(.update(renamed, rule: nil, scope: .event), over: held)
        #expect(try event(edited).first("X-EXAMPLE-KEPT")?.value == "yes")
        #expect(EventMapping.series(edited).first?.base?.showAs == .free)
    }

    @Test func privateRoundTrips() throws {
        let made = try written(.create(details(isPrivate: true), rule: nil))
        #expect(try event(made).first("CLASS")?.value == "PRIVATE")
        let base = try #require(EventMapping.series(made).first?.base)
        #expect(base.isPrivate)
        var open = base
        open.isPrivate = false
        let opened = try written(.update(open, rule: nil, scope: .event), over: made)
        #expect(EventMapping.series(opened).first?.base?.isPrivate == false)
        let plain = try written(.create(details(), rule: nil))
        #expect(EventMapping.series(plain).first?.base?.isPrivate == false)
    }

    @Test func showAsIsWrittenToGraph() throws {
        let expected: [ShowAs: String] = [.busy: "busy", .free: "free", .tentative: "tentative", .away: "oof"]
        for (showAs, graph) in expected {
            let body = GraphEventMapping.body(details(showAs: showAs), rule: nil, over: nil, phoneZone: .gmt)
            #expect(body["showAs"] as? String == graph)
            let json = try JSONSerialization.data(withJSONObject: [
                "id": "e1", "type": "singleInstance", "subject": "Planning", "showAs": graph,
                "start": ["dateTime": "2026-11-12T08:00:00.0000000", "timeZone": "UTC"],
                "end": ["dateTime": "2026-11-12T09:00:00.0000000", "timeZone": "UTC"]
            ])
            #expect(GraphEventMapping.series(json)?.base?.showAs == showAs)
        }
        // Unchanged, it is not sent again.
        let held = details(showAs: .away)
        var renamed = held
        renamed.title = "Planning, again"
        let body = GraphEventMapping.body(renamed, rule: nil, over: (held, nil), phoneZone: .gmt)
        #expect(body["showAs"] == nil)
    }

    @Test func privateIsWrittenToGraph() throws {
        let body = GraphEventMapping.body(details(isPrivate: true), rule: nil, over: nil, phoneZone: .gmt)
        #expect(body["sensitivity"] as? String == "private")
        let json = try JSONSerialization.data(withJSONObject: [
            "id": "e1", "type": "singleInstance", "subject": "Planning", "sensitivity": "private",
            "start": ["dateTime": "2026-11-12T08:00:00.0000000", "timeZone": "UTC"],
            "end": ["dateTime": "2026-11-12T09:00:00.0000000", "timeZone": "UTC"]
        ])
        #expect(GraphEventMapping.series(json)?.base?.isPrivate == true)
    }
}
