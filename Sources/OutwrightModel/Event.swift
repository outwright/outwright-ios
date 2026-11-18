// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation

public enum EventStatus: Sendable, Equatable, Codable { case confirmed, tentative, cancelled }

/// How the event shows the owner's time to others: TRANSP (RFC 5545 › 3.8.2.7) holds busy or free, and
/// the X-MICROSOFT-CDO-BUSYSTATUS property, where present, tentative and away too.
public enum ShowAs: String, Sendable, Equatable, Codable, CaseIterable { case busy, free, tentative, away }

public struct Attendee: Sendable, Equatable, Codable {
    /// PARTSTAT.
    public enum Response: Sendable, Equatable, Codable { case needsAction, accepted, tentative, declined, delegated }

    public var email: String
    /// CN.
    public var name: String
    public var response: Response
    /// ROLE, "REQ-PARTICIPANT" when absent.
    public var role: String
    public var rsvp: Bool

    public init(email: String, name: String = "", response: Response = .needsAction,
                role: String = "REQ-PARTICIPANT", rsvp: Bool = false) {
        self.email = email
        self.name = name
        self.response = response
        self.role = role
        self.rsvp = rsvp
    }
}

/// What one event (the series event or one overridden occurrence) says.
public struct EventDetails: Sendable, Equatable, Codable {
    public var title: String
    public var place: String
    public var notes: String
    public var start: EventTime
    public var end: EventTime
    /// Minutes before the start; nil for none.
    public var reminder: Int?
    public var attendees: [Attendee]
    /// The organizer's email.
    public var organizer: String?
    public var status: EventStatus
    public var showAs: ShowAs
    /// CLASS:PRIVATE (or CONFIDENTIAL): others who can see the calendar see only that the time is taken.
    public var isPrivate: Bool
    /// SEQUENCE, 0 when absent.
    public var sequence: Int

    public init(title: String, place: String = "", notes: String = "", start: EventTime, end: EventTime,
                reminder: Int? = nil, attendees: [Attendee] = [], organizer: String? = nil,
                status: EventStatus = .confirmed, showAs: ShowAs = .busy, isPrivate: Bool = false,
                sequence: Int = 0) {
        self.title = title
        self.place = place
        self.notes = notes
        self.start = start
        self.end = end
        self.reminder = reminder
        self.attendees = attendees
        self.organizer = organizer
        self.status = status
        self.showAs = showAs
        self.isPrivate = isPrivate
        self.sequence = sequence
    }

    private enum CodingKeys: String, CodingKey {
        case title, place, notes, start, end, reminder, attendees, organizer, status, showAs, isPrivate, sequence
    }

    /// The key details saved before Show as had: busy or free.
    private enum LegacyKeys: String, CodingKey { case transparency }

    /// Saved details from before Show as and Private read as busy (free when they said so) and not private.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        place = try container.decode(String.self, forKey: .place)
        notes = try container.decode(String.self, forKey: .notes)
        start = try container.decode(EventTime.self, forKey: .start)
        end = try container.decode(EventTime.self, forKey: .end)
        reminder = try container.decodeIfPresent(Int.self, forKey: .reminder)
        attendees = try container.decode([Attendee].self, forKey: .attendees)
        organizer = try container.decodeIfPresent(String.self, forKey: .organizer)
        status = try container.decode(EventStatus.self, forKey: .status)
        sequence = try container.decode(Int.self, forKey: .sequence)
        isPrivate = (try? container.decodeIfPresent(Bool.self, forKey: .isPrivate)) ?? false
        if let showAs = try? container.decodeIfPresent(ShowAs.self, forKey: .showAs) {
            self.showAs = showAs
        } else {
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            let old = try? legacy.nestedContainer(keyedBy: LegacyFree.self, forKey: .transparency)
            showAs = old?.contains(.free) == true ? .free : .busy
        }
    }

    /// How the old two-case enum was saved: `{"free":{}}` or `{"busy":{}}`.
    private enum LegacyFree: String, CodingKey { case free }
}

extension EventDetails {
    /// A range's (RANGE=THISANDFUTURE) details after the series event changed from `old` to `new`: each
    /// title, place, notes, reminder, people, show as and privacy the series changed and the range had
    /// as the series did is the series' new one; what the range changed on purpose stays. The store and
    /// the writer both ask it, so the server gets what the phone shows.
    public func following(seriesFrom old: EventDetails, to new: EventDetails) -> EventDetails {
        var next = self
        func take<Field: Equatable>(_ path: WritableKeyPath<EventDetails, Field>) {
            if old[keyPath: path] != new[keyPath: path], self[keyPath: path] == old[keyPath: path] {
                next[keyPath: path] = new[keyPath: path]
            }
        }
        take(\.title)
        take(\.place)
        take(\.notes)
        take(\.reminder)
        take(\.attendees)
        take(\.showAs)
        take(\.isPrivate)
        return next
    }
}

/// The one rule for who owns an event; the store, the mapping and the views all ask it.
public enum EventOwnership {
    /// True when the event has no organizer, or the account is the organizer.
    public static func isOrganizer(_ details: EventDetails, accountEmail: String) -> Bool {
        guard let organizer = details.organizer else { return true }
        return sameAddress(organizer, accountEmail)
    }

    /// The attendee line that is the account's own.
    public static func ownAttendee(_ details: EventDetails, accountEmail: String) -> Attendee? {
        details.attendees.first { sameAddress($0.email, accountEmail) }
    }

    /// Tentative when the event says so, the account answered tentatively, or the account was
    /// invited by someone else and has not answered yet.
    public static func isTentative(_ details: EventDetails, accountEmail: String) -> Bool {
        let response = ownAttendee(details, accountEmail: accountEmail)?.response
        return details.status == .tentative || response == .tentative
            || (response == .needsAction && !isOrganizer(details, accountEmail: accountEmail))
    }

    /// Someone else organizes it and the account is one of its attendees: the owner may answer it
    /// and keep an own reminder, nothing else.
    public static func isInvitation(_ details: EventDetails, accountEmail: String) -> Bool {
        !isOrganizer(details, accountEmail: accountEmail) && ownAttendee(details, accountEmail: accountEmail) != nil
    }

    /// The details with the account's own answer set (its RSVP request answered); unchanged when the
    /// account is not an attendee.
    public static func answering(_ details: EventDetails, _ response: Attendee.Response, accountEmail: String)
        -> EventDetails {
        var next = details
        for index in next.attendees.indices where sameAddress(next.attendees[index].email, accountEmail) {
            next.attendees[index].response = response
            next.attendees[index].rsvp = false
        }
        return next
    }

    private static func sameAddress(_ lhs: String, _ rhs: String) -> Bool {
        lhs.lowercased() == rhs.lowercased()
    }
}

/// One overridden occurrence: a VEVENT with a RECURRENCE-ID.
public struct EventOverride: Sendable, Equatable, Codable {
    public var recurrenceID: EventTime
    public var details: EventDetails
    /// RANGE=THISANDFUTURE: the override also moves and rewrites every later occurrence of the series.
    public var thisAndFuture: Bool

    public init(recurrenceID: EventTime, details: EventDetails, thisAndFuture: Bool = false) {
        self.recurrenceID = recurrenceID
        self.details = details
        self.thisAndFuture = thisAndFuture
    }

    private enum CodingKeys: String, CodingKey { case recurrenceID, details, thisAndFuture }

    /// Saved data from before ranges, or with an unreadable range, is an override of its own occurrence.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        recurrenceID = try container.decode(EventTime.self, forKey: .recurrenceID)
        details = try container.decode(EventDetails.self, forKey: .details)
        thisAndFuture = (try? container.decodeIfPresent(Bool.self, forKey: .thisAndFuture)) ?? false
    }
}

/// A recurring event (or a single one) as its calendar object holds it.
public struct EventSeries: Sendable, Equatable {
    public var uid: String
    /// The VEVENT without RECURRENCE-ID; nil when only overridden occurrences were shared (an invitation
    /// to one occurrence).
    public var base: EventDetails?
    public var rule: RecurrenceRule?
    public var rdates: [EventTime]
    public var exdates: [EventTime]
    public var overrides: [EventOverride]
    /// The calendar object's VTIMEZONEs by TZID.
    public var zones: [String: ZoneRules]

    public init(uid: String, base: EventDetails?, rule: RecurrenceRule? = nil, rdates: [EventTime] = [],
                exdates: [EventTime] = [], overrides: [EventOverride] = [],
                zones: [String: ZoneRules] = [:]) {
        self.uid = uid
        self.base = base
        self.rule = rule
        self.rdates = rdates
        self.exdates = exdates
        self.overrides = overrides
        self.zones = zones
    }
}

/// One occurrence of a series inside a window.
public struct Occurrence: Sendable, Equatable {
    /// Nil for an event that does not recur.
    public var recurrenceID: EventTime?
    /// The series event's details, or the override's; `start` and `end` below are this occurrence's own times.
    public var details: EventDetails
    public var start: Date
    public var end: Date
    /// yyyymmdd for an all-day occurrence; the end is exclusive.
    public var allDayStart: Int?
    public var allDayEnd: Int?

    public init(recurrenceID: EventTime?, details: EventDetails, start: Date, end: Date,
                allDayStart: Int? = nil, allDayEnd: Int? = nil) {
        self.recurrenceID = recurrenceID
        self.details = details
        self.start = start
        self.end = end
        self.allDayStart = allDayStart
        self.allDayEnd = allDayEnd
    }
}
