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
