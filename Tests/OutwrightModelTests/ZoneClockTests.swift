// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Testing

@testable import OutwrightModel

/// A zone given only by its VTIMEZONE converts instants to wall times as the system's zone does.
@Suite struct ZoneClockTests {
    /// Europe/Stockholm's rules under a made-up TZID.
    static let zone = "Made-up North"
    static let rules = ZoneResolverTests.custom

    static let own = ZoneClock.rules(RulesTable(rules, years: 2025...2027))
    static let system = ZoneClock.system(Cal.stockholm)

    /// Instants around an onset: every five minutes for three hours either side, and a second either side of it.
    static func around(_ onset: Date) -> [Date] {
        let steps = stride(from: -3 * 3_600, through: 3 * 3_600, by: 300).map { onset.addingTimeInterval(TimeInterval($0)) }
        return steps + [-1, 0, 1].map { onset.addingTimeInterval(TimeInterval($0)) }
    }

    @Test func wallTimesAfterASpringForwardMatchTheSystemZone() {
        // 29 March 2026: 02:00 CET (01:00 UTC) becomes 03:00 CEST.
        let onset = Cal.instant(2026, 3, 29, 1, in: .gmt)
        for instant in Self.around(onset) {
            #expect(Self.own.wall(at: instant) == Self.system.wall(at: instant), "\(instant)")
        }
    }

    @Test func wallTimesInTheRepeatedHourMatchTheSystemZone() {
        // 25 October 2026: 03:00 CEST (01:00 UTC) becomes 02:00 CET, so 02:00 to 03:00 comes twice.
        let onset = Cal.instant(2026, 10, 25, 1, in: .gmt)
        for instant in Self.around(onset) {
            #expect(Self.own.wall(at: instant) == Self.system.wall(at: instant), "\(instant)")
        }
    }

    @Test func wallTimesRoundTripOutsideTheGapAndTheRepeatedHour() {
        for onset in [Cal.instant(2026, 3, 29, 1, in: .gmt), Cal.instant(2026, 10, 25, 1, in: .gmt)] {
            for instant in Self.around(onset) {
                guard let wall = Self.own.wall(at: instant) else {
                    Issue.record("no wall time at \(instant)")
                    continue
                }
                // The first of a repeated hour's two instants is the one a wall time names.
                let back = Self.own.instant(of: wall)
                #expect(back == instant || back == instant.addingTimeInterval(-3_600), "\(instant)")
            }
        }
    }

    /// A daily series at 03:15 whose UTC UNTIL is the 03:15 just after the spring-forward onset.
    @Test func untilJustAfterASpringForwardCountsAsInTheSystemZone() {
        func count(_ zone: String) -> Int {
            var start = Cal.wall(2026, 3, 25, 3)
            start.minute = 15
            var end = start
            end.hour = 4
            let series = Cal.series(Cal.details(.zoned(start, zone: zone), .zoned(end, zone: zone)),
                                    rule: "FREQ=DAILY;UNTIL=20260329T011500Z", zones: [Self.zone: Self.rules])
            return Recurrence.occurrences(series, from: Cal.instant(2026, 3, 1), to: Cal.instant(2026, 5, 1),
                                          phoneZone: Cal.stockholm).count
        }
        #expect(count("Europe/Stockholm") == 5)
        #expect(count(Self.zone) == count("Europe/Stockholm"))
    }
}
