// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Testing

@testable import OutwrightModel

@Suite struct RecurrenceRuleTests {
    @Test func parsesWeeklyByDay() throws {
        let rule = try #require(RecurrenceRule.parse("FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE,-1FR;WKST=SU"))
        #expect(rule.freq == .weekly)
        #expect(rule.interval == 2)
        #expect(rule.byDay == [
            WeekdayNum(weekday: 1, ordinal: 0), WeekdayNum(weekday: 3, ordinal: 0),
            WeekdayNum(weekday: 5, ordinal: -1),
        ])
        #expect(rule.weekStart == 7)
    }

    @Test func parsesUntilAndCount() throws {
        let counted = try #require(RecurrenceRule.parse("FREQ=DAILY;COUNT=5"))
        #expect(counted.count == 5)
        #expect(counted.until == nil)
        let until = try #require(RecurrenceRule.parse("FREQ=DAILY;UNTIL=20261231T235959Z"))
        #expect(until.until == .utc(Cal.instant(2026, 12, 31, 23, 59, in: .gmt).addingTimeInterval(59)))
        let byDate = try #require(RecurrenceRule.parse("FREQ=DAILY;UNTIL=20261231"))
        #expect(byDate.until == .date(year: 2026, month: 12, day: 31))
    }

    @Test func minutelyIsRefused() {
        #expect(RecurrenceRule.parse("FREQ=MINUTELY") == nil)
        #expect(RecurrenceRule.parse("FREQ=SECONDLY;COUNT=3") == nil)
    }

    @Test func intervalZeroReadsAsOne() throws {
        let rule = try #require(RecurrenceRule.parse("FREQ=DAILY;INTERVAL=0"))
        #expect(rule.interval == 1)
    }

    /// Saved rules are hostile: decoding goes through the same clamps as parsing.
    @Test func decodedRuleIsClampedAndExpands() throws {
        let valid = try #require(RecurrenceRule.parse("FREQ=MONTHLY;BYDAY=-1FR"))
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any])
        object["interval"] = 0
        object["count"] = -5
        object["weekStart"] = 99
        object["byHour"] = [Int.max, 9, -1]
        object["byMinute"] = [Int.min, 30]
        object["byMonthDay"] = [0, 99, -1, Int.min]
        object["byMonth"] = [13, 6]
        object["bySetPos"] = [Int.min, 1]
        object["byYearDay"] = [Int.max]
        object["byWeekNo"] = [54, -53]
        object["byDay"] = [["weekday": 5, "ordinal": Int.min], ["weekday": 99, "ordinal": 0],
                           ["weekday": 1, "ordinal": 2]]
        let data = try JSONSerialization.data(withJSONObject: object)
        let rule = try JSONDecoder().decode(RecurrenceRule.self, from: data)
        try #require(rule.interval == 1)
        #expect(rule.count == 1)
        #expect(rule.weekStart == 1)
        try #require(rule.byHour == [9])
        try #require(rule.byMinute == [30])
        #expect(rule.byMonthDay == [-1])
        #expect(rule.byMonth == [6])
        #expect(rule.bySetPos == [1])
        #expect(rule.byYearDay.isEmpty)
        #expect(rule.byWeekNo == [-53])
        try #require(rule.byDay == [WeekdayNum(weekday: 1, ordinal: 2)])

        var series = Cal.series(Cal.hour(Cal.wall(2026, 1, 30, 10)))
        series.rule = rule
        let found = Recurrence.occurrences(series, from: Cal.instant(2026, 1, 1), to: Cal.instant(2027, 1, 1),
                                           phoneZone: Cal.stockholm)
        #expect(found.count == 1)
    }

    @Test func hugeIntervalDecodesWithoutTrapping() throws {
        let valid = try #require(RecurrenceRule.parse("FREQ=HOURLY"))
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any])
        object["interval"] = Int.max
        let rule = try JSONDecoder().decode(RecurrenceRule.self, from: JSONSerialization.data(withJSONObject: object))
        try #require(rule.interval <= 10_000)
        var series = Cal.series(Cal.hour(Cal.wall(2026, 1, 1, 9)))
        series.rule = rule
        let found = Recurrence.occurrences(series, from: Cal.instant(2026, 1, 1), to: Cal.instant(2100, 1, 1),
                                           phoneZone: Cal.stockholm)
        #expect(found.count <= 5_000)
    }

    @Test func junkIsNil() {
        for text in ["", "garbage", "BYDAY=MO", "FREQ=WEEKLY;INTERVAL=abc", "FREQ=WEEKLY;BYDAY=XX",
                     "FREQ=MONTHLY;BYMONTHDAY=40", "FREQ=DAILY;UNTIL=2026-12-31", "FREQ=FORTNIGHTLY"] {
            #expect(RecurrenceRule.parse(text) == nil, "\(text)")
        }
    }
    @Test func secondsScaleSkipAndUnknownPartsAreKept() throws {
        let rule = try #require(RecurrenceRule.parse(
            "FREQ=MONTHLY;RSCALE=gregorian;SKIP=BACKWARD;BYSECOND=0,30,60;X-OWN=Mixed-Case;BYHOUR=9;X-TWO=a,b"))
        #expect(rule.bySecond == [0, 30, 60])
        #expect(rule.rscale == "GREGORIAN")
        #expect(rule.skip == .backward)
        #expect(rule.otherParts == ["X-OWN=Mixed-Case", "X-TWO=a,b"])
        #expect(rule.byHour == [9])
        // A leap month of another calendar (RFC 7529) is kept as text.
        let hebrew = try #require(RecurrenceRule.parse("FREQ=YEARLY;RSCALE=HEBREW;BYMONTH=5L;BYMONTHDAY=8;SKIP=FORWARD"))
        #expect(hebrew.rscale == "HEBREW")
        #expect(hebrew.byMonth.isEmpty)
        #expect(hebrew.otherParts == ["BYMONTH=5L"])
        #expect(hebrew.byMonthDay == [8])
        #expect(hebrew.skip == .forward)
    }

    @Test func malformedSecondsScaleAndSkipAreNil() {
        for text in ["FREQ=DAILY;BYSECOND=61", "FREQ=DAILY;BYSECOND=-1", "FREQ=MONTHLY;RSCALE=GREGORIAN;SKIP=SIDEWAYS",
                     "FREQ=YEARLY;RSCALE=;BYMONTH=2", "FREQ=YEARLY;RSCALE=GREGORIAN;BYMONTH=5L"] {
            #expect(RecurrenceRule.parse(text) == nil, "\(text)")
        }
        // An unknown part unfit to write back is dropped, the rest of the rule kept.
        #expect(RecurrenceRule.parse("FREQ=DAILY;X-OWN=a\u{7}b;X-FINE=1")?.otherParts == ["X-FINE=1"])
    }

    /// Two other parts that differ only in the case of their name are one part.
    @Test func otherPartsDifferingInNameCaseAreOne() {
        let rule = RecurrenceRule(freq: .daily, otherParts: ["X-OWN=1", "x-own=1", "X-Two=a", "X-TWO=a", "X-TWO=A"])
        #expect(rule.otherParts == ["X-OWN=1", "X-TWO=a", "X-TWO=A"])
    }

    /// Saved rules are hostile: the new parts go through the same checks as parsing.
    @Test func decodedPartsAreChecked() throws {
        let valid = try #require(RecurrenceRule.parse("FREQ=DAILY"))
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any])
        object["bySecond"] = [Int.min, 61, 15, -1]
        object["rscale"] = "not a scale;"
        object["skip"] = "FORWARD"
        object["otherParts"] = ["X-OK=1", "FREQ=SECONDLY", "BYHOUR=3", "X-BAD=a\r\nb", "no-equals", "X-OK=1"]
        let rule = try JSONDecoder().decode(RecurrenceRule.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(rule.bySecond == [15])
        #expect(rule.rscale == nil)
        #expect(rule.skip == .forward)
        #expect(rule.otherParts == ["X-OK=1"])
        // A rule saved before these parts existed still decodes.
        let old = try JSONDecoder().decode(RecurrenceRule.self, from: Data(#"{"freq":"DAILY"}"#.utf8))
        #expect(old == RecurrenceRule(freq: .daily))
    }
}
