// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightDAV
import OutwrightMIME
import OutwrightModel

/// The words of the mails about meetings: a reply's subject prefix per answer ("Accepted:" and so
/// on) and its plain-text line, the plain-text line of an invitation the owner sends, and a
/// cancellation's subject prefix and line; `%@` stands for the owner's name. Sync has no String
/// Catalog: the app hands in the localized wording.
public struct MeetingWording: Sendable, Equatable {
    public var accepted: String
    public var tentative: String
    public var declined: String
    public var line: String
    public var invited: String
    public var cancelled: String
    public var cancelledLine: String

    public init(
        accepted: String, tentative: String, declined: String, line: String, invited: String, cancelled: String,
        cancelledLine: String
    ) {
        self.accepted = accepted
        self.tentative = tentative
        self.declined = declined
        self.line = line
        self.invited = invited
        self.cancelled = cancelled
        self.cancelledLine = cancelledLine
    }

    public static let english = MeetingWording(
        accepted: "Accepted:", tentative: "Tentative:", declined: "Declined:",
        line: "%@ has replied to the invitation.", invited: "%@ has invited you to this meeting.",
        cancelled: "Cancelled:", cancelledLine: "%@ has cancelled this meeting.")

    /// The prefix for the answer; nil for one that is not a reply (no answer, delegated).
    func prefix(_ response: Attendee.Response) -> String? {
        switch response {
        case .accepted: accepted
        case .tentative: tentative
        case .declined: declined
        case .needsAction, .delegated: nil
        }
    }
}

/// The iMIP REPLY mail (RFC 6047) for the owner's answer, built from the stored calendar object,
/// never from a received message.
enum InvitationReply {
    /// The longest title kept in the subject.
    static let maxTitle = 200

    // swiftlint:disable function_parameter_count
    /// From the account to the ORGANIZER: subject `<prefix> <title>`, the plain-text line and the
    /// `text/calendar; method=REPLY` part (`ITIP.reply`: only the owner's ATTENDEE, at the answer).
    /// Every header value is stripped of CR, LF and NUL. Nil when there is nothing to reply to: no
    /// ORGANIZER that is an address, no ATTENDEE for the account, or an answer that is not a reply.
    static func message(
        calendar: ICalComponent, response: Attendee.Response, recurrenceID: EventTime?, account: Account,
        wording: MeetingWording, now: Date
    ) -> OutgoingMessage? {
        guard let prefix = wording.prefix(response), let partstat = EventMapping.partstat(response),
            let reply = ITIP.reply(
                from: calendar, ownEmail: account.email, partstat: partstat,
                recurrenceID: recurrenceID.map { ICalValue.property("RECURRENCE-ID", $0) }, now: now),
            let event = reply.components.first(where: { $0.name == "VEVENT" }),
            let organizer = event.first("ORGANIZER"), case let to = clean(EventMapping.address(organizer.value)),
            isAddress(to)
        else { return nil }
        let title = String(clean(event.first("SUMMARY")?.text ?? "").prefix(maxTitle))
        let name = clean(account.displayName)
        let domain = account.email.split(separator: "@").last.map(String.init) ?? "outwright.invalid"
        return OutgoingMessage(
            from: Address(name: name.isEmpty ? nil : name, email: clean(account.email)),
            to: [Address(name: organizer.parameter("CN").map(clean).flatMap { $0.isEmpty ? nil : $0 }, email: to)],
            cc: [], bcc: [], subject: clean(title.isEmpty ? prefix : prefix + " " + title),
            textBody: wording.line.replacingOccurrences(of: "%@", with: name.isEmpty ? account.email : name),
            htmlBody: nil, attachments: [], inReplyTo: nil, references: [], date: now,
            messageID: "\(UUID().uuidString.lowercased())@\(clean(domain))",
            calendar: CalendarPart(method: ITIPMethod.reply.rawValue, data: ICalendarWriter.write(reply)))
    }

    // swiftlint:enable function_parameter_count

    /// The draft the reply is sent from: its row (placed in Drafts by the store) and body.
    static func draft(_ message: OutgoingMessage, account: Account) -> (row: MessageRow, body: Data)? {
        guard let body = try? MIMEWriter.write(message, includeBcc: true) else { return nil }
        let row = MessageRow(
            id: MessageID(raw: 0), accountID: account.id, folderID: FolderID(raw: 0), uid: 0,
            threadID: ThreadID(raw: message.messageID), from: message.from, to: message.to, cc: [],
            subject: message.subject, preview: String(message.textBody.prefix(200)), date: message.date, isRead: true,
            isFlagged: false, hasAttachment: false, isInvitation: false, inboxClass: .focused, hasBody: true,
            threadCount: 1, messageIDHeader: message.messageID)
        return (row, body)
    }

    /// Without CR, LF and NUL.
    static func clean(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { !["\r", "\n", "\0"].contains($0) }))
    }

    /// One `@` with something on both sides, and nothing that would break the address out of its header.
    static func isAddress(_ text: String) -> Bool {
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        let breaking = "<>,;:\"()[]\\".unicodeScalars
        return parts.count == 2 && parts.allSatisfy { !$0.isEmpty }
            && !text.unicodeScalars.contains { $0.properties.isWhitespace || breaking.contains($0) }
    }
}
