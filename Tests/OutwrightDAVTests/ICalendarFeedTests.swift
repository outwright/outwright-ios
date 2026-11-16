// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightFakes
import Testing

@testable import OutwrightDAV

@Suite struct ICalendarFeedTests {
    func object(_ split: FeedSplit, _ href: String) throws -> ICalComponent {
        let found = try #require(split.objects.first { $0.href == href })
        return try ICalendarReader.calendar(found.data)
    }

    @Test func splitGroupsByUID() throws {
        let split = try ICalendarFeed.split(SyntheticFeed.work)
        #expect(split.objects.map(\.href) == ["uid:d1", "uid:e1", "uid:s1"])
        let series = try object(split, "uid:s1")
        #expect(series.components.filter { $0.name == "VEVENT" }.count == 2)
        #expect(series.components.filter { $0.name == "VTIMEZONE" }.count == 1)
    }

    @Test func splitDropsAlarms() throws {
        let split = try ICalendarFeed.split(SyntheticFeed.work)
        for item in split.objects {
            #expect(!String(decoding: item.data, as: UTF8.self).contains("BEGIN:VALARM"))
        }
    }

    @Test func splitNamesOnlyUsedZones() throws {
        let split = try ICalendarFeed.split(SyntheticFeed.work)
        #expect(try object(split, "uid:d1").components.allSatisfy { $0.name != "VTIMEZONE" })
        #expect(try object(split, "uid:e1").components.contains { $0.name == "VTIMEZONE" })
    }

    @Test func splitRefusesEventWithoutUID() throws {
        let split = try ICalendarFeed.split(SyntheticFeed.work)
        #expect(split.refused.count == 1)
        #expect(!split.objects.contains { $0.href.contains("t1") })
        #expect(!split.refused.contains { $0.href.contains("t1") })
    }

    @Test func splitReadsName() throws {
        #expect(try ICalendarFeed.split(SyntheticFeed.work).name == "Work")
    }

    @Test func etagIsStable() throws {
        let first = try ICalendarFeed.split(SyntheticFeed.work)
        let again = try ICalendarFeed.split(SyntheticFeed.work)
        #expect(first.objects == again.objects)
        let renamed = SyntheticFeed.review.replacingOccurrences(of: "SUMMARY:Review", with: "SUMMARY:Review 2")
        let changed = try ICalendarFeed.split(
            SyntheticFeed.feed([
                SyntheticFeed.standup, SyntheticFeed.standupMoved, renamed, SyntheticFeed.conference,
            ]))
        let etags = Dictionary(uniqueKeysWithValues: first.objects.map { ($0.href, $0.etag) })
        for item in changed.objects {
            #expect((etags[item.href] == item.etag) == (item.href != "uid:e1"))
        }
    }

    @Test func splitCapsObjects() {
        #expect(throws: ICalError.tooLarge) { try ICalendarFeed.split(SyntheticFeed.many(DAVLimits.feedObjects + 1)) }
    }

    @Test func feedReadsPastResourceCap() throws {
        #expect(try ICalendarFeed.split(SyntheticFeed.many(1_500)).objects.count == 1_500)
    }

    /// A feed whose one zone is padded to `padding` bytes, with `count` events naming it.
    func padded(zone padding: Int, events count: Int) -> Data {
        let zone = [
            "BEGIN:VTIMEZONE", "TZID:Z", "X-PAD:" + String(repeating: "a", count: padding), "BEGIN:STANDARD",
            "DTSTART:16010101T030000", "TZOFFSETFROM:+0100", "TZOFFSETTO:+0100", "END:STANDARD", "END:VTIMEZONE"
        ].joined(separator: "\r\n")
        let events = (0..<count).map { index in
            SyntheticFeed.event(["UID:p\(index)", "DTSTART;TZID=Z:20261110T100000", "SUMMARY:p\(index)"])
        }
        return SyntheticFeed.feed([zone] + events)
    }

    @Test func oversizedZoneIsLeftOut() throws {
        let split = try ICalendarFeed.split(padded(zone: DAVLimits.feedZoneBytes, events: 3))
        #expect(split.objects.count == 3)
        for item in split.objects {
            #expect(!String(decoding: item.data, as: UTF8.self).contains("X-PAD"))
        }
    }

    @Test func splitCapsTotalOutput() {
        // Each object carries a copy of the zone: past the cap on what one file may write.
        let count = DAVLimits.feedOutputBytes / (DAVLimits.feedZoneBytes / 2) + 1
        #expect(throws: ICalError.tooLarge) {
            try ICalendarFeed.split(padded(zone: DAVLimits.feedZoneBytes / 2, events: count))
        }
    }

    @Test func eventsWithoutUIDCountTowardTheCap() {
        let events = (0...DAVLimits.feedObjects).map { index in
            SyntheticFeed.event(["DTSTART:20261110T100000Z", "SUMMARY:x\(index)"])
        }
        #expect(throws: ICalError.tooLarge) { try ICalendarFeed.split(SyntheticFeed.feed(events)) }
    }

    @Test func nameIsClamped() throws {
        let long = String(repeating: "N", count: 1_000)
        let split = try ICalendarFeed.split(SyntheticFeed.feed([SyntheticFeed.review], name: long))
        #expect(split.name?.count == ICalendarFeed.nameLength)
    }
}
