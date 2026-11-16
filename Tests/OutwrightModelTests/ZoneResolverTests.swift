// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Testing

@testable import OutwrightModel

@Suite struct ZoneResolverTests {
    static let custom = ZoneRules(observances: [
        Observance(isDaylight: false, start: Cal.wall(1970, 10, 25, 3), offsetFrom: 7_200, offsetTo: 3_600,
                   rule: RecurrenceRule.parse("FREQ=YEARLY;BYMONTH=10;BYDAY=-1SU")),
        Observance(isDaylight: true, start: Cal.wall(1970, 3, 29, 2), offsetFrom: 3_600, offsetTo: 7_200,
                   rule: RecurrenceRule.parse("FREQ=YEARLY;BYMONTH=3;BYDAY=-1SU")),
    ])

    /// An instant in a VTIMEZONE-only zone expands the zone's rules around the time's own year only.
    @Test func instantsInAnOwnZoneAreQuick() {
        let started = threadCPUTime()
        var found: [Date] = []
        for index in 0..<200 {
            let time = EventTime.zoned(Cal.wall(2026 + index % 20, 7, 1, 12), zone: "Own")
            if let instant = time.instant(in: .gmt, zones: ["Own": Self.custom]) { found.append(instant) }
        }
        // About a quarter of a second of CPU; expanding the rules from 1970 instead would take many
        // times longer. CPU time, not the clock, so a busy machine doesn't count.
        #expect(threadCPUTime() - started < .seconds(3))
        // Summer: two hours ahead of UTC.
        #expect(found.first == Cal.instant(2026, 7, 1, 10, in: .gmt))
        #expect(found.count == 200)
    }

    @Test func ianaIdIsUsed() {
        #expect(ZoneResolver.resolve(tzid: "Europe/Stockholm", given: [:]) == .iana("Europe/Stockholm"))
    }

    @Test func windowsZoneNameResolves() {
        #expect(ZoneResolver.resolve(tzid: "W. Europe Standard Time", given: [:]) == .iana("Europe/Berlin"))
    }

    @Test func vtimezoneRulesAreUsedForUnknownId() {
        let resolved = ZoneResolver.resolve(tzid: "Custom Central", given: ["Custom Central": Self.custom])
        #expect(resolved == .rules(Self.custom))
    }

    @Test func unknownZoneIsFloating() {
        #expect(ZoneResolver.resolve(tzid: "Nowhere/Atlantis", given: [:]) == .floating)
    }

    @Test func zonedTimeUsesTheGivenVTIMEZONE() {
        let time = EventTime.zoned(Cal.wall(2026, 7, 1, 9), zone: "Custom Central")
        #expect(time.instant(in: Cal.newYork, zones: ["Custom Central": Self.custom])
            == Cal.instant(2026, 7, 1, 7, in: .gmt))
    }

    @Test func hugeObservanceOffsetsAreClamped() throws {
        let json = Data("""
            {"observances": [{"isDaylight": false, "start": {"year": 1970, "month": 1, "day": 1},
              "offsetFrom": \(Int.max), "offsetTo": \(Int.min), "rdates": []}]}
            """.utf8)
        let rules = try JSONDecoder().decode(ZoneRules.self, from: json)
        let time = EventTime.zoned(Cal.wall(2026, 6, 1, 9), zone: "Hostile")
        // TZOFFSETTO is clamped to -18 hours.
        #expect(time.instant(in: Cal.stockholm, zones: ["Hostile": rules]) == Cal.instant(2026, 6, 2, 3, in: .gmt))
        let series = Cal.series(Cal.hour(Cal.wall(2026, 6, 1, 9), zone: "Hostile"), rule: "FREQ=DAILY",
                                zones: ["Hostile": rules])
        let found = Recurrence.occurrences(series, from: Cal.instant(2026, 6, 1), to: Cal.instant(2026, 7, 1),
                                           phoneZone: Cal.stockholm)
        #expect(!found.isEmpty)
    }

    @Test func vtimezoneGapMovesForward() {
        let series = Cal.series(Cal.hour(Cal.wall(2026, 3, 29, 2, 30), zone: "Custom Central"),
                                zones: ["Custom Central": Self.custom])
        let found = Recurrence.occurrences(series, from: Cal.instant(2026, 3, 1), to: Cal.instant(2026, 4, 1),
                                           phoneZone: Cal.newYork)
        #expect(found.map(\.start) == [Cal.instant(2026, 3, 29, 1, 30, in: .gmt)])
    }

    @Test func vtimezoneRulesPlaceTheEvent() {
        let winter = Cal.series(Cal.hour(Cal.wall(2026, 1, 15, 9), zone: "Custom Central"),
                                zones: ["Custom Central": Self.custom])
        let summer = Cal.series(Cal.hour(Cal.wall(2026, 7, 1, 9), zone: "Custom Central"),
                                zones: ["Custom Central": Self.custom])
        let from = Cal.instant(2026, 1, 1)
        let to = Cal.instant(2027, 1, 1)
        let first = Recurrence.occurrences(winter, from: from, to: to, phoneZone: Cal.newYork)
        let second = Recurrence.occurrences(summer, from: from, to: to, phoneZone: Cal.newYork)
        #expect(first.map(\.start) == [Cal.instant(2026, 1, 15, 8, in: .gmt)])
        #expect(second.map(\.start) == [Cal.instant(2026, 7, 1, 7, in: .gmt)])
    }

    /// A zone goes out under the Windows name CLDR gives its territory, as Outlook names it.
    @Test(arguments: [
        ("Europe/Stockholm", "W. Europe Standard Time"), ("Europe/Budapest", "Central Europe Standard Time"),
        ("America/Detroit", "Eastern Standard Time"), ("Europe/Berlin", "W. Europe Standard Time"),
    ])
    func windowsNamesFollowTheTerritory(_ pair: (String, String)) {
        #expect(WindowsZones.windowsName(forIANA: pair.0) == pair.1)
    }

    /// A zone CLDR doesn't list still gets the name of a zone with the same clock, quickly.
    @Test func anUnlistedZoneGetsAMatchingClockQuickly() {
        let started = threadCPUTime()
        for _ in 0..<50 { #expect(WindowsZones.windowsName(forIANA: "America/Nuuk") != nil) }
        #expect(threadCPUTime() - started < .seconds(1))
        #expect(WindowsZones.windowsName(forIANA: "Not/AZone") == nil)
    }
}

/// The CPU time the calling thread has used: what a speed check measures, unlike the clock, which
/// also counts the time other processes on a busy machine take.
private func threadCPUTime() -> Duration {
    .nanoseconds(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID))
}
