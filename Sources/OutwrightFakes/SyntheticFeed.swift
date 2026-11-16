// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation

/// A published calendar made in tests, shaped like the file Microsoft 365 publishes: one VCALENDAR,
/// Windows time zone names with their VTIMEZONE, Microsoft's own properties. Synthetic data only.
public enum SyntheticFeed {
    public static let zone = "W. Europe Standard Time"

    /// Fridays 09:00 W. Europe from 2026-10-02 to the end of 2026, across the October change.
    public static let standup = event([
        "UID:s1", "DTSTAMP:20260901T000000Z", "DTSTART;TZID=\(zone):20261002T090000",
        "DTEND;TZID=\(zone):20261002T093000", "RRULE:FREQ=WEEKLY;UNTIL=20261231T080000Z;INTERVAL=1;BYDAY=FR;WKST=MO",
        "EXDATE;TZID=\(zone):20261016T090000", "SUMMARY:Standup", "X-MICROSOFT-CDO-BUSYSTATUS:BUSY"
    ])
    /// The 2026-11-06 standup moved to 13:00.
    public static let standupMoved = event([
        "UID:s1", "DTSTAMP:20260901T000000Z", "RECURRENCE-ID;TZID=\(zone):20261106T090000",
        "DTSTART;TZID=\(zone):20261106T130000", "DTEND;TZID=\(zone):20261106T133000", "SUMMARY:Standup moved"
    ])
    /// 2026-11-10 10:00 W. Europe, with an alarm.
    public static let review = event(
        [
            "UID:e1", "DTSTAMP:20260901T000000Z", "DTSTART;TZID=\(zone):20261110T100000",
            "DTEND;TZID=\(zone):20261110T110000", "SUMMARY:Review", "LOCATION:Room 2"
        ], inner: ["BEGIN:VALARM", "ACTION:DISPLAY", "TRIGGER:-PT15M", "END:VALARM"])
    /// All day on 2026-11-20.
    public static let conference = event([
        "UID:d1", "DTSTAMP:20260901T000000Z", "DTSTART;VALUE=DATE:20261120", "DTEND;VALUE=DATE:20261121",
        "SUMMARY:Conference", "TRANSP:TRANSPARENT"
    ])
    public static let todo = ["BEGIN:VTODO", "UID:t1", "SUMMARY:Task", "END:VTODO"].joined(separator: "\r\n")
    public static let noUID = event(["DTSTAMP:20260901T000000Z", "DTSTART:20261111T100000Z", "SUMMARY:Broken"])

    /// The whole file: every piece above.
    public static var work: Data { feed([standup, standupMoved, review, conference, todo, noUID]) }

    /// A VEVENT of these lines.
    public static func event(_ lines: [String], inner: [String] = []) -> String {
        (["BEGIN:VEVENT"] + lines + inner + ["END:VEVENT"]).joined(separator: "\r\n")
    }

    /// A published file of these components, with the zone's VTIMEZONE.
    public static func feed(_ components: [String], name: String = "Work") -> Data {
        let head = [
            "BEGIN:VCALENDAR", "METHOD:PUBLISH", "PRODID:Microsoft Exchange Server 2010", "VERSION:2.0",
            "X-WR-CALNAME:\(name)", "BEGIN:VTIMEZONE", "TZID:\(zone)", "BEGIN:STANDARD", "DTSTART:16010101T030000",
            "TZOFFSETFROM:+0200", "TZOFFSETTO:+0100", "RRULE:FREQ=YEARLY;INTERVAL=1;BYDAY=-1SU;BYMONTH=10",
            "END:STANDARD", "BEGIN:DAYLIGHT", "DTSTART:16010101T020000", "TZOFFSETFROM:+0100", "TZOFFSETTO:+0200",
            "RRULE:FREQ=YEARLY;INTERVAL=1;BYDAY=-1SU;BYMONTH=3", "END:DAYLIGHT", "END:VTIMEZONE"
        ]
        let lines = head + components + ["END:VCALENDAR"]
        return Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
    }

    /// `count` one-hour events, `n<i>` each, from 2026-11-01 on.
    public static func many(_ count: Int) -> Data {
        feed(
            (0..<count).map { index in
                event(["UID:n\(index)", "DTSTAMP:20260901T000000Z", "DTSTART:20261101T100000Z", "SUMMARY:n\(index)"])
            })
    }
}
