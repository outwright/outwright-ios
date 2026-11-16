// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightModel
import OutwrightSync
import Testing

/// An occurrence of event `id` starting at `start`, an hour long.
private func occurrence(
    _ id: Int64, at start: Date, reminder: Int? = 15, status: EventStatus = .confirmed,
    recurrenceID: EventTime? = nil, title: String = "Meeting", place: String = ""
) -> CalendarEvent {
    let details = EventDetails(
        title: title, place: place, start: .utc(start), end: .utc(start.addingTimeInterval(3_600)),
        reminder: reminder, status: status)
    return CalendarEvent(
        id: EventID(raw: id), calendarID: CalendarID(raw: 1), accountID: AccountID(),
        occurrence: Occurrence(
            recurrenceID: recurrenceID, details: details, start: start, end: start.addingTimeInterval(3_600)),
        isSeries: recurrenceID != nil, isEditable: true, isTentative: false)
}

@Suite struct ReminderPlanTests {
    @Test func planKeepsTheNearest64() {
        let all = (1...200).map { index in
            occurrence(Int64(index), at: fixedNow.addingTimeInterval(Double(201 - index) * 3_600))
        }
        let planned = ReminderPlan.plan(all.shuffled(), now: fixedNow)
        #expect(planned.count == 64)
        #expect(planned.map(\.fire) == planned.map(\.fire).sorted())
        let nearest = all.sorted { $0.occurrence.start < $1.occurrence.start }.prefix(64)
        #expect(planned.map(\.event) == nearest.map(\.id))
        #expect(planned.first?.fire == fixedNow.addingTimeInterval(3_600 - 15 * 60))
        #expect(ReminderPlan.plan(all, now: fixedNow, limit: 3).count == 3)
    }

    @Test func pastAndCancelledAreSkipped() {
        let planned = ReminderPlan.plan(
            [
                occurrence(1, at: fixedNow.addingTimeInterval(-3_600)),
                // Starts in ten minutes: its fifteen-minute reminder is past.
                occurrence(2, at: fixedNow.addingTimeInterval(600)),
                occurrence(3, at: fixedNow.addingTimeInterval(7_200), status: .cancelled),
                occurrence(4, at: fixedNow.addingTimeInterval(7_200), reminder: nil),
                occurrence(5, at: fixedNow.addingTimeInterval(7_200), title: "Review", place: "Room 4"),
            ], now: fixedNow)
        #expect(planned.map(\.event) == [EventID(raw: 5)])
        #expect(planned.first?.title == "Review")
        #expect(planned.first?.fire == fixedNow.addingTimeInterval(7_200 - 900))
    }

    @Test func farOffTimesPlanNothingAndNeverTrap() {
        let planned = ReminderPlan.plan(
            [occurrence(1, at: Date(timeIntervalSince1970: 1e300)), occurrence(2, at: .distantFuture)], now: fixedNow)
        // Past what a whole number of seconds holds: no reminder. Far but representable: planned.
        #expect(planned.map(\.event) == [EventID(raw: 2)])
    }

    @Test func identifierIsStablePerOccurrence() {
        let start = fixedNow.addingTimeInterval(86_400)
        let recurrence = EventTime.utc(start)
        let first = ReminderPlan.plan([occurrence(7, at: start, recurrenceID: recurrence)], now: fixedNow)
        let again = ReminderPlan.plan(
            [occurrence(7, at: start, reminder: 30, recurrenceID: recurrence, title: "Renamed")], now: fixedNow)
        #expect(first.first?.identifier == "outwright.event.7.\(Int(start.timeIntervalSince1970))")
        #expect(first.first?.identifier == again.first?.identifier)
        #expect(first.first?.occurrence == recurrence)
        let next = ReminderPlan.plan(
            [occurrence(7, at: start.addingTimeInterval(604_800), recurrenceID: .utc(start.addingTimeInterval(604_800)))],
            now: fixedNow)
        #expect(next.first?.identifier != first.first?.identifier)
        let other = ReminderPlan.plan([occurrence(8, at: start)], now: fixedNow)
        #expect(other.first?.identifier != first.first?.identifier)
    }
}
