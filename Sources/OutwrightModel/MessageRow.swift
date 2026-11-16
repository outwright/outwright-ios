// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
public import OutwrightMIME

public enum InboxClass: String, Codable, Sendable {
    case focused, other
}

/// One message as the lists show it. The body is kept apart (`MailStore.body`).
public struct MessageRow: Sendable, Identifiable, Equatable {
    public var id: MessageID
    public var accountID: AccountID
    public var folderID: FolderID
    public var uid: UInt32
    public var threadID: ThreadID
    public var from: Address
    public var to: [Address]
    public var cc: [Address]
    public var subject: String
    public var preview: String
    public var date: Date
    public var isRead: Bool
    public var isFlagged: Bool
    public var hasAttachment: Bool
    public var isInvitation: Bool
    public var inboxClass: InboxClass
    public var hasBody: Bool
    public var threadCount: Int
    /// The Message-ID header, as sent.
    public var messageIDHeader: String?
    /// A draft the server refused for good, and why; nil for everything else.
    public var notSent: SendRefusal?
    /// The Message-IDs it answers (References and In-Reply-To), as read from the server. Kept by the
    /// store to join threads, not read back.
    public var references: [String]
    /// The message was protected from readers on the way (its outer subject says nothing): the
    /// subject and preview shown are the opened message's, kept apart from what the server holds.
    public var isProtected: Bool
    /// A protected message that was opened: what it shows (even nothing) is its own.
    public var isDecrypted: Bool

    public init(
        id: MessageID, accountID: AccountID, folderID: FolderID, uid: UInt32, threadID: ThreadID,
        from: Address, to: [Address], cc: [Address], subject: String, preview: String, date: Date,
        isRead: Bool, isFlagged: Bool, hasAttachment: Bool, isInvitation: Bool,
        inboxClass: InboxClass, hasBody: Bool, threadCount: Int, messageIDHeader: String? = nil,
        notSent: SendRefusal? = nil, references: [String] = [], isProtected: Bool = false,
        isDecrypted: Bool = false
    ) {
        self.id = id
        self.accountID = accountID
        self.folderID = folderID
        self.uid = uid
        self.threadID = threadID
        self.from = from
        self.to = to
        self.cc = cc
        self.subject = subject
        self.preview = preview
        self.date = date
        self.isRead = isRead
        self.isFlagged = isFlagged
        self.hasAttachment = hasAttachment
        self.isInvitation = isInvitation
        self.inboxClass = inboxClass
        self.hasBody = hasBody
        self.threadCount = threadCount
        self.messageIDHeader = messageIDHeader
        self.notSent = notSent
        self.references = references
        self.isProtected = isProtected
        self.isDecrypted = isDecrypted
    }
}
