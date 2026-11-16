// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation

/// What an attendee may change in an object the organiser controls (RFC 6638 › 3.2.2.1).
extension FakeCalDAVServer {
    /// From now on an attendee's PUT that changes start, end, summary, location, status or sequence
    /// is refused with `allowed-attendee-scheduling-object-change` (403), as RFC 6638 › 3.2.2.1 lets
    /// a server do.
    public func refuseAttendeeChanges() {
        refusesAttendeeChanges = true
    }

    /// From now on the calendar refuses writes (403), as one shared read-only after it was listed.
    public func makeReadOnly(_ calendar: URL) {
        calendars[Self.key(calendar)]?.readOnly = true
    }

    /// The object is an attendee's: its ORGANIZER is someone else, and the account is among its
    /// ATTENDEEs.
    func isAttendees(_ ics: String) -> Bool {
        let lines = Self.unfolded(ics)
        let user = core.user.lowercased()
        guard let organizer = lines.first(where: { $0.uppercased().hasPrefix("ORGANIZER") }) else { return false }
        return !organizer.lowercased().hasSuffix(":mailto:" + user)
            && lines.contains(where: { Self.isOwn($0, core.user) })
    }

    /// The lines an attendee may not change, in order.
    static func organiserFields(_ ics: String) -> [String] {
        let names = ["DTSTART", "DTEND", "SUMMARY", "LOCATION", "STATUS", "SEQUENCE"]
        return unfolded(ics).filter { line in
            names.contains { line.uppercased().hasPrefix($0 + ":") || line.uppercased().hasPrefix($0 + ";") }
        }
    }
}
