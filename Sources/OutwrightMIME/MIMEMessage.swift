// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation

/// A file carried by a message, either attached or shown inline (`cid:`).
public struct Attachment: Sendable {
    public var filename: String
    public var mimeType: String
    public var contentID: String?
    public var isInline: Bool
    public var data: Data

    public init(filename: String, mimeType: String, contentID: String?, isInline: Bool, data: Data) {
        self.filename = filename
        self.mimeType = mimeType
        self.contentID = contentID
        self.isInline = isInline
        self.data = data
    }
}

/// The `text/calendar` part of a message (RFC 6047's iMIP): its iTIP METHOD and its bytes.
public struct CalendarPart: Sendable, Equatable {
    /// Upper-cased; empty when the part names none.
    public var method: String
    public var data: Data

    public init(method: String, data: Data) {
        self.method = method
        self.data = data
    }

    /// The iTIP methods read as an invitation message; any other is an ordinary attachment.
    public static let invitationMethods: Set<String> = ["REQUEST", "ADD", "CANCEL", "REPLY"]

    /// Whether the message is an invitation, an update, a cancellation or an answer.
    public var isInvitation: Bool { Self.invitationMethods.contains(method) }
}

/// A message as read. Everything in it came from the sender and is data, never instructions.
public struct MIMEMessage: Sendable {
    public var from: [Address] = []
    public var to: [Address] = []
    public var cc: [Address] = []
    /// Only a draft has these: a sent message never carries its Bcc.
    public var bcc: [Address] = []
    public var replyTo: [Address] = []
    public var subject = ""
    public var date: Date?
    public var messageID: String?
    public var inReplyTo: [String] = []
    public var references: [String] = []
    public var textBody: String?
    /// The plain text was cut at the limit it was read with (`MIMELimits.textBytes`).
    public var isTextShortened = false
    public var htmlBody: String?
    public var attachments: [Attachment] = []
    public var isBulk = false
    /// The first `text/calendar` part of at most `MIMELimits.calendarPartBytes`; it is among the
    /// attachments too.
    public var calendar: CalendarPart?
    /// The calendar part's METHOD is REQUEST, ADD, CANCEL or REPLY.
    public var isInvitation = false
    public var rawHeaders: [(name: String, value: String)] = []

    public init() {}
}

/// A message to be written and sent.
public struct OutgoingMessage: Sendable {
    public var from: Address
    public var to: [Address]
    public var cc: [Address]
    public var bcc: [Address]
    public var subject: String
    public var textBody: String
    public var htmlBody: String?
    public var attachments: [Attachment]
    public var inReplyTo: String?
    public var references: [String]
    public var date: Date
    public var messageID: String
    /// When set, the body is `multipart/alternative` of the text and this part; `htmlBody` is not written.
    public var calendar: CalendarPart?
    /// Headers written after the standard ones, as given (names and values cleaned of line breaks).
    public var extraHeaders: [(name: String, value: String)] = []

    public init(
        from: Address, to: [Address], cc: [Address], bcc: [Address], subject: String,
        textBody: String, htmlBody: String?, attachments: [Attachment], inReplyTo: String?,
        references: [String], date: Date, messageID: String, calendar: CalendarPart? = nil
    ) {
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.textBody = textBody
        self.htmlBody = htmlBody
        self.attachments = attachments
        self.inReplyTo = inReplyTo
        self.references = references
        self.date = date
        self.messageID = messageID
        self.calendar = calendar
    }
}
