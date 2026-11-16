// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightDAV
import OutwrightMIME
import OutwrightModel

/// The owner's own meetings: the guests a CalDAV server that schedules would tell (RFC 6638 › 3.2.1),
/// the app tells by iMIP (RFC 6047) where the server does not, once each write has landed. A new or
/// changed meeting goes to its guests as a REQUEST, a guest taken off gets a CANCEL, and a deleted
/// meeting a CANCEL to every guest it had.
extension CalendarSyncer {
    /// The mails, as drafts, that `change` owes the meeting's guests, `calendar` being the meeting as
    /// the server now holds it (nil: deleted). None for a change that is only the owner's answers or
    /// reminder, for a meeting someone else organises, or for guests the server tells itself.
    func meetingMails(_ change: QueuedEventChange, now calendar: ICalComponent?) throws(SyncError)
        -> [(row: MessageRow, body: Data)] {
        guard change.edits.contains(where: Self.isOrganising) else { return [] }
        let schedules = try stored { try store.serverSchedules(account.id) }
        let guests = { (meeting: ICalComponent) in
            ITIP.mailedAttendees(meeting, ownEmail: self.account.email, serverSchedules: schedules)
        }
        // What the guests were last told: the server's object before this change; a create has none.
        let before = change.href == nil ? nil : change.ics.flatMap(Self.parse)
        let told = before.map(guests) ?? []
        let mail = { (calendar: ICalComponent, to: [String]) in
            MeetingMail.message(calendar, to: to, account: self.account, wording: self.meetingWording, now: self.now())
        }
        let invited = calendar.map(guests) ?? []
        var sent: [(guests: [String], calendar: ICalComponent)] = []
        if let calendar {
            sent += ITIP.requests(from: calendar, guests: invited, now: now())
            sent += ITIP.occurrenceCancels(from: calendar, guests: invited, now: now())
        }
        let off = told.filter { !invited.contains($0) }
        if let cancel = before.flatMap({ ITIP.cancel(from: $0, attendees: off, raisingSequence: true, now: now()) }) {
            sent.append((off, cancel))
        }
        return sent.compactMap { mail($0.calendar, $0.guests) }
            .compactMap { InvitationReply.draft($0, account: account) }
    }

    /// An edit the organiser makes: the meeting made, changed or deleted.
    static func isOrganising(_ edit: EventEdit) -> Bool {
        switch edit {
        case .create, .update, .delete: true
        case .respond, .ownReminder, .guestAnswer, .organiserChange: false
        }
    }
}

/// The iMIP mail (RFC 6047) of the owner's meeting: from the account to the guests, the subject the
/// title (after the cancellation's prefix for a CANCEL), the plain-text line and the `text/calendar`
/// part. Every header value is stripped of CR, LF and NUL.
enum MeetingMail {
    static func message(
        _ calendar: ICalComponent, to guests: [String], account: Account, wording: MeetingWording, now: Date
    ) -> OutgoingMessage? {
        guard let method = calendar.first("METHOD")?.value,
            let event = calendar.components.first(where: { $0.name == "VEVENT" })
        else { return nil }
        let names = Dictionary(
            calendar.components.flatMap { $0.all("ATTENDEE") }
                .map { (EventMapping.address($0.value).lowercased(), $0) },
            uniquingKeysWith: { first, _ in first })
        let to = guests.map(InvitationReply.clean).filter(InvitationReply.isAddress).map { email in
            Address(
                name: names[email]?.parameter("CN").map(InvitationReply.clean).flatMap { $0.isEmpty ? nil : $0 },
                email: email)
        }
        guard !to.isEmpty else { return nil }
        let cancelled = method == ITIPMethod.cancel.rawValue
        let title = String(InvitationReply.clean(event.first("SUMMARY")?.text ?? "").prefix(InvitationReply.maxTitle))
        let subject = cancelled ? (title.isEmpty ? wording.cancelled : wording.cancelled + " " + title) : title
        let name = InvitationReply.clean(account.displayName)
        let line = (cancelled ? wording.cancelledLine : wording.invited)
            .replacingOccurrences(of: "%@", with: name.isEmpty ? account.email : name)
        let domain = account.email.split(separator: "@").last.map(String.init) ?? "outwright.invalid"
        return OutgoingMessage(
            from: Address(name: name.isEmpty ? nil : name, email: InvitationReply.clean(account.email)),
            to: to, cc: [], bcc: [], subject: InvitationReply.clean(subject.isEmpty ? line : subject),
            textBody: line, htmlBody: nil, attachments: [], inReplyTo: nil, references: [], date: now,
            messageID: "\(UUID().uuidString.lowercased())@\(InvitationReply.clean(domain))",
            calendar: CalendarPart(method: method, data: ICalendarWriter.write(calendar)))
    }
}
