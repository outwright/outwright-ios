// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Testing

@testable import OutwrightModel

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}

@Suite struct RecurrenceFuzzTests {
    static let realRules = [
        "FREQ=WEEKLY;BYDAY=MO,WE,FR;INTERVAL=2;UNTIL=20271231T235959Z",
        "FREQ=MONTHLY;BYDAY=-1FR;COUNT=12", "FREQ=YEARLY;BYMONTH=3;BYDAY=-1SU",
        "FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1", "FREQ=YEARLY;BYWEEKNO=20;BYDAY=MO;WKST=SU",
        "FREQ=DAILY;BYHOUR=9,12,17;BYMINUTE=0,30", "RRULE:FREQ=HOURLY;INTERVAL=3;BYYEARDAY=-1,100",
        "FREQ=MONTHLY;RSCALE=GREGORIAN;SKIP=FORWARD;BYMONTHDAY=31;BYSECOND=0,30",
        "FREQ=YEARLY;RSCALE=HEBREW;BYMONTH=5L;BYMONTHDAY=8;SKIP=BACKWARD;X-OWN=Value",
    ]
    static let parts = [
        "FREQ=", "YEARLY", "MONTHLY", "WEEKLY", "DAILY", "HOURLY", "MINUTELY", ";", ",", "=", "INTERVAL=", "COUNT=",
        "UNTIL=", "BYDAY=", "BYMONTHDAY=", "BYMONTH=", "BYSETPOS=", "BYYEARDAY=", "BYWEEKNO=", "BYHOUR=", "BYMINUTE=",
        "WKST=", "MO", "SU", "-1", "+2", "0", "53", "366", "99999999999", "20261231T235959Z", "T", "Z", "\u{0}", "é",
        "BYSECOND=", "60", "RSCALE=", "GREGORIAN", "HEBREW", "SKIP=", "OMIT", "BACKWARD", "FORWARD", "5L", "X-OWN=",
        "\r\n", "\"",
    ]

    @Test func ruleParserNeverTrapsOverArbitraryStrings() {
        var rng = SplitMix64(state: 0x5EED_0001)
        for round in 0..<10_000 {
            var text: String
            switch round % 4 {
            case 3:
                text = String(String.UnicodeScalarView((0..<Int.random(in: 0..<60, using: &rng)).map { _ in
                    Self.randomScalar(&rng)
                }))
            case 0:
                text = String((0..<Int.random(in: 0..<120, using: &rng)).map { _ in
                    Character(Unicode.Scalar(UInt8.random(in: 0...127, using: &rng)))
                })
            case 1:
                text = (0..<Int.random(in: 0..<16, using: &rng)).map { _ in
                    Self.parts.randomElement(using: &rng) ?? ""
                }.joined()
            default:
                var bytes = Array((Self.realRules.randomElement(using: &rng) ?? "").utf8)
                for _ in 0..<Int.random(in: 1..<6, using: &rng) where !bytes.isEmpty {
                    bytes[Int.random(in: 0..<bytes.count, using: &rng)] = UInt8.random(in: 32...126, using: &rng)
                }
                text = String(decoding: bytes, as: UTF8.self)
            }
            if let rule = RecurrenceRule.parse(text) {
                #expect(rule.interval >= 1)
                #expect((rule.count ?? 1) >= 1)
                #expect(rule.bySecond.allSatisfy { (0...60).contains($0) })
                #expect(rule.otherParts.count <= 16)
                #expect(rule.otherParts.allSatisfy { $0.utf8.count <= 256 && !$0.contains(";")
                    && !$0.unicodeScalars.contains { $0.value < 32 || $0.value == 127 } })
            }
        }
    }

    /// ASCII rule text, combining marks, characters whose uppercase is longer (ß, ŉ, ﬃ) and any scalar.
    static func randomScalar(_ rng: inout SplitMix64) -> Unicode.Scalar {
        let tricky: [Unicode.Scalar] = ["\u{DF}", "\u{149}", "\u{FB03}", "\u{1F0}", "\u{390}", "\u{301}",
                                        "\u{308}", "\u{200D}", "\u{FEFF}", "\u{130}", "=", ";", ","]
        switch Int.random(in: 0..<4, using: &rng) {
        case 0: return tricky.randomElement(using: &rng) ?? "="
        case 1: return Unicode.Scalar(UInt8.random(in: 32...126, using: &rng))
        default:
            let value = UInt32.random(in: 0...0x10_FFFF, using: &rng)
            return Unicode.Scalar(value) ?? "\u{FFFD}"
        }
    }

    static func randomRule(_ rng: inout SplitMix64) -> RecurrenceRule? {
        func pick(_ range: ClosedRange<Int>, _ rng: inout SplitMix64) -> String {
            (0..<Int.random(in: 1...3, using: &rng)).map { _ in
                var value = Int.random(in: range, using: &rng)
                if Bool.random(using: &rng), range.lowerBound > 0 { value = -value }
                return String(value)
            }.joined(separator: ",")
        }
        let freqs = ["YEARLY", "MONTHLY", "WEEKLY", "DAILY", "HOURLY"]
        var parts = ["FREQ=" + (freqs.randomElement(using: &rng) ?? "DAILY")]
        let optional: [(inout SplitMix64) -> String] = [
            { "INTERVAL=\(Int.random(in: 1...5, using: &$0))" }, { "COUNT=\(Int.random(in: 1...9_999, using: &$0))" },
            { "UNTIL=20\(Int.random(in: 20...35, using: &$0))0615T120000Z" },
            { rng in "BYDAY=" + (0..<Int.random(in: 1...3, using: &rng)).map { _ in
                let ordinal = Bool.random(using: &rng) ? "" : String(Int.random(in: -5...5, using: &rng))
                return (ordinal == "0" ? "" : ordinal) + (["MO", "TU", "WE", "TH", "FR", "SA", "SU"].randomElement(using: &rng) ?? "MO")
            }.joined(separator: ",") },
            { "BYMONTHDAY=" + pick(1...31, &$0) }, { "BYMONTH=" + pick(1...12, &$0).replacingOccurrences(of: "-", with: "") },
            { "BYSETPOS=" + pick(1...10, &$0) }, { "BYYEARDAY=" + pick(1...366, &$0) },
            { "BYWEEKNO=" + pick(1...53, &$0) },
            { "BYHOUR=" + pick(0...23, &$0) }, { "BYMINUTE=" + pick(0...59, &$0) },
            { "WKST=" + (["MO", "SU", "WE"].randomElement(using: &$0) ?? "MO") },
            { "BYSECOND=" + pick(0...60, &$0).replacingOccurrences(of: "-", with: "") },
            { "RSCALE=" + (["GREGORIAN", "GREGORIAN", "HEBREW", "CHINESE"].randomElement(using: &$0) ?? "GREGORIAN") },
            { "SKIP=" + (["OMIT", "BACKWARD", "FORWARD"].randomElement(using: &$0) ?? "OMIT") },
            { "X-OWN=" + String(Int.random(in: 0...99, using: &$0)) },
        ]
        for make in optional where Int.random(in: 0..<4, using: &rng) == 0 { parts.append(make(&rng)) }
        return RecurrenceRule.parse(parts.joined(separator: ";"))
    }

    static func randomStart(_ rng: inout SplitMix64) -> (EventTime, EventTime) {
        let wall = Cal.wall(Int.random(in: 2018...2028, using: &rng), Int.random(in: 1...12, using: &rng),
                            Int.random(in: 1...28, using: &rng), Int.random(in: 0...23, using: &rng),
                            Int.random(in: 0...59, using: &rng))
        var end = wall
        end.day = (wall.day ?? 1) + Int.random(in: 0...1, using: &rng)
        switch Int.random(in: 0..<4, using: &rng) {
        case 0: return (.floating(wall), .floating(end))
        case 1: return (.date(year: wall.year ?? 2026, month: wall.month ?? 1, day: wall.day ?? 1),
                        .date(year: end.year ?? 2026, month: end.month ?? 1, day: end.day ?? 2))
        case 2: return (.zoned(wall, zone: "Custom Central"), .zoned(end, zone: "Custom Central"))
        default: return (.zoned(wall, zone: "Pacific Standard Time"), .zoned(end, zone: "Pacific Standard Time"))
        }
    }

    @Test func expansionStaysWithinCapsForRandomRules() {
        var rng = SplitMix64(state: 0x5EED_0002)
        var expanded = 0
        while expanded < 1_000 {
            guard let rule = Self.randomRule(&rng) else { continue }
            expanded += 1
            let (start, end) = Self.randomStart(&rng)
            let series = EventSeries(uid: "fuzz@example.org", base: Cal.details(start, end), rule: rule,
                                     zones: ["Custom Central": ZoneResolverTests.custom])
            let from = Cal.instant(Int.random(in: 2018...2030, using: &rng), Int.random(in: 1...12, using: &rng), 1)
            let to = from.addingTimeInterval(TimeInterval(Int.random(in: 1...800, using: &rng)) * 86_400)
            let found = Recurrence.occurrences(series, from: from, to: to, phoneZone: Cal.stockholm)
            #expect(found.count <= 5_000)
            #expect(zip(found, found.dropFirst()).allSatisfy { $0.start <= $1.start })
            #expect(found.allSatisfy { $0.start < to && ($0.end > from || $0.start >= from) }, "\(rule)")
        }
    }

    /// A time `days` and `minutes` from `time`, of the same kind.
    static func moved(_ time: EventTime, days: Int, minutes: Int) -> EventTime {
        func shift(_ wall: DateComponents) -> DateComponents {
            var wall = wall
            wall.day = (wall.day ?? 1) + days
            wall.minute = (wall.minute ?? 0) + minutes
            return wall
        }
        switch time {
        case let .date(year, month, day):
            let wall = shift(Cal.wall(year, month, day))
            return .date(year: wall.year ?? year, month: wall.month ?? month, day: wall.day ?? day)
        case let .floating(wall): return .floating(shift(wall))
        case let .zoned(wall, zone): return .zoned(shift(wall), zone: zone)
        case let .utc(date): return .utc(date.addingTimeInterval(TimeInterval(days * 86_400 + minutes * 60)))
        }
    }

    @Test func expansionWithRandomRangedOverridesStaysWithinCaps() {
        var rng = SplitMix64(state: 0x5EED_0003)
        var expanded = 0
        while expanded < 1_000 {
            guard let rule = Self.randomRule(&rng) else { continue }
            expanded += 1
            let (start, end) = Self.randomStart(&rng)
            var overrides: [EventOverride] = []
            for _ in 0..<Int.random(in: 0...4, using: &rng) {
                let id = Self.moved(start, days: Int.random(in: -30...400, using: &rng), minutes: 0)
                let (from, to) = Bool.random(using: &rng)
                    ? Self.randomStart(&rng)
                    : (Self.moved(id, days: Int.random(in: -20_000...20_000, using: &rng),
                                  minutes: Int.random(in: -600...600, using: &rng)),
                       Self.moved(id, days: Int.random(in: -5...5, using: &rng), minutes: 0))
                var details = Cal.details(from, to, title: "Moved")
                details.status = Int.random(in: 0..<5, using: &rng) == 0 ? .cancelled : .confirmed
                details.sequence = Int.random(in: 0...2, using: &rng)
                overrides.append(EventOverride(recurrenceID: id, details: details,
                                               thisAndFuture: Bool.random(using: &rng)))
            }
            let exdates = (0..<Int.random(in: 0...3, using: &rng)).map { _ in
                Self.moved(start, days: Int.random(in: 0...200, using: &rng), minutes: 0)
            }
            let series = EventSeries(uid: "fuzz@example.org", base: Cal.details(start, end), rule: rule,
                                     exdates: exdates, overrides: overrides,
                                     zones: ["Custom Central": ZoneResolverTests.custom])
            let from = Cal.instant(Int.random(in: 2018...2030, using: &rng), Int.random(in: 1...12, using: &rng), 1)
            let to = from.addingTimeInterval(TimeInterval(Int.random(in: 1...800, using: &rng)) * 86_400)
            let found = Recurrence.occurrences(series, from: from, to: to, phoneZone: Cal.stockholm)
            #expect(found.count <= 5_000)
            #expect(zip(found, found.dropFirst()).allSatisfy { $0.start <= $1.start })
            #expect(found.allSatisfy { $0.start < to && ($0.end > from || $0.start >= from) }, "\(rule)")
            for override in overrides {
                _ = Recurrence.range(holding: override.recurrenceID, in: series, phoneZone: Cal.stockholm)
                if let carried = Recurrence.rangeAfter(override.recurrenceID, in: series, phoneZone: Cal.stockholm) {
                    #expect(carried.thisAndFuture)
                }
            }
        }
    }
}
