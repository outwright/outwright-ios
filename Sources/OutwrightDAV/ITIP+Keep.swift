// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// The organiser's change written over the owner's copy on the server.
extension ITIP {
    /// `calendar` (the organiser's change) with what is the owner's in `held` (the copy it is written
    /// over) kept, as RFC 6638 › 3.2.2.1 leaves those to the attendee: the ORGANIZER's SCHEDULE-AGENT
    /// (it is the client's to set at the create, never to change), and on each VEVENT the held copy
    /// has too, the owner's VALARMs and, while its timing is unchanged, the owner's PARTSTAT.
    public static func keepingOwn(_ calendar: ICalComponent, from held: ICalComponent, ownEmail: String)
        -> ICalComponent {
        let agent = seriesEvent(held)?.first("ORGANIZER").flatMap { organizer in
            organizer.parameters.first { $0.name == "SCHEDULE-AGENT" }
        } ?? events(held).first?.first("ORGANIZER")?.parameters.first { $0.name == "SCHEDULE-AGENT" }
        let heldEvents = events(held)
        var result = calendar
        result.components = calendar.components.map { component in
            guard component.name == "VEVENT" else { return component }
            var event = withAgent(component, agent)
            guard let old = heldEvents.first(where: {
                key($0.first("RECURRENCE-ID")) == key(component.first("RECURRENCE-ID"))
            }) else { return event }
            let sameTime = timing.allSatisfy { component.all($0) == old.all($0) }
            if sameTime, let answered = old.all("ATTENDEE").first(where: { isOwn($0, ownEmail) })?
                .parameter("PARTSTAT").map(token), !answered.isEmpty {
                event = withOwnPartstat(event, answered, ownEmail, dropRSVP: answered != "NEEDS-ACTION")
            }
            event.components = event.components.filter { $0.name != "VALARM" }
                + old.components.filter { $0.name == "VALARM" }
            return event
        }
        return result
    }

    /// The VEVENT's ORGANIZER with `agent` as its SCHEDULE-AGENT, or with none.
    private static func withAgent(_ event: ICalComponent, _ agent: ContentParameter?) -> ICalComponent {
        let organizers = event.all("ORGANIZER")
        guard !organizers.isEmpty else { return event }
        return event.replacing("ORGANIZER", with: organizers.map { organizer in
            var line = organizer
            line.parameters = line.parameters.filter { $0.name != "SCHEDULE-AGENT" } + (agent.map { [$0] } ?? [])
            return line
        })
    }
}
