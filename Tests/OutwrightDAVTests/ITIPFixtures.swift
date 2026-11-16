// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// Synthetic invitations in the shapes Outlook, Google and Stalwart send.
enum ITIPFixtures {
    static func ics(_ lines: [String]) -> Data {
        Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
    }

    static let me = "me@example.org"
    static let organizer = "org@example.org"

    /// Outlook: Windows zone names and X-MICROSOFT- properties.
    static func outlook(method: String = "REQUEST", sequence: Int = 0, start: String = "20261109T090000",
                        end: String = "20261109T100000", location: String = "Room 1",
                        stamp: String = "20261101T120000Z", ownPartstat: String = "NEEDS-ACTION") -> Data {
        ics([
            "BEGIN:VCALENDAR", "METHOD:\(method)", "PRODID:Microsoft Exchange Server 2010", "VERSION:2.0",
            "BEGIN:VTIMEZONE", "TZID:W. Europe Standard Time",
            "BEGIN:STANDARD", "DTSTART:16010101T030000", "TZOFFSETFROM:+0200", "TZOFFSETTO:+0100",
            "RRULE:FREQ=YEARLY;INTERVAL=1;BYDAY=-1SU;BYMONTH=10", "END:STANDARD",
            "BEGIN:DAYLIGHT", "DTSTART:16010101T020000", "TZOFFSETFROM:+0100", "TZOFFSETTO:+0200",
            "RRULE:FREQ=YEARLY;INTERVAL=1;BYDAY=-1SU;BYMONTH=3", "END:DAYLIGHT",
            "END:VTIMEZONE",
            "BEGIN:VEVENT",
            "ORGANIZER;CN=Org Person:mailto:\(organizer)",
            "ATTENDEE;ROLE=REQ-PARTICIPANT;PARTSTAT=\(ownPartstat);RSVP=TRUE;CN=Me:mailto:\(me)",
            "ATTENDEE;ROLE=OPT-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE;CN=Bo:mailto:bo@example.org",
            "DESCRIPTION;LANGUAGE=en-US:Agenda\\nhttps://example.org/agenda",
            "UID:040000008200E00074C5B7101A82E00800000000outlook1",
            "SUMMARY;LANGUAGE=en-US:Planning",
            "DTSTART;TZID=W. Europe Standard Time:\(start)",
            "DTEND;TZID=W. Europe Standard Time:\(end)",
            "CLASS:PUBLIC", "PRIORITY:5", "DTSTAMP:\(stamp)", "TRANSP:OPAQUE", "STATUS:CONFIRMED",
            "SEQUENCE:\(sequence)", "LOCATION;LANGUAGE=en-US:\(location)",
            "X-MICROSOFT-CDO-APPT-SEQUENCE:\(sequence)", "X-MICROSOFT-CDO-BUSYSTATUS:TENTATIVE",
            "X-MICROSOFT-CDO-IMPORTANCE:1",
            "BEGIN:VALARM", "DESCRIPTION:REMINDER", "TRIGGER;RELATED=START:-PT15M", "ACTION:DISPLAY", "END:VALARM",
            "END:VEVENT", "END:VCALENDAR",
        ])
    }

    /// Google: a weekly series, RSVP=TRUE and quoted CNs.
    static func google(method: String = "REQUEST") -> Data {
        ics([
            "BEGIN:VCALENDAR", "PRODID:-//Google Inc//Google Calendar 70.9054//EN", "VERSION:2.0",
            "CALSCALE:GREGORIAN", "METHOD:\(method)",
            "BEGIN:VEVENT",
            "DTSTART:20261110T080000Z", "DTEND:20261110T083000Z", "RRULE:FREQ=WEEKLY;BYDAY=TU",
            "DTSTAMP:20261101T100000Z",
            "ORGANIZER;CN=\"Org, Person\":mailto:\(organizer)",
            "UID:g1@google.example.org",
            "ATTENDEE;CUTYPE=INDIVIDUAL;ROLE=REQ-PARTICIPANT;PARTSTAT=ACCEPTED;RSVP=TRUE;CN=\"Org, Person\";"
                + "X-NUM-GUESTS=0:mailto:\(organizer)",
            "ATTENDEE;CUTYPE=INDIVIDUAL;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE;CN=\"Me, Myself\";"
                + "X-NUM-GUESTS=0:mailto:\(me)",
            "X-GOOGLE-CONFERENCE:https://meet.example.org/abc",
            "CREATED:20261101T095900Z", "DESCRIPTION:Weekly sync", "LAST-MODIFIED:20261101T100000Z",
            "LOCATION:", "SEQUENCE:0", "STATUS:CONFIRMED", "SUMMARY:Weekly sync", "TRANSP:OPAQUE",
            "END:VEVENT", "END:VCALENDAR",
        ])
    }

    /// Stalwart: SCHEDULE-STATUS on attendees, an IANA zone.
    static func stalwart(method: String = "REQUEST") -> Data {
        ics([
            "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Stalwart Labs LLC//Stalwart Server//EN",
            "METHOD:\(method)",
            "BEGIN:VEVENT", "UID:st1@example.org", "DTSTAMP:20261102T080000Z", "SEQUENCE:2",
            "DTSTART;TZID=Europe/Stockholm:20261112T130000", "DTEND;TZID=Europe/Stockholm:20261112T140000",
            "SUMMARY:Review",
            "ORGANIZER;CN=Org:mailto:\(organizer)",
            "ATTENDEE;PARTSTAT=NEEDS-ACTION;RSVP=TRUE;SCHEDULE-STATUS=1.2:mailto:\(me)",
            "ATTENDEE;PARTSTAT=ACCEPTED;SCHEDULE-STATUS=1.2:mailto:cy@example.org",
            "END:VEVENT", "END:VCALENDAR",
        ])
    }

    /// A reply from `attendee` to the Outlook meeting.
    static func reply(from attendee: String = "bo@example.org", partstat: String = "ACCEPTED",
                      extraAttendee: Bool = false) -> Data {
        var lines = [
            "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Example//Example//EN", "METHOD:REPLY",
            "BEGIN:VEVENT", "UID:040000008200E00074C5B7101A82E00800000000outlook1", "SEQUENCE:0",
            "DTSTAMP:20261103T080000Z", "ORGANIZER:mailto:\(me)",
            "ATTENDEE;PARTSTAT=\(partstat):mailto:\(attendee)",
        ]
        if extraAttendee { lines.append("ATTENDEE;PARTSTAT=DECLINED:mailto:other@example.org") }
        lines += ["END:VEVENT", "END:VCALENDAR"]
        return ics(lines)
    }

    /// A cancellation of the Google series, or of one of its occurrences.
    static func googleCancel(recurrenceID: String?) -> Data {
        var lines = [
            "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Example//Example//EN", "METHOD:CANCEL",
            "BEGIN:VEVENT", "UID:g1@google.example.org", "SEQUENCE:1", "DTSTAMP:20261104T080000Z",
            "ORGANIZER:mailto:\(organizer)", "ATTENDEE:mailto:\(me)", "STATUS:CANCELLED",
        ]
        if let recurrenceID { lines.append("RECURRENCE-ID:\(recurrenceID)") }
        lines += ["END:VEVENT", "END:VCALENDAR"]
        return ics(lines)
    }
}
