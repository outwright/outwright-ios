// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightDAV
import OutwrightModel

/// The owner's answer and own reminder on an invitation, written into its calendar object. Only the
/// owner's PARTSTAT (`ITIP.settingPartstat`) or the shown VALARM changes; SEQUENCE and everything else
/// stay as the organiser wrote them.
extension EventMapping {
    /// The iCalendar PARTSTAT of an answer; nil for delegated, which the app does not write.
    static func partstat(_ response: Attendee.Response) -> String? {
        switch response {
        case .needsAction: "NEEDS-ACTION"
        case .accepted: "ACCEPTED"
        case .tentative: "TENTATIVE"
        case .declined: "DECLINED"
        case .delegated: nil
        }
    }

    /// An answer (the owner's, `ownEmail` being theirs, or a guest's to the owner's meeting) or the own
    /// reminder written; any other edit leaves the object.
    static func invitee(_ edit: EventEdit, _ calendar: ICalComponent, uid: String, ownEmail: String) -> ICalComponent {
        switch edit {
        case let .respond(response, scope, _, _): answered(calendar, response, scope, ownEmail: ownEmail)
        case let .ownReminder(minutes, scope): reminded(calendar, minutes, scope, uid: uid)
        case let .guestAnswer(guest, response, scope): guestAnswered(calendar, response, scope, guest: guest)
        case .create, .update, .delete, .organiserChange: calendar
        }
    }

    /// The answer for the whole event is written on every VEVENT of it (it holds for each occurrence,
    /// as the store shows it); for one occurrence on its override, made from the series when there is
    /// none.
    static func answered(
        _ calendar: ICalComponent, _ response: Attendee.Response, _ scope: EditScope, ownEmail: String
    ) -> ICalComponent {
        guard let partstat = partstat(response) else { return calendar }
        switch scope {
        case let .occurrence(time):
            return ITIP.settingPartstat(
                partstat, in: calendar, ownEmail: ownEmail, recurrenceID: ICalValue.property("RECURRENCE-ID", time))
        case .event:
            var result = ITIP.settingPartstat(partstat, in: calendar, ownEmail: ownEmail, recurrenceID: nil)
            let overrides = calendar.components.filter { $0.name == "VEVENT" }.compactMap { $0.first("RECURRENCE-ID") }
            for line in overrides {
                result = ITIP.settingPartstat(partstat, in: result, ownEmail: ownEmail, recurrenceID: line)
            }
            return result
        }
    }

    /// A guest's answer to the owner's meeting: for one occurrence on its override, for the whole event
    /// on the series and on each override where the guest has not answered on their own.
    static func guestAnswered(
        _ calendar: ICalComponent, _ response: Attendee.Response, _ scope: EditScope, guest: String
    ) -> ICalComponent {
        guard let partstat = partstat(response) else { return calendar }
        if case .occurrence = scope { return answered(calendar, response, scope, ownEmail: guest) }
        var result = ITIP.settingPartstat(partstat, in: calendar, ownEmail: guest, recurrenceID: nil)
        let unanswered = calendar.components.filter { event in
            event.name == "VEVENT" && event.all("ATTENDEE").contains {
                address($0.value).lowercased() == guest.lowercased()
                    && ($0.parameter("PARTSTAT") ?? "NEEDS-ACTION").uppercased() == "NEEDS-ACTION"
            }
        }.compactMap { $0.first("RECURRENCE-ID") }
        for line in unanswered {
            result = ITIP.settingPartstat(partstat, in: result, ownEmail: guest, recurrenceID: line)
        }
        return result
    }

    /// The own reminder set on the series event (on every override when there is no series event), or
    /// on one occurrence: its override, made from the series (the occurrence's own time, nothing
    /// else changed, SEQUENCE kept) when there is none.
    static func reminded(_ calendar: ICalComponent, _ minutes: Int?, _ scope: EditScope, uid: String) -> ICalComponent {
        var result = calendar
        switch scope {
        case .event:
            let hasBase = calendar.components.contains { isBase($0, uid) }
            for (index, component) in calendar.components.enumerated()
            where isEvent(component, uid) && (!hasBase || isBase(component, uid)) {
                result.components[index] = alarmed(component, minutes)
            }
            return result
        case let .occurrence(time):
            let zones = zones(calendar)
            if let index = overrideIndex(calendar, uid, time, zones) {
                result.components[index] = alarmed(calendar.components[index], minutes)
                return result
            }
            guard let baseIndex = calendar.components.firstIndex(where: { isBase($0, uid) }),
                let series = series(calendar).first(where: { $0.uid == uid }),
                var own = Recurrence.ownOverride(at: time, in: series, phoneZone: ICalValue.utcZone)
            else { return calendar }
            let base = calendar.components[baseIndex]
            var copy = base
            copy.properties.removeAll { ["RRULE", "RDATE", "EXDATE", "EXRULE"].contains($0.name) }
            copy = copy.replacing("RECURRENCE-ID", with: [ICalValue.property("RECURRENCE-ID", time)])
            own.details.reminder = minutes
            copy = revised(copy, from: details(base, zones: zones), to: own.details, organizer: "")
            let last = calendar.components.lastIndex { isEvent($0, uid) } ?? baseIndex
            result.components.insert(copy, at: last + 1)
            return withZones(result)
        }
    }
}
