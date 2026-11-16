// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
public import OutwrightDAV
public import OutwrightModel

extension EventMapping {
    public static let productID = "-//Outwright//Outwright//EN"

    /// The calendar object with the owner's edit written into the events of `uid`. A create (or any
    /// edit with no object) makes a new VCALENDAR, with a fresh `urn:uuid:` UID when `uid` is empty.
    /// Only the properties the app shows are rewritten, and only when they changed; everything else
    /// (other VEVENTs, alarms not shown, X- properties, parameters, METHOD, DTSTAMP) stays as it came.
    /// An update raises SEQUENCE. ORGANIZER (`organizer`, the account's address) is set only when the
    /// event has attendees; an answer to an invitation is that address's PARTSTAT. A series' new time
    /// or rule removes its overridden occurrences and EXDATEs.
    public static func apply(
        _ edit: EventEdit, to calendar: ICalComponent?, uid: String, organizer: String
    ) -> ICalComponent {
        switch edit {
        case let .create(details, rule):
            guard let calendar else { return created(details, rule: rule, uid: uid, organizer: organizer) }
            return updated(calendar, details, rule: rule, uid: uid, organizer: organizer)
        case let .update(details, rule, scope):
            guard let calendar else { return created(details, rule: rule, uid: uid, organizer: organizer) }
            switch scope {
            case .event:
                return updated(calendar, details, rule: rule, uid: uid, organizer: organizer)
            case let .occurrence(time):
                return overridden(calendar, details, at: time, uid: uid, organizer: organizer)
            }
        case let .delete(scope):
            guard let calendar else { return ICalComponent(name: "VCALENDAR") }
            return deleted(calendar, scope, uid: uid)
        case .respond, .ownReminder, .guestAnswer, .organiserChange:
            guard let calendar else { return ICalComponent(name: "VCALENDAR") }
            return invitee(edit, calendar, uid: uid, ownEmail: organizer)
        }
    }

    // MARK: - Edits

    private static func deleted(_ calendar: ICalComponent, _ scope: EditScope, uid: String) -> ICalComponent {
        switch scope {
        case .event:
            var calendar = calendar
            calendar.components.removeAll { $0.name == "VEVENT" && $0.first("UID")?.value == uid }
            return calendar
        case let .occurrence(time):
            return excluded(calendar, time, uid: uid)
        }
    }

    private static func created(
        _ details: EventDetails, rule: RecurrenceRule?, uid: String, organizer: String
    ) -> ICalComponent {
        let uid = uid.isEmpty ? "urn:uuid:" + UUID().uuidString.lowercased() : uid
        var event = ICalComponent(name: "VEVENT", properties: [
            ICalProperty(name: "UID", value: uid), ICalProperty(name: "DTSTAMP", value: ICalValue.utcText(Date())),
            ICalProperty(name: "SEQUENCE", value: "0")
        ])
        event = revised(event, from: nil, to: details, organizer: organizer)
        if let rule { event.properties.append(ICalProperty(name: "RRULE", value: ICalValue.recur(rule))) }
        let calendar = ICalComponent(
            name: "VCALENDAR",
            properties: [ICalProperty(name: "VERSION", value: "2.0"), ICalProperty(name: "PRODID", value: productID)],
            components: [event])
        return withZones(calendar)
    }

    private static func updated(
        _ calendar: ICalComponent, _ details: EventDetails, rule: RecurrenceRule?, uid: String, organizer: String
    ) -> ICalComponent {
        guard let index = calendar.components.firstIndex(where: { isBase($0, uid) })
        else { return calendar }
        let zones = zones(calendar)
        let event = calendar.components[index]
        let old = Self.details(event, zones: zones)
        let oldRule = event.first("RRULE").flatMap { RecurrenceRule.parse($0.value) }
        var next = revised(event, from: old, to: details, organizer: organizer)
        if rule != oldRule {
            let line = rule.map { [ICalProperty(name: "RRULE", value: ICalValue.recur($0))] } ?? []
            next = next.replacing("RRULE", with: line)
        }
        let moved = old?.start != details.start || old?.end != details.end || rule != oldRule
        if moved { next = next.replacing("EXDATE", with: []) }
        var result = calendar
        result.components[index] = bumped(next, old)
        if moved {
            result.components.removeAll { isEvent($0, uid) && $0.first("RECURRENCE-ID") != nil }
        } else if let old {
            result = followed(result, seriesFrom: old, to: details, uid: uid, organizer: organizer)
        }
        return withZones(result)
    }

    /// Every range's VEVENT of `uid` given the series' change in the fields it had as the series did.
    private static func followed(
        _ calendar: ICalComponent, seriesFrom old: EventDetails, to new: EventDetails, uid: String,
        organizer: String
    ) -> ICalComponent {
        let zones = zones(calendar)
        var result = calendar
        for (index, event) in calendar.components.enumerated() where isEvent(event, uid) && isRange(event) {
            guard let held = Self.details(event, zones: zones) else { continue }
            let next = held.following(seriesFrom: old, to: new)
            guard next != held, result.components.indices.contains(index) else { continue }
            result.components[index] = bumped(revised(event, from: held, to: next, organizer: organizer), held)
        }
        return result
    }

    private static func isRange(_ event: ICalComponent) -> Bool {
        let range = event.first("RECURRENCE-ID")?.parameter("RANGE")
        return range?.trimmingCharacters(in: .whitespaces).uppercased() == "THISANDFUTURE"
    }

    /// The VEVENT of `uid` for the occurrence at `time` that counts: the highest SEQUENCE, and on a
    /// tie the later one, as the expansion picks it.
    static func overrideIndex(
        _ calendar: ICalComponent, _ uid: String, _ time: EventTime, _ zones: [String: ZoneRules]
    ) -> Int? {
        var best: (index: Int, sequence: Int)?
        for (index, event) in calendar.components.enumerated() where isOverride(event, uid, time, zones) {
            let sequence = Self.details(event, zones: zones)?.sequence ?? 0
            if best.map({ sequence >= $0.sequence }) ?? true { best = (index, sequence) }
        }
        return best?.index
    }

    /// One occurrence changed: its RECURRENCE-ID event is rewritten, or made from the series event.
    private static func overridden(
        _ calendar: ICalComponent, _ details: EventDetails, at time: EventTime, uid: String, organizer: String
    ) -> ICalComponent {
        let zones = zones(calendar)
        var result = calendar
        if let index = overrideIndex(calendar, uid, time, zones) {
            let event = calendar.components[index]
            let old = Self.details(event, zones: zones)
            // The occurrence changes alone: a range it started carries on from the next occurrence.
            let changed = revised(withoutRange(event), from: old, to: details, organizer: organizer)
            result.components[index] = bumped(changed, old)
            if let carried = carried(calendar, from: time, uid: uid) {
                result.components.insert(carriedOn(event, carried), at: index + 1)
            }
            // The lower SEQUENCEs' copies of the occurrence go, as a delete removes them.
            result.components = result.components.enumerated().filter { position, component in
                position == index || !isOverride(component, uid, time, zones)
            }.map(\.element)
            return withZones(result)
        }
        guard let baseIndex = calendar.components.firstIndex(where: { isBase($0, uid) })
        else { return calendar }
        let base = calendar.components[baseIndex]
        var copy = base
        copy.properties.removeAll { ["RRULE", "RDATE", "EXDATE", "EXRULE"].contains($0.name) }
        copy = copy.replacing("RECURRENCE-ID", with: [ICalValue.property("RECURRENCE-ID", time)])
        let old = Self.details(base, zones: zones)
        copy = bumped(revised(copy, from: old, to: details, organizer: organizer), old)
        let last = calendar.components.lastIndex { isEvent($0, uid) } ?? baseIndex
        result.components.insert(copy, at: last + 1)
        return withZones(result)
    }

    /// One occurrence deleted: an EXDATE on the series event, and its override gone.
    private static func excluded(_ calendar: ICalComponent, _ time: EventTime, uid: String) -> ICalComponent {
        let zones = zones(calendar)
        guard let index = calendar.components.firstIndex(where: { isBase($0, uid) })
        else { return calendar }
        var result = calendar
        var base = calendar.components[index]
        base.properties.append(ICalValue.property("EXDATE", time))
        result.components[index] = bumped(base, Self.details(base, zones: zones))
        // A range the occurrence started carries on from the next occurrence.
        if let carried = carried(calendar, from: time, uid: uid),
            let ranged = overrideIndex(result, uid, time, zones) {
            result.components[ranged] = carriedOn(result.components[ranged], carried)
        }
        result.components.removeAll { isOverride($0, uid, time, zones) }
        return withZones(result)
    }

    /// The range that carries on when the occurrence at `time`, which started it, changes or goes alone.
    private static func carried(_ calendar: ICalComponent, from time: EventTime, uid: String) -> EventOverride? {
        guard let series = series(calendar).first(where: { $0.uid == uid }) else { return nil }
        return Recurrence.rangeAfter(time, in: series, phoneZone: ICalValue.utcZone)
    }

    /// A range's own VEVENT moved on to the occurrence `carried` names, everything else kept.
    private static func carriedOn(_ event: ICalComponent, _ carried: EventOverride) -> ICalComponent {
        var line = ICalValue.property("RECURRENCE-ID", carried.recurrenceID)
        line.parameters.append(ContentParameter(name: "RANGE", values: ["THISANDFUTURE"]))
        var moved = event.replacing("RECURRENCE-ID", with: [line])
            .replacing("DTSTART", with: [ICalValue.property("DTSTART", carried.details.start)])
        if moved.first("DTEND") != nil {
            moved = moved.replacing("DTEND", with: [ICalValue.property("DTEND", carried.details.end)])
        }
        return moved
    }

    private static func withoutRange(_ event: ICalComponent) -> ICalComponent {
        guard var line = event.first("RECURRENCE-ID") else { return event }
        line.parameters.removeAll { $0.name == "RANGE" }
        return event.replacing("RECURRENCE-ID", with: [line])
    }

    /// The series event of `uid`: its VEVENT without RECURRENCE-ID.
    static func isBase(_ component: ICalComponent, _ uid: String) -> Bool {
        isEvent(component, uid) && component.first("RECURRENCE-ID") == nil
    }

    static func isEvent(_ component: ICalComponent, _ uid: String) -> Bool {
        component.name == "VEVENT" && component.first("UID")?.value == uid
    }

    /// The VEVENT of `uid` whose RECURRENCE-ID names `time` (the same instant, or the same value).
    private static func isOverride(
        _ component: ICalComponent, _ uid: String, _ time: EventTime, _ zones: [String: ZoneRules]
    ) -> Bool {
        guard isEvent(component, uid), let line = component.first("RECURRENCE-ID"),
            let held = ICalValue.time(line, zones: zones)
        else { return false }
        if held == time { return true }
        let utc = ICalValue.utcZone
        guard let first = held.instant(in: utc, zones: zones), let second = time.instant(in: utc, zones: zones)
        else { return false }
        return first == second
    }

    private static func bumped(_ event: ICalComponent, _ old: EventDetails?) -> ICalComponent {
        let next = (old?.sequence ?? 0) + 1
        return event.replacing("SEQUENCE", with: [ICalProperty(name: "SEQUENCE", value: String(next))])
    }
}
