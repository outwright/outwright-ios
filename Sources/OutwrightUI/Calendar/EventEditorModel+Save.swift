// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightModel
import OutwrightStore

extension EventEditorModel {
    // MARK: Saving

    /// Stores the event (new, the series, or one occurrence of it) and queues it for the server.
    func save(scope: EditScope) throws(EventEditError) -> EventID {
        guard let calendar else { throw .noCalendar }
        guard !endsBeforeStart else { throw .endBeforeStart }
        let result = cleaned()
        do {
            guard let eventID else { return try app.store.createEvent(result, rule: savedRule, in: calendar) }
            switch scope {
            case .occurrence:
                try app.store.updateEvent(eventID, result, rule: openedRule, scope: scope)
            case .event:
                try app.store.updateEvent(eventID, seriesDetails(result), rule: savedRule, scope: .event)
            }
            return eventID
        } catch {
            throw .store
        }
    }

    /// The series' own event after the edit: its own times when the owner left the occurrence's alone;
    /// else moved by as much as the occurrence was, from the series' own start.
    private func seriesDetails(_ edited: EventDetails) -> EventDetails {
        guard let series, let base = series.base, series.rule != nil || !series.rdates.isEmpty else { return edited }
        var result = edited
        if edited.start == opened.start, edited.end == opened.end {
            result.start = base.start
            result.end = base.end
            return result
        }
        // Both read as the clock the edit is in (a zone picked, a UTC override), so the move is
        // counted in that clock's hours, across a summer-time change too.
        let from = inKind(base.start, like: edited.start)
        guard let delta = EditorTimes.distance(from: inKind(opened.start, like: edited.start), to: edited.start),
            let length = EditorTimes.distance(from: edited.start, to: edited.end),
            let start = EditorTimes.moved(from, by: delta, like: edited.start),
            let end = EditorTimes.moved(start, by: length, like: edited.end)
        else { return edited }
        result.start = start
        result.end = end
        return result
    }

    /// The time as the kind of `template` (unchanged when it already is one).
    private func inKind(_ time: EventTime, like template: EventTime) -> EventTime {
        Self.sameKind(time, template) ? time : EditorTimes.make(like: template, at: instant(time), phone: phone)
    }

    private static func sameKind(_ lhs: EventTime, _ rhs: EventTime) -> Bool {
        switch (lhs, rhs) {
        case (.date, .date), (.floating, .floating), (.utc, .utc): true
        case let (.zoned(_, one), .zoned(_, other)): one == other
        default: false
        }
    }

    /// What is typed, trimmed, with the people as attendees (kept as they were when already invited).
    /// An event with people gets the calendar's account as its organiser.
    private func cleaned() -> EventDetails {
        var result = details
        let trim = { (text: String) in text.trimmingCharacters(in: .whitespacesAndNewlines) }
        result.title = trim(details.title)
        result.place = trim(details.place)
        result.notes = trim(details.notes)
        var lines = details.attendees.filter { Self.same($0.email, details.organizer) }
        var seen = Set(lines.map { $0.email.lowercased() })
        for person in people {
            let key = person.email.lowercased()
            guard seen.insert(key).inserted else { continue }
            let name = trim(person.name ?? "")
            lines.append(
                details.attendees.first { $0.email.lowercased() == key }
                    ?? Attendee(email: person.email, name: name, rsvp: true))
        }
        result.attendees = lines
        if !people.isEmpty, result.organizer == nil { result.organizer = chosen?.account.email }
        return result
    }
}
