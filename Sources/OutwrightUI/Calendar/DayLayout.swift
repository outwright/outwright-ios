// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightModel

/// Lays out a day's timed events by their wall-clock minutes: a run of events that overlap on the
/// clock shares the width, each event in the first column free at its start. Two events in an hour
/// the clock repeats overlap there, so neither hides the other.
enum DayLayout {
    /// The fewest minutes an event takes up, so a short one still has room to be read and tapped.
    static let shortest = 20

    static func place(_ events: [CalendarEvent], minutes: (Date) -> Int) -> [PlacedEvent] {
        let spans = events.map { event in
            let start = minutes(event.occurrence.start)
            let end = max(minutes(event.occurrence.end), start + shortest)
            return PlacedEvent(event: event, column: 0, columns: 1, startMinute: start, endMinute: end)
        }
        let sorted = spans.sorted {
            ($0.startMinute, -$0.endMinute, $0.event.occurrence.start)
                < ($1.startMinute, -$1.endMinute, $1.event.occurrence.start)
        }
        var placed: [PlacedEvent] = []
        var run: [PlacedEvent] = []
        var columnEnds: [Int] = []
        var runEnd = Int.min
        func closeRun() {
            placed += run.map { var event = $0; event.columns = columnEnds.count; return event }
            run = []
            columnEnds = []
        }
        for var span in sorted {
            if span.startMinute >= runEnd { closeRun() }
            if let free = columnEnds.firstIndex(where: { $0 <= span.startMinute }) {
                columnEnds[free] = span.endMinute
                span.column = free
            } else {
                columnEnds.append(span.endMinute)
                span.column = columnEnds.count - 1
            }
            run.append(span)
            runEnd = max(runEnd, span.endMinute)
        }
        closeRun()
        return placed
    }
}

/// An all-day event drawn as one bar across the days it lasts (`first` to `last`, indexes into the
/// days shown), in its lane: the row it takes in the all-day band.
struct AllDayBar: Equatable, Identifiable {
    var event: CalendarEvent
    var first: Int
    var last: Int
    var lane: Int

    var id: String { event.occurrenceKey }
}

/// Lays out the all-day band: each event once, across the days it lasts, the longer ones on top, each
/// in the first lane that is free on all its days.
enum AllDayLayout {
    /// Only the events on a day `touching` accepts are laid out (the days on screen, for the band).
    static func bars(_ days: [DayColumn], touching: (Int) -> Bool = { _ in true }) -> [AllDayBar] {
        var spans: [String: AllDayBar] = [:]
        for (index, day) in days.enumerated() {
            for event in day.allDay {
                let key = event.occurrenceKey
                if var bar = spans[key] {
                    bar.last = index
                    spans[key] = bar
                } else {
                    spans[key] = AllDayBar(event: event, first: index, last: index, lane: 0)
                }
            }
        }
        let sorted = spans.values.filter { bar in (bar.first...bar.last).contains(where: touching) }.sorted {
            ($0.first, $0.first - $0.last, $0.event.occurrence.details.title, $0.id)
                < ($1.first, $1.first - $1.last, $1.event.occurrence.details.title, $1.id)
        }
        // For each lane, the last day it is taken on.
        var laneEnds: [Int] = []
        return sorted.map { bar in
            var bar = bar
            if let free = laneEnds.firstIndex(where: { $0 < bar.first }) {
                laneEnds[free] = bar.last
                bar.lane = free
            } else {
                laneEnds.append(bar.last)
                bar.lane = laneEnds.count - 1
            }
            return bar
        }
    }
}
