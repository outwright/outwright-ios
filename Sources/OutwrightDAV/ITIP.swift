// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation

/// The iTIP methods (RFC 5546) Outwright acts on; any other is an ordinary attachment.
public enum ITIPMethod: String, Sendable, Codable {
    case request = "REQUEST", add = "ADD", cancel = "CANCEL", reply = "REPLY"
}

/// An iTIP message as read from the calendar part of a mail. Everything in it came from the sender.
public struct ITIPMessage: Sendable, Equatable {
    public var method: ITIPMethod
    public var uid: String
    /// The RECURRENCE-ID as given: the message is about one occurrence. Nil when it holds the series.
    public var recurrenceID: ICalProperty?
    public var sequence: Int
    /// The ORGANIZER's address, lower-cased, without `mailto:`.
    public var organizer: String?
    /// The ATTENDEEs, addresses as `organizer`, PARTSTAT upper-cased (NEEDS-ACTION when absent).
    public var attendees: [(email: String, partstat: String)]
    /// The whole VCALENDAR.
    public var calendar: ICalComponent

    public init(method: ITIPMethod, uid: String, recurrenceID: ICalProperty?, sequence: Int, organizer: String?,
                attendees: [(email: String, partstat: String)], calendar: ICalComponent) {
        self.method = method
        self.uid = uid
        self.recurrenceID = recurrenceID
        self.sequence = sequence
        self.organizer = organizer
        self.attendees = attendees
        self.calendar = calendar
    }

    public static func == (lhs: ITIPMessage, rhs: ITIPMessage) -> Bool {
        lhs.method == rhs.method && lhs.uid == rhs.uid && lhs.recurrenceID == rhs.recurrenceID
            && lhs.sequence == rhs.sequence && lhs.organizer == rhs.organizer && lhs.calendar == rhs.calendar
            && lhs.attendees.elementsEqual(rhs.attendees) { $0.email == $1.email && $0.partstat == $1.partstat }
    }
}

/// iTIP (RFC 5546) on the iCalendar tree: reading a message, who may apply it, applying it to the
/// stored copy, the owner's answer and the REPLY. Pure: no I/O, no model.
public enum ITIP {
    static let prodID = "-//Outwright//Outwright//EN"

    /// The iTIP message in `data`; nil when it is unreadable, has no VEVENT, a VEVENT without a UID
    /// or VEVENTs of more than one UID, or a METHOD other than the four. The VCALENDAR's METHOD wins
    /// over `method` (the Content-Type's).
    public static func read(_ data: Data, method: String) -> ITIPMessage? {
        guard let calendar = try? ICalendarReader.calendar(data) else { return nil }
        let named = token(calendar.first("METHOD")?.value ?? "")
        guard let kind = ITIPMethod(rawValue: named.isEmpty ? token(method) : named) else { return nil }
        let vevents = events(calendar)
        let uids = vevents.map { ($0.first("UID")?.value ?? "").trimmingCharacters(in: .whitespaces) }
        guard let uid = uids.first, !uid.isEmpty, uids.allSatisfy({ $0 == uid }),
              let primary = seriesEvent(calendar) ?? vevents.first
        else { return nil }
        let organizer = primary.first("ORGANIZER").map { address($0.value) }.flatMap { $0.isEmpty ? nil : $0 }
        let attendees = primary.all("ATTENDEE").map {
            (email: address($0.value), partstat: token($0.parameter("PARTSTAT") ?? "NEEDS-ACTION"))
        }
        return ITIPMessage(method: kind, uid: uid, recurrenceID: primary.first("RECURRENCE-ID"),
                           sequence: sequence(primary), organizer: organizer, attendees: attendees,
                           calendar: calendar)
    }

    /// A REQUEST, ADD or CANCEL only from its ORGANIZER; a REPLY only from its one ATTENDEE.
    public static func senderMayApply(_ message: ITIPMessage, from sender: String) -> Bool {
        let from = address(sender)
        guard !from.isEmpty else { return false }
        switch message.method {
        case .request, .add, .cancel:
            return message.organizer == from
        case .reply:
            let everyone = Set(events(message.calendar).flatMap { $0.all("ATTENDEE") }.map { address($0.value) })
            return message.attendees.count == 1 && everyone == [from]
        }
    }

    /// Newer than the stored copy of the same occurrence (or of the series): a greater SEQUENCE, or
    /// the same one with a later DTSTAMP.
    public static func isNewer(_ message: ITIPMessage, than stored: ICalComponent) -> Bool {
        let wanted = key(message.recurrenceID)
        guard let old = events(stored).first(where: { key($0.first("RECURRENCE-ID")) == wanted }) ?? seriesEvent(stored)
        else { return true }
        let current = sequence(old)
        guard message.sequence == current else { return message.sequence > current }
        guard let incoming = seriesEvent(message.calendar) ?? events(message.calendar).first,
              let new = incoming.first("DTSTAMP").flatMap({ ICalTime.parse($0.value) }),
              let before = old.first("DTSTAMP").flatMap({ ICalTime.parse($0.value) })
        else { return false }
        return new.date > before.date
    }

    /// The copy says the client handles its scheduling messages: `SCHEDULE-AGENT=CLIENT` on an
    /// ORGANIZER (RFC 6638 › 7.1). Otherwise a server that schedules sends the owner's replies.
    public static func repliesByClient(_ calendar: ICalComponent) -> Bool {
        events(calendar).contains { event in
            event.all("ORGANIZER").contains { $0.parameter("SCHEDULE-AGENT")?.uppercased() == "CLIENT" }
        }
    }

    /// `SCHEDULE-AGENT=CLIENT` on every ORGANIZER (RFC 6638 › 7.1): the server sends nothing for it.
    public static func settingScheduleAgentClient(_ calendar: ICalComponent) -> ICalComponent {
        scheduleAgentClient(calendar, depth: 0)
    }

    private static func scheduleAgentClient(_ component: ICalComponent, depth: Int) -> ICalComponent {
        guard depth < DAVLimits.componentDepth * 2 else { return component }
        var result = component
        let organizers = component.all("ORGANIZER")
        if !organizers.isEmpty {
            result = result.replacing("ORGANIZER", with: organizers.map { organizer in
                var line = organizer
                line.parameters = line.parameters.filter { $0.name != "SCHEDULE-AGENT" }
                    + [ContentParameter(name: "SCHEDULE-AGENT", values: ["CLIENT"])]
                return line
            })
        }
        result.components = component.components.map { scheduleAgentClient($0, depth: depth + 1) }
        return result
    }

    /// The iMIP REPLY (RFC 6047) for the owner's answer, built from the stored copy: the occurrence
    /// for `recurrenceID` (or the series), with only the owner's ATTENDEE. An answer for the whole
    /// series also carries one VEVENT per override the copy holds (RFC 5546 › 3.2.3), the owner's
    /// answer on each, so the organiser's per-occurrence answers follow it. Nil when that VEVENT has
    /// no ORGANIZER or no ATTENDEE for `ownEmail`. A `comment` is each VEVENT's COMMENT (RFC 5546 ›
    /// 3.2.3 allows one in a REPLY), on one line: CR, LF and NUL never reach the property.
    public static func reply(from calendar: ICalComponent, ownEmail: String, partstat: String,
                             recurrenceID: ICalProperty?, now: Date, comment: String? = nil) -> ICalComponent? {
        let answer = token(partstat)
        let note = comment.map(oneLine).flatMap { $0.isEmpty ? nil : $0 }
        guard !answer.isEmpty, let source = replySource(calendar, recurrenceID: recurrenceID),
              let organizer = source.first("ORGANIZER"),
              let main = replyEvent(source, organizer: organizer, ownEmail: ownEmail, answer: (answer, note), now: now)
        else { return nil }
        var replied = [main]
        if recurrenceID == nil, source.first("RECURRENCE-ID") == nil {
            let uid = source.first("UID")?.value
            replied += events(calendar).filter { $0.first("RECURRENCE-ID") != nil && $0.first("UID")?.value == uid }
                .prefix(DAVLimits.componentsPerResource)
                .compactMap {
                    replyEvent($0, organizer: organizer, ownEmail: ownEmail, answer: (answer, note), now: now)
                }
        }
        let used = Set(replied.flatMap(\.properties).compactMap { $0.parameter("TZID") })
        let zones = calendar.components.filter {
            $0.name == "VTIMEZONE" && $0.first("TZID").map { used.contains($0.value) } == true
        }
        let header = [
            ICalProperty(name: "VERSION", value: "2.0"), ICalProperty(name: "PRODID", value: prodID),
            ICalProperty(name: "METHOD", value: ITIPMethod.reply.rawValue)
        ]
        return ICalComponent(name: "VCALENDAR", properties: header, components: zones + replied)
    }

    /// One VEVENT of a REPLY: `source`'s identity and time, its ORGANIZER (else `organizer`), the
    /// owner's ATTENDEE at the answer's PARTSTAT and its comment. Nil when `source` has no ATTENDEE for
    /// `ownEmail`.
    private static func replyEvent(
        _ source: ICalComponent, organizer: ICalProperty, ownEmail: String,
        answer: (partstat: String, comment: String?), now: Date
    ) -> ICalComponent? {
        guard let own = source.all("ATTENDEE").first(where: { isOwn($0, ownEmail) }) else { return nil }
        var properties: [ICalProperty] = []
        properties += source.all("UID").prefix(1)
        properties += source.all("RECURRENCE-ID").prefix(1)
        properties.append(ICalProperty(name: "SEQUENCE", value: String(sequence(source))))
        properties.append(ICalProperty(name: "DTSTAMP", value: ICalTime.format(now, form: .utc)))
        properties += source.all("DTSTART").prefix(1)
        let end = source.all("DTEND").prefix(1)
        properties += end.isEmpty ? Array(source.all("DURATION").prefix(1)) : Array(end)
        properties += source.all("SUMMARY").prefix(1)
        properties.append(withoutScheduling(source.first("ORGANIZER") ?? organizer))
        var attendee = withoutScheduling(own)
        attendee.parameters = attendee.parameters.filter { $0.name != "PARTSTAT" && $0.name != "RSVP" }
            + [ContentParameter(name: "PARTSTAT", values: [answer.partstat])]
        properties.append(attendee)
        if let comment = answer.comment { properties.append(ICalProperty(name: "COMMENT", text: comment)) }
        return ICalComponent(name: "VEVENT", properties: properties)
    }

    /// The VEVENT a REPLY answers for: the override, or the occurrence made from the series.
    private static func replySource(_ calendar: ICalComponent, recurrenceID: ICalProperty?) -> ICalComponent? {
        guard let recurrenceID else { return seriesEvent(calendar) ?? events(calendar).first }
        let wanted = key(recurrenceID)
        if let override = events(calendar).first(where: { key($0.first("RECURRENCE-ID")) == wanted }) {
            return override
        }
        return seriesEvent(calendar).map { occurrence(of: $0, at: recurrenceID) }
    }

    /// The SCHEDULE- parameters are a CalDAV server's (RFC 6638); iMIP carries none.
    static func withoutScheduling(_ property: ICalProperty) -> ICalProperty {
        var line = property
        line.parameters = line.parameters.filter { !$0.name.hasPrefix("SCHEDULE-") }
        return line
    }

    // MARK: - Pieces

    /// The longest token kept (a METHOD or a PARTSTAT is a word).
    private static let maxToken = 64

    /// Upper-cased letters, digits and `-`, at most `maxToken`.
    static func token(_ value: String) -> String {
        let kept = value.uppercased().unicodeScalars.filter {
            ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "-"
        }.prefix(maxToken)
        return String(String.UnicodeScalarView(kept))
    }

    /// The text on one line: CR and LF become spaces, NUL goes; trimmed.
    static func oneLine(_ text: String) -> String {
        let scalars = text.unicodeScalars.compactMap { scalar -> Unicode.Scalar? in
            switch scalar {
            case "\0": nil
            case "\r", "\n": " "
            default: scalar
            }
        }
        return String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
    }

    /// A CAL-ADDRESS as an address: without `mailto:`, lower-cased.
    static func address(_ value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespaces)
        if text.lowercased().hasPrefix("mailto:") { text = String(text.dropFirst("mailto:".count)) }
        return text.trimmingCharacters(in: .whitespaces).lowercased()
    }

    static func isOwn(_ attendee: ICalProperty, _ ownEmail: String) -> Bool {
        let own = address(ownEmail)
        return !own.isEmpty && address(attendee.value) == own
    }

    static func events(_ calendar: ICalComponent) -> [ICalComponent] {
        calendar.components.filter { $0.name == "VEVENT" }
    }

    /// The VEVENT without RECURRENCE-ID: the series, or the single event.
    static func seriesEvent(_ calendar: ICalComponent) -> ICalComponent? {
        events(calendar).first { $0.first("RECURRENCE-ID") == nil }
    }

    /// What RECURRENCE-IDs are matched on: the value, trimmed and upper-cased.
    static func key(_ recurrenceID: ICalProperty?) -> String? {
        recurrenceID.map { $0.value.trimmingCharacters(in: .whitespaces).uppercased() }
    }

    /// SEQUENCE, 0 when absent or unreadable, never negative.
    static func sequence(_ event: ICalComponent) -> Int {
        let text = (event.first("SEQUENCE")?.value ?? "").trimmingCharacters(in: .whitespaces)
        return min(max(Int(text.prefix(20)) ?? 0, 0), Int(Int32.max))
    }
}
