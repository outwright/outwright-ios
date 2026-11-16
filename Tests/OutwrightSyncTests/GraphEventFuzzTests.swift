// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightModel
import Testing

@testable import OutwrightSync

private struct Seeded: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}

/// Values of every JSON kind, including the wrong ones for each property.
private func junk(_ rng: inout Seeded, depth: Int = 0) -> Any {
    switch Int.random(in: 0...9, using: &rng) {
    case 0: return NSNull()
    case 1: return Bool.random(using: &rng)
    case 2: return Int.random(in: -1_000_000_000...1_000_000_000, using: &rng)
    case 3: return Double.random(in: -1e300...1e300, using: &rng)
    case 4: return ["2026-03-02T08:00:00.0000000", "9999-99-99T99:99:99", "", "last", "weekly", "monday",
                    "OID.x.2026-02-30", "W. Europe Standard Time", "tzone://Microsoft/Custom"].randomElement(using: &rng) ?? ""
    case 5: return String(repeating: "å", count: Int.random(in: 0...70_000, using: &rng))
    case 6 where depth < 3: return (0..<Int.random(in: 0...4, using: &rng)).map { _ in junk(&rng, depth: depth + 1) }
    case 7 where depth < 3:
        let keys = ["dateTime", "timeZone", "pattern", "range", "type", "interval", "daysOfWeek", "index", "month",
                    "dayOfMonth", "numberOfOccurrences", "endDate", "emailAddress", "address", "status", "response"]
        var object: [String: Any] = [:]
        for _ in 0..<Int.random(in: 0...5, using: &rng) {
            object[keys.randomElement(using: &rng) ?? "type"] = junk(&rng, depth: depth + 1)
        }
        return object
    default: return "x"
    }
}

@Suite struct GraphEventFuzzTests {
    private func check(_ data: Data) {
        guard let series = GraphEventMapping.series(data) else { return }
        _ = Recurrence.occurrences(
            series, from: Date(timeIntervalSince1970: 1_767_225_600), to: Date(timeIntervalSince1970: 1_830_297_600),
            phoneZone: TimeZone(identifier: "Europe/Stockholm") ?? .current)
        if let base = series.base {
            #expect(base.title.count <= GraphEventMapping.maxText && base.notes.count <= GraphEventMapping.maxText)
            #expect(base.attendees.count <= GraphEventMapping.maxAttendees)
            _ = GraphEventMapping.body(base, rule: series.rule, over: nil, phoneZone: .current)
        }
    }

    @Test func readerNeverTrapsOverArbitraryBytes() {
        var rng = Seeded(state: 7)
        for _ in 0..<5_000 {
            let count = Int.random(in: 0...2048, using: &rng)
            check(Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &rng) }))
        }
    }

    @Test func readerNeverTrapsOverMutatedEvents() {
        var rng = Seeded(state: 11)
        let keys = ["id", "subject", "body", "start", "end", "isAllDay", "location", "isReminderOn",
                    "reminderMinutesBeforeStart", "organizer", "attendees", "isCancelled", "showAs", "originalStartTimeZone",
                    "recurrence", "exceptionOccurrences", "cancelledOccurrences", "iCalUId", "isOrganizer"]
        for _ in 0..<3_000 {
            var event: [String: Any] = [
                "id": "e", "start": ["dateTime": "2026-03-02T08:00:00", "timeZone": "UTC"],
                "end": ["dateTime": "2026-03-02T09:00:00", "timeZone": "UTC"],
                "recurrence": ["pattern": ["type": "weekly", "interval": 1, "daysOfWeek": ["monday"]],
                               "range": ["type": "noEnd", "startDate": "2026-03-02"]],
            ]
            for _ in 0..<Int.random(in: 1...4, using: &rng) {
                event[keys.randomElement(using: &rng) ?? "id"] = junk(&rng)
            }
            check((try? JSONSerialization.data(withJSONObject: event)) ?? Data())
        }
    }

    /// Any hex after the GlobalObjectId's class id (lengths that lie, a marker cut short) and any
    /// other text: an answer, never a trap.
    @Test func anyICalUIdReadsWithoutATrap() {
        var rng = Seeded(state: 0x60_1D)
        let classID = "040000008200E00074C5B7101A82E008"
        let hexDigits = Array("0123456789ABCDEFabcdefxZ")
        let marker = Array("vCal-Uid".utf8).map { String(format: "%02X", $0) }.joined() + "01000000"
        for _ in 0..<3_000 {
            let tail = String((0..<Int.random(in: 0...120, using: &rng)).map { _ in
                hexDigits.randomElement(using: &rng) ?? "0"
            })
            let withMarker = Bool.random(using: &rng) ? String(tail.prefix(48)) + marker + tail : tail
            let text = Bool.random(using: &rng) ? classID + withMarker : withMarker
            #expect(GraphGlobalObjectID.uid(text).utf8.count <= max(text.utf8.count, 8_192))
        }
    }
}

