// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
public import OutwrightDAV

/// Who sends the organiser the owner's answer to an invitation, as RFC 6638 decides it. A server
/// that schedules (it says `calendar-auto-schedule`, › 2) sends the iMIP REPLY when the owner's
/// PARTSTAT changes (› 3.2.2.3), unless the ORGANIZER of the owner's copy says
/// `SCHEDULE-AGENT=CLIENT` (› 7.1); then, and with a server that does not schedule, the app mails it.
/// Never both.
public enum ReplyRoute: Sendable, Equatable {
    case server, app

    /// `.server` when the server schedules and the copy leaves it to, else `.app`.
    public static func route(_ calendar: ICalComponent, serverSchedules: Bool) -> ReplyRoute {
        serverSchedules && !ITIP.repliesByClient(calendar) ? .server : .app
    }

    /// Whether "don't send a response" can be kept: only where the server will not send one. That is
    /// every copy on a server that does not schedule, the app's own copy whose create has not reached
    /// the server (`onServer` false: the create can say `SCHEDULE-AGENT=CLIENT`), and a copy that
    /// says it already. On any other copy the server
    /// answers the organiser whatever the app writes, and an attendee may not change its
    /// SCHEDULE-AGENT (RFC 6638 › 3.2.2.1), so the choice is not offered there.
    public static func canWithholdReply(copy: Data?, onServer: Bool, serverSchedules: Bool) -> Bool {
        guard serverSchedules, onServer else { return true }
        guard let copy, let calendar = try? ICalendarReader.calendar(copy) else { return false }
        return ITIP.repliesByClient(calendar)
    }
}
