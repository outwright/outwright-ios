// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Testing

@testable import OutwrightModel

@Suite struct RecurrenceTests {
    let november = (from: Cal.instant(2026, 11, 1), to: Cal.instant(2026, 12, 1))

    private func expand(_ series: EventSeries, _ from: Date, _ to: Date,
                        zone: TimeZone = Cal.stockholm) -> [Occurrence] {
        Recurrence.occurrences(series, from: from, to: to, phoneZone: zone)
    }

    private func mondays(_ extra: (EventSeries) -> EventSeries = { $0 }) -> [Occurrence] {
        let series = Cal.series(Cal.hour(Cal.wall(2026, 11, 2, 9)), rule: "FREQ=WEEKLY;BYDAY=MO")
        return expand(extra(series), november.from, november.to)
    }

    @Test func singleEventIsOneOccurrence() {
        let found = expand(Cal.series(Cal.hour(Cal.wall(2026, 11, 9, 9))), november.from, november.to)
        #expect(found.count == 1)
        #expect(found.first?.start == Cal.instant(2026, 11, 9, 9))
        #expect(found.first?.end == Cal.instant(2026, 11, 9, 10))
        #expect(found.first?.allDayStart == nil)
    }

    @Test func allDayEventCoversItsDays() {
        let christmas = Cal.details(.date(year: 2026, month: 12, day: 24), .date(year: 2026, month: 12, day: 26))
        let found = expand(Cal.series(christmas), Cal.instant(2026, 12, 1), Cal.instant(2027, 1, 1))
        #expect(found.count == 1)
        #expect(found.first?.allDayStart == 20_261_224)
        #expect(found.first?.allDayEnd == 20_261_226)
        #expect(found.first?.start == Cal.instant(2026, 12, 24))
        #expect(found.first?.end == Cal.instant(2026, 12, 26))
    }

    @Test func weeklySeriesKeepsLocalTimeAcrossDST() {
        let series = Cal.series(Cal.hour(Cal.wall(2026, 3, 2, 9)), rule: "FREQ=WEEKLY;BYDAY=MO;COUNT=12")
        let found = expand(series, Cal.instant(2026, 3, 1), Cal.instant(2026, 7, 1))
        #expect(found.count == 12)
        for occurrence in found {
            #expect(Cal.local(occurrence.start).hour == 9)
            let utcHour = Cal.local(occurrence.start, in: .gmt).hour
            #expect(utcHour == (occurrence.start < Cal.instant(2026, 3, 29, 3) ? 8 : 7))
        }
    }

    @Test func monthlyLastFridayAndYearlyByMonth() {
        let monthly = Cal.series(Cal.hour(Cal.wall(2026, 1, 30, 10)), rule: "FREQ=MONTHLY;BYDAY=-1FR")
        let fridays = expand(monthly, Cal.instant(2026, 1, 1), Cal.instant(2027, 1, 1)).map { Cal.local($0.start).day }
        #expect(fridays == [30, 27, 27, 24, 29, 26, 31, 28, 25, 30, 27, 25])
        let yearly = Cal.series(Cal.hour(Cal.wall(2026, 6, 1, 10)), rule: "FREQ=YEARLY;BYMONTH=6;BYMONTHDAY=1")
        let firsts = expand(yearly, Cal.instant(2026, 1, 1), Cal.instant(2029, 1, 1)).map { Cal.local($0.start) }
        #expect(firsts.map(\.year) == [2026, 2027, 2028])
        #expect(firsts.allSatisfy { $0.month == 6 && $0.day == 1 && $0.hour == 10 })
    }

    @Test func countAndUntilEndTheSeries() {
        let counted = Cal.series(Cal.hour(Cal.wall(2026, 11, 1, 9)), rule: "FREQ=DAILY;COUNT=3")
        #expect(expand(counted, november.from, november.to).count == 3)
        let until = Cal.series(Cal.hour(Cal.wall(2026, 11, 1, 9)), rule: "FREQ=DAILY;UNTIL=20261105T235959Z")
        let days = expand(until, november.from, november.to).map { Cal.local($0.start).day }
        #expect(days == [1, 2, 3, 4, 5])
    }

    @Test func overrideReplacesItsOccurrence() {
        let moved = Cal.hour(Cal.wall(2026, 11, 16, 13), title: "Moved")
        let found = mondays { series in
            var series = series
            series.overrides = [EventOverride(recurrenceID: .zoned(Cal.wall(2026, 11, 16, 9), zone: "Europe/Stockholm"), details: moved)]
            return series
        }
        #expect(found.count == 5)
        let that = found.filter { Cal.local($0.start).day == 16 }
        #expect(that.count == 1)
        #expect(that.first.map { Cal.local($0.start).hour } == 13)
        #expect(that.first?.details.title == "Moved")
    }

    @Test func duplicateOverridesKeepTheHighestSequence() {
        let id = EventTime.zoned(Cal.wall(2026, 11, 16, 9), zone: "Europe/Stockholm")
        func moved(_ title: String, sequence: Int) -> EventDetails {
            var details = Cal.hour(Cal.wall(2026, 11, 16, 13), title: title)
            details.sequence = sequence
            return details
        }
        let highest = mondays { series in
            var series = series
            series.overrides = [EventOverride(recurrenceID: id, details: moved("New", sequence: 2)),
                                EventOverride(recurrenceID: id, details: moved("Old", sequence: 1))]
            return series
        }
        #expect(highest.filter { Cal.local($0.start).day == 16 }.map(\.details.title) == ["New"])
        let tie = mondays { series in
            var series = series
            series.overrides = [EventOverride(recurrenceID: id, details: moved("First", sequence: 1)),
                                EventOverride(recurrenceID: id, details: moved("Later", sequence: 1))]
            return series
        }
        #expect(tie.filter { Cal.local($0.start).day == 16 }.map(\.details.title) == ["Later"])
    }

    @Test func exdateAndCancelledOverrideAreSkipped() {
        let found = mondays { series in
            var series = series
            series.exdates = [.zoned(Cal.wall(2026, 11, 9, 9), zone: "Europe/Stockholm")]
            series.overrides = [EventOverride(
                recurrenceID: .zoned(Cal.wall(2026, 11, 23, 9), zone: "Europe/Stockholm"),
                details: Cal.hour(Cal.wall(2026, 11, 23, 9), status: .cancelled)
            )]
            return series
        }
        #expect(found.map { Cal.local($0.start).day } == [2, 16, 30])
    }

    /// The Monday 09:00 standup from the 9th on moves to 10:00, half an hour, with new details.
    private func fromTheNinth(_ title: String = "Moved", hour: Int = 10, day: Int = 9) -> EventOverride {
        var moved = Cal.details(.zoned(Cal.wall(2026, 11, day, hour), zone: "Europe/Stockholm"),
                                .zoned(Cal.wall(2026, 11, day, hour, 30), zone: "Europe/Stockholm"), title: title)
        moved.place = "Room 2"
        moved.notes = "Agenda"
        moved.reminder = 5
        moved.attendees = [Attendee(email: "a@example.org")]
        moved.status = .tentative
        return EventOverride(recurrenceID: .zoned(Cal.wall(2026, 11, day, 9), zone: "Europe/Stockholm"),
                             details: moved, thisAndFuture: true)
    }

    @Test func thisAndFutureMovesEveryLaterOccurrence() {
        let found = mondays { series in
            var series = series
            series.overrides = [fromTheNinth()]
            return series
        }
        #expect(found.map { Cal.local($0.start).day } == [2, 9, 16, 23, 30])
        #expect(found.map { Cal.local($0.start).hour } == [9, 10, 10, 10, 10])
        #expect(found.map { $0.end.timeIntervalSince($0.start) } == [3_600, 1_800, 1_800, 1_800, 1_800])
        #expect(found.map(\.details.title) == ["Standup", "Moved", "Moved", "Moved", "Moved"])
        let later = found.dropFirst()
        #expect(later.allSatisfy { $0.details.place == "Room 2" && $0.details.notes == "Agenda" })
        #expect(later.allSatisfy { $0.details.reminder == 5 && $0.details.status == .tentative })
        #expect(later.allSatisfy { $0.details.attendees.map(\.email) == ["a@example.org"] })
        // Each keeps its own occurrence's identity.
        #expect(found.map(\.recurrenceID) == [2, 9, 16, 23, 30].map {
            .zoned(Cal.wall(2026, 11, $0, 9), zone: "Europe/Stockholm")
        })
    }

    @Test func plainOverrideInsideARangeWinsForItsOccurrence() {
        let found = mondays { series in
            var series = series
            series.overrides = [
                fromTheNinth(),
                EventOverride(recurrenceID: .zoned(Cal.wall(2026, 11, 23, 9), zone: "Europe/Stockholm"),
                              details: Cal.hour(Cal.wall(2026, 11, 23, 13), title: "Single")),
            ]
            return series
        }
        #expect(found.map { Cal.local($0.start).hour } == [9, 10, 10, 13, 10])
        #expect(found.map(\.details.title) == ["Standup", "Moved", "Moved", "Single", "Moved"])
    }

    @Test func twoRangesMakeTwoSegments() {
        let found = mondays { series in
            var series = series
            series.overrides = [fromTheNinth("B", hour: 11, day: 23), fromTheNinth("A")]
            return series
        }
        #expect(found.map { Cal.local($0.start).hour } == [9, 10, 10, 11, 11])
        #expect(found.map(\.details.title) == ["Standup", "A", "A", "B", "B"])
    }

    @Test func exdateInsideARangeIsRemoved() {
        let found = mondays { series in
            var series = series
            series.overrides = [fromTheNinth()]
            series.exdates = [.zoned(Cal.wall(2026, 11, 23, 9), zone: "Europe/Stockholm")]
            return series
        }
        #expect(found.map { Cal.local($0.start).day } == [2, 9, 16, 30])
    }

    @Test func cancelledRangeRemovesEveryLaterOccurrence() {
        let found = mondays { series in
            var series = series
            var cancelled = fromTheNinth()
            cancelled.details.status = .cancelled
            series.overrides = [cancelled]
            return series
        }
        #expect(found.map { Cal.local($0.start).day } == [2])
    }

    @Test func rangeShiftsInWallTimeAcrossDST() {
        let series = Cal.series(
            Cal.hour(Cal.wall(2026, 3, 2, 9)), rule: "FREQ=WEEKLY;BYDAY=MO;COUNT=8",
            overrides: [EventOverride(recurrenceID: .zoned(Cal.wall(2026, 3, 16, 9), zone: "Europe/Stockholm"),
                                      details: Cal.hour(Cal.wall(2026, 3, 16, 10)), thisAndFuture: true)])
        let found = expand(series, Cal.instant(2026, 3, 1), Cal.instant(2026, 5, 1))
        #expect(found.map { Cal.local($0.start).hour } == [9, 9, 10, 10, 10, 10, 10, 10])
        #expect(found.allSatisfy { $0.end.timeIntervalSince($0.start) == 3_600 })
    }

    @Test func rangeMovesOccurrencesIntoTheWindowFromOutsideIt() {
        // From the 2nd on, every Monday moves ten days later, to a Thursday.
        let series = Cal.series(
            Cal.hour(Cal.wall(2026, 11, 2, 9)), rule: "FREQ=WEEKLY;BYDAY=MO",
            overrides: [EventOverride(recurrenceID: .zoned(Cal.wall(2026, 11, 2, 9), zone: "Europe/Stockholm"),
                                      details: Cal.hour(Cal.wall(2026, 11, 12, 9)), thisAndFuture: true)])
        let found = expand(series, Cal.instant(2026, 12, 1), Cal.instant(2026, 12, 8))
        #expect(found.map { Cal.local($0.start).day } == [3])
    }

    @Test func aSplitRangeCarriesOnFromTheNextFreeOccurrence() {
        let zone = "Europe/Stockholm"
        var series = Cal.series(Cal.hour(Cal.wall(2026, 11, 2, 9)), rule: "FREQ=WEEKLY;BYDAY=MO;COUNT=5")
        series.overrides = [fromTheNinth(),
                            EventOverride(recurrenceID: .zoned(Cal.wall(2026, 11, 23, 9), zone: zone),
                                          details: Cal.hour(Cal.wall(2026, 11, 23, 13), title: "Single"))]
        series.exdates = [.zoned(Cal.wall(2026, 11, 16, 9), zone: zone)]
        let ninth = EventTime.zoned(Cal.wall(2026, 11, 9, 9), zone: zone)
        let carried = Recurrence.rangeAfter(ninth, in: series, phoneZone: Cal.stockholm)
        #expect(carried?.recurrenceID == .zoned(Cal.wall(2026, 11, 30, 9), zone: zone))
        #expect(carried?.details.start == .zoned(Cal.wall(2026, 11, 30, 10), zone: zone))
        #expect(carried?.details.end == .zoned(Cal.wall(2026, 11, 30, 10, 30), zone: zone))
        #expect(carried?.details.title == "Moved")
        #expect(carried?.thisAndFuture == true)
        // No range starts at a plain override; none carries on past the last occurrence.
        #expect(Recurrence.rangeAfter(.zoned(Cal.wall(2026, 11, 23, 9), zone: zone), in: series,
                                      phoneZone: Cal.stockholm) == nil)
        series.exdates.append(.zoned(Cal.wall(2026, 11, 30, 9), zone: zone))
        #expect(Recurrence.rangeAfter(ninth, in: series, phoneZone: Cal.stockholm) == nil)
    }

    @Test func aSplitRangeStopsAtTheNextRange() {
        let zone = "Europe/Stockholm"
        var series = Cal.series(Cal.hour(Cal.wall(2026, 11, 2, 9)), rule: "FREQ=WEEKLY;BYDAY=MO")
        series.overrides = [fromTheNinth("A"), fromTheNinth("B", hour: 11, day: 16)]
        let ninth = EventTime.zoned(Cal.wall(2026, 11, 9, 9), zone: zone)
        // The 9th's range ends where the 16th's begins: nothing is left of it to carry on.
        #expect(Recurrence.rangeAfter(ninth, in: series, phoneZone: Cal.stockholm) == nil)
        // With a week before the next range, it carries on into that week.
        series.overrides = [fromTheNinth("A"), fromTheNinth("B", hour: 11, day: 23)]
        let carried = Recurrence.rangeAfter(ninth, in: series, phoneZone: Cal.stockholm)
        #expect(carried?.recurrenceID == .zoned(Cal.wall(2026, 11, 16, 9), zone: zone))
    }

    @Test func aRangeShiftedPastTheLastYearCarriesNothingOn() {
        let floating = { (day: Int) in EventTime.floating(Cal.wall(9999, 12, day, 9)) }
        let base = Cal.details(floating(2), .floating(Cal.wall(9999, 12, 2, 10)))
        let range = Cal.details(floating(26), .floating(Cal.wall(9999, 12, 26, 10)), title: "Late")
        let series = Cal.series(base, rule: "FREQ=WEEKLY", overrides: [
            EventOverride(recurrenceID: floating(16), details: range, thisAndFuture: true),
        ])
        // The 23rd shifted by the range's ten days would fall in year 10000.
        #expect(Recurrence.rangeAfter(floating(16), in: series, phoneZone: Cal.stockholm) == nil)
        let found = expand(series, Cal.instant(9999, 12, 1), Cal.instant(9999, 12, 31))
        #expect(found.map { Cal.local($0.start).day } == [2, 9, 26])
    }

    @Test func savedOverrideWithoutOrWithAnUnreadableRangeIsItsOwnOccurrenceOnly() throws {
        let ranged = fromTheNinth()
        let data = try JSONEncoder().encode(ranged)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(try JSONDecoder().decode(EventOverride.self, from: data) == ranged)
        object["thisAndFuture"] = nil
        let older = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(EventOverride.self, from: older).thisAndFuture == false)
        object["thisAndFuture"] = "yes"
        let hostile = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(EventOverride.self, from: hostile).thisAndFuture == false)
    }

    @Test func rdateAddsAnOccurrence() {
        let found = mondays { series in
            var series = series
            series.rdates = [.zoned(Cal.wall(2026, 11, 4, 9), zone: "Europe/Stockholm")]
            return series
        }
        #expect(found.map { Cal.local($0.start).day } == [2, 4, 9, 16, 23, 30])
        #expect(found.allSatisfy { $0.end.timeIntervalSince($0.start) == 3_600 })
    }

    @Test func ruleThatNeverMatchesStops() {
        let series = Cal.series(Cal.hour(Cal.wall(2026, 1, 1, 9)), rule: "FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=30")
        #expect(expand(series, Cal.instant(2026, 2, 1), Cal.instant(2126, 1, 1)).isEmpty)
    }

    @Test func hostileRulesStayWithinCaps() {
        let hourly = Cal.series(Cal.hour(Cal.wall(2026, 1, 1, 9)), rule: "FREQ=HOURLY")
        let many = expand(hourly, Cal.instant(2026, 1, 1), Cal.instant(2029, 1, 1))
        #expect(many.count <= 5_000)
        #expect(!many.isEmpty)
        let counted = Cal.series(Cal.hour(Cal.wall(2026, 1, 1, 9)), rule: "FREQ=DAILY;COUNT=1000000")
        #expect(expand(counted, Cal.instant(2026, 1, 1), Cal.instant(2100, 1, 1)).count <= 5_000)
    }

    @Test func onlyTheWindowIsExpanded() {
        let series = Cal.series(Cal.hour(Cal.wall(2020, 1, 1, 9)), rule: "FREQ=DAILY")
        let from = Cal.instant(2026, 11, 1)
        let found = expand(series, from, Cal.instant(2026, 11, 8))
        #expect(found.count == 7)
        #expect(found.first.map { $0.start >= from } == true)
    }

    @Test func floatingEventFollowsPhoneZone() {
        let series = Cal.series(
            Cal.details(.floating(Cal.wall(2026, 3, 2, 9)), .floating(Cal.wall(2026, 3, 2, 10))),
            rule: "FREQ=WEEKLY;BYDAY=MO;COUNT=12")
        let from = Cal.instant(2026, 3, 1, in: Cal.newYork)
        let found = expand(series, from, Cal.instant(2026, 7, 1, in: Cal.newYork), zone: Cal.newYork)
        #expect(found.count == 12)
        #expect(found.allSatisfy { Cal.local($0.start, in: Cal.newYork).hour == 9 })
    }

    @Test func dstGapMovesForwardAndOverlapTakesTheFirst() {
        let spring = expand(Cal.series(Cal.hour(Cal.wall(2026, 3, 29, 2, 30))), Cal.instant(2026, 3, 1),
                            Cal.instant(2026, 4, 1))
        #expect(spring.map(\.start) == [Cal.instant(2026, 3, 29, 1, 30, in: .gmt)])
        let autumn = expand(Cal.series(Cal.hour(Cal.wall(2026, 10, 25, 2, 30))), Cal.instant(2026, 10, 1),
                            Cal.instant(2026, 11, 1))
        #expect(autumn.map(\.start) == [Cal.instant(2026, 10, 25, 0, 30, in: .gmt)])
    }
    /// A range set ten years before the window, in a zone only its VTIMEZONE defines, still moves the
    /// window's instances by its own shift: an hour later, from 10:00 to 11:00.
    @Test func aRangeYearsBeforeTheWindowInAnOwnZoneShiftsTheWindow() {
        let own = "Made-up North"
        let range = Cal.hour(Cal.wall(2016, 7, 6, 11), zone: own, title: "Later")
        let series = Cal.series(Cal.hour(Cal.wall(2016, 6, 1, 10)), rule: "FREQ=WEEKLY", overrides: [
            EventOverride(recurrenceID: .zoned(Cal.wall(2016, 7, 6, 10), zone: "Europe/Stockholm"),
                          details: range, thisAndFuture: true),
        ], zones: [own: ZoneResolverTests.custom])
        let found = expand(series, Cal.instant(2026, 7, 1), Cal.instant(2026, 8, 1))
        #expect(found.map(\.start) == [1, 8, 15, 22, 29].map { Cal.instant(2026, 7, $0, 11) })
        #expect(found.allSatisfy { $0.details.title == "Later" })
    }
    @Test func bySecondSetsTheSecondsOfEachInstance() {
        let series = Cal.series(Cal.hour(Cal.wall(2026, 11, 2, 9)), rule: "FREQ=DAILY;COUNT=5;BYSECOND=15,45")
        let found = expand(series, november.from, november.to)
        let nine = Cal.instant(2026, 11, 2, 9)
        let next = Cal.instant(2026, 11, 3, 9)
        #expect(found.map(\.start) == [nine, nine.addingTimeInterval(15), nine.addingTimeInterval(45),
                                       next.addingTimeInterval(15), next.addingTimeInterval(45)])
    }

    private func monthly31(_ parts: String) -> [DateComponents] {
        let series = Cal.series(Cal.hour(Cal.wall(2026, 1, 31, 9)), rule: "FREQ=MONTHLY;COUNT=6" + parts)
        return expand(series, Cal.instant(2026, 1, 1), Cal.instant(2027, 1, 1)).map { Cal.local($0.start) }
    }

    @Test func skipMovesAnInvalidDateForwardOrBackward() {
        #expect(monthly31(";RSCALE=GREGORIAN;SKIP=FORWARD") == [
            Cal.wall(2026, 1, 31, 9), Cal.wall(2026, 3, 1, 9), Cal.wall(2026, 3, 31, 9), Cal.wall(2026, 5, 1, 9),
            Cal.wall(2026, 5, 31, 9), Cal.wall(2026, 7, 1, 9),
        ].map(\.minuteless))
        #expect(monthly31(";RSCALE=GREGORIAN;SKIP=BACKWARD") == [
            Cal.wall(2026, 1, 31, 9), Cal.wall(2026, 2, 28, 9), Cal.wall(2026, 3, 31, 9), Cal.wall(2026, 4, 30, 9),
            Cal.wall(2026, 5, 31, 9), Cal.wall(2026, 6, 30, 9),
        ].map(\.minuteless))
        // OMIT, the default, leaves the short months out.
        let omitted = [Cal.wall(2026, 1, 31, 9), Cal.wall(2026, 3, 31, 9), Cal.wall(2026, 5, 31, 9),
                       Cal.wall(2026, 7, 31, 9), Cal.wall(2026, 8, 31, 9), Cal.wall(2026, 10, 31, 9)].map(\.minuteless)
        #expect(monthly31(";RSCALE=GREGORIAN;SKIP=OMIT") == omitted)
        #expect(monthly31("") == omitted)
    }

    /// A day counted from the month's end that the month lacks (−31 in a 30-day month) lies before its
    /// first day: FORWARD gives the first, BACKWARD the previous month's last.
    @Test func skipMovesANegativeDayTheMonthLacks() {
        func days(_ skip: String) -> [DateComponents] {
            let series = Cal.series(Cal.hour(Cal.wall(2026, 1, 1, 9)),
                                    rule: "FREQ=MONTHLY;COUNT=6;BYMONTHDAY=-31;RSCALE=GREGORIAN;SKIP=" + skip)
            return expand(series, Cal.instant(2026, 1, 1), Cal.instant(2027, 1, 1)).map { Cal.local($0.start) }
        }
        #expect(days("FORWARD") == [1, 2, 3, 4, 5, 6].map { Cal.wall(2026, $0, 1, 9).minuteless })
        #expect(days("BACKWARD") == [
            Cal.wall(2026, 1, 1, 9), Cal.wall(2026, 1, 31, 9), Cal.wall(2026, 3, 1, 9), Cal.wall(2026, 3, 31, 9),
            Cal.wall(2026, 5, 1, 9), Cal.wall(2026, 5, 31, 9),
        ].map(\.minuteless))
        #expect(days("OMIT") == [1, 3, 5, 7, 8, 10].map { Cal.wall(2026, $0, 1, 9).minuteless })
    }

    @Test func skipMovesTheLeapDayOfAYearlySeries() {
        let series = Cal.series(Cal.hour(Cal.wall(2028, 2, 29, 9)), rule: "FREQ=YEARLY;COUNT=3;RSCALE=GREGORIAN;SKIP=FORWARD")
        let found = expand(series, Cal.instant(2028, 1, 1), Cal.instant(2032, 1, 1)).map { Cal.local($0.start) }
        #expect(found == [Cal.wall(2028, 2, 29, 9), Cal.wall(2029, 3, 1, 9), Cal.wall(2030, 3, 1, 9)].map(\.minuteless))
    }

    /// Another calendar's rule cannot be laid out in the Gregorian one: only its first occurrence shows.
    @Test func anotherCalendarScaleShowsOnlyTheFirstOccurrence() {
        let series = Cal.series(Cal.hour(Cal.wall(2026, 2, 25, 9)),
                                rule: "FREQ=YEARLY;RSCALE=HEBREW;BYMONTH=5L;BYMONTHDAY=8;SKIP=FORWARD")
        let found = expand(series, Cal.instant(2026, 1, 1), Cal.instant(2036, 1, 1))
        #expect(found.map(\.start) == [Cal.instant(2026, 2, 25, 9)])
        #expect(expand(Cal.series(Cal.hour(Cal.wall(2026, 2, 25, 9)), rule: "FREQ=MONTHLY;RSCALE=CHINESE"),
                       Cal.instant(2026, 1, 1), Cal.instant(2027, 1, 1)).count == 1)
    }
}

private extension DateComponents {
    /// The fields `Cal.local` gives: no seconds.
    var minuteless: DateComponents {
        DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
    }
}
