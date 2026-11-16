// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation

/// The organiser's side of iTIP (RFC 5546): who the app mails when the owner's own meeting changes,
/// and the REQUEST and CANCEL it mails them (iMIP, RFC 6047).
extension ITIP {
    /// The most guests one meeting's mail goes to.
    static let maxMailed = 500

    /// The guests the app mails for the owner's meeting: every ATTENDEE but the owner, once, across
    /// the meeting's VEVENTs, when the ORGANIZER is `ownEmail`. A server that schedules (RFC 6638 › 2)
    /// mails those it handles itself, so then only the ones whose `SCHEDULE-AGENT` is `CLIENT`
    /// (› 7.1); one whose `SCHEDULE-AGENT` is `NONE` is mailed by nobody. Addresses lower-cased,
    /// without `mailto:`; empty for a meeting someone else organises.
    public static func mailedAttendees(_ calendar: ICalComponent, ownEmail: String, serverSchedules: Bool)
        -> [String] {
        guard let lead = seriesEvent(calendar) ?? events(calendar).first,
              let organizer = lead.first("ORGANIZER"), address(organizer.value) == address(ownEmail)
        else { return [] }
        var seen: Set<String> = []
        var mailed: [String] = []
        for attendee in events(calendar).flatMap({ $0.all("ATTENDEE") }) where mailed.count < maxMailed {
            let email = address(attendee.value)
            guard !email.isEmpty, !isOwn(attendee, ownEmail), seen.insert(email).inserted else { continue }
            switch attendee.parameter("SCHEDULE-AGENT")?.uppercased() {
            case "NONE":
                continue
            case "CLIENT":
                mailed.append(email)
            default:
                if !serverSchedules { mailed.append(email) }
            }
        }
        return mailed
    }

    /// The REQUESTs for the owner's meeting as it now is, to `guests` (addresses): each guest is sent
    /// the VEVENTs that list them (the series, its overrides, or one occurrence alone, RFC 5546
    /// › 3.2.2), so guests listed on the same ones share one REQUEST. Stamped `now`, with the zones the
    /// VEVENTs use; nothing of the owner's own goes: no alarms, no X- properties or parameters, no
    /// CalDAV server's SCHEDULE- parameters. Empty for a meeting without ORGANIZER.
    public static func requests(from calendar: ICalComponent, guests: [String], now: Date)
        -> [(guests: [String], calendar: ICalComponent)] {
        guard let lead = seriesEvent(calendar) ?? events(calendar).first, lead.first("ORGANIZER") != nil,
              let uid = lead.first("UID")?.value
        else { return [] }
        let stamp = ICalProperty(name: "DTSTAMP", value: ICalTime.format(now, form: .utc))
        let meeting = Array(events(calendar).filter { $0.first("UID")?.value == uid }
            .prefix(DAVLimits.componentsPerResource))
        var groups: [(indices: [Int], guests: [String])] = []
        for guest in guests.map(address) where !guest.isEmpty {
            let indices = meeting.indices.filter { lists(meeting[$0], guest) }
            guard !indices.isEmpty else { continue }
            if let group = groups.firstIndex(where: { $0.indices == indices }) {
                groups[group].guests.append(guest)
            } else {
                groups.append((indices, [guest]))
            }
        }
        return groups.map { group in
            let sent = group.indices.map { index in
                var event = shared(meeting[index]).replacing("DTSTAMP", with: [stamp])
                event.components = []
                return event
            }
            return (group.guests, message(.request, events: sent, zonesFrom: calendar))
        }
    }

    /// The CANCELs of single occurrences (RFC 5546 › 3.2.5): a guest of the series that an override
    /// no longer lists is told that occurrence is off for them, with its RECURRENCE-ID and SEQUENCE.
    /// One per override, to every such guest among `guests`.
    public static func occurrenceCancels(from calendar: ICalComponent, guests: [String], now: Date)
        -> [(guests: [String], calendar: ICalComponent)] {
        guard let series = seriesEvent(calendar), let organizer = series.first("ORGANIZER"),
              let uid = series.first("UID")?.value
        else { return [] }
        let invited = guests.map(address).filter { lists(series, $0) }
        let overrides = events(calendar).filter { $0.first("UID")?.value == uid && $0.first("RECURRENCE-ID") != nil }
            .prefix(DAVLimits.componentsPerResource)
        return overrides.compactMap { override in
            let off = invited.filter { !lists(override, $0) }
            guard !off.isEmpty else { return nil }
            let event = cancelled(
                override, organizer: organizer, attendees: off, sequence: sequence(override), now: now)
            return (off, message(.cancel, events: [event], zonesFrom: calendar))
        }
    }

    /// The CANCEL of the owner's whole meeting for `attendees` (addresses): the series' identity and
    /// time, `STATUS:CANCELLED`, only those ATTENDEEs. `raisingSequence`: SEQUENCE one past the one
    /// `calendar` holds, as a cancellation is a revision of its own (the sync builds it from the
    /// meeting as it was before the change that cancels). Nil for no one, or a meeting without
    /// ORGANIZER.
    public static func cancel(
        from calendar: ICalComponent, attendees: [String], raisingSequence: Bool, now: Date
    ) -> ICalComponent? {
        let named = Array(attendees.map(address).filter { !$0.isEmpty }.prefix(maxMailed))
        guard !named.isEmpty, let lead = seriesEvent(calendar) ?? events(calendar).first,
              let organizer = lead.first("ORGANIZER")
        else { return nil }
        let sequence = min(sequence(lead) + (raisingSequence ? 1 : 0), Int(Int32.max))
        let event = cancelled(lead, organizer: organizer, attendees: named, sequence: sequence, now: now)
        return message(.cancel, events: [event], zonesFrom: calendar)
    }

    /// A cancelled VEVENT for `source`: its identity and time, `STATUS:CANCELLED`, the ORGANIZER and
    /// only the ATTENDEEs named (as `source` lists them, else made from the address).
    private static func cancelled(
        _ source: ICalComponent, organizer: ICalProperty, attendees: [String], sequence: Int, now: Date
    ) -> ICalComponent {
        let held = source.all("ATTENDEE")
        var properties: [ICalProperty] = []
        properties += source.all("UID").prefix(1)
        properties += source.all("RECURRENCE-ID").prefix(1).map(shared)
        properties.append(ICalProperty(name: "SEQUENCE", value: String(sequence)))
        properties.append(ICalProperty(name: "DTSTAMP", value: ICalTime.format(now, form: .utc)))
        properties += source.all("DTSTART").prefix(1).map(shared)
        let end = source.all("DTEND").prefix(1)
        properties += (end.isEmpty ? Array(source.all("DURATION").prefix(1)) : Array(end)).map(shared)
        properties += source.all("RRULE").prefix(1)
        properties += source.all("SUMMARY").prefix(1).map(shared)
        properties.append(ICalProperty(name: "STATUS", value: "CANCELLED"))
        properties.append(shared(source.first("ORGANIZER") ?? organizer))
        properties += attendees.map { email in
            held.first { address($0.value) == email }.map(shared)
                ?? ICalProperty(name: "ATTENDEE", value: "mailto:" + email)
        }
        return ICalComponent(name: "VEVENT", properties: properties)
    }

    /// `event` lists `guest` (an address) as an ATTENDEE.
    private static func lists(_ event: ICalComponent, _ guest: String) -> Bool {
        event.all("ATTENDEE").contains { address($0.value) == guest }
    }

    /// What of the owner's meeting a guest is sent: no X- properties, and no X- or SCHEDULE-
    /// parameters (a CalDAV server's, RFC 6638), on a VEVENT or one property.
    private static func shared(_ event: ICalComponent) -> ICalComponent {
        var event = event
        event.properties = event.properties.filter { !$0.name.uppercased().hasPrefix("X-") }.map(shared)
        return event
    }

    private static func shared(_ property: ICalProperty) -> ICalProperty {
        var line = withoutScheduling(property)
        line.parameters = line.parameters.filter { !$0.name.uppercased().hasPrefix("X-") }
        return line
    }

    /// When the message was made: the DTSTAMP of its series VEVENT (or its first); nil when unreadable.
    /// Of two messages of one SEQUENCE the later stamp is the newer (RFC 5546 › 2.1.5).
    public static func stamp(_ message: ITIPMessage) -> Date? {
        (seriesEvent(message.calendar) ?? events(message.calendar).first)?.first("DTSTAMP")
            .flatMap { ICalTime.parse($0.value)?.date }
    }

    /// A VCALENDAR of `method` holding `events` and the zones of `calendar` they use.
    private static func message(_ method: ITIPMethod, events: [ICalComponent], zonesFrom calendar: ICalComponent)
        -> ICalComponent {
        let used = Set(events.flatMap(\.properties).compactMap { $0.parameter("TZID") })
        let zones = calendar.components.filter {
            $0.name == "VTIMEZONE" && $0.first("TZID").map { used.contains($0.value) } == true
        }
        let header = [
            ICalProperty(name: "VERSION", value: "2.0"), ICalProperty(name: "PRODID", value: prodID),
            ICalProperty(name: "METHOD", value: method.rawValue)
        ]
        return ICalComponent(name: "VCALENDAR", properties: header, components: zones + events)
    }
}
