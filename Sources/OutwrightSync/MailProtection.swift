// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
public import OutwrightMIME
public import OutwrightModel

/// One message as it goes to the server: its bytes and who it is submitted to.
public struct Submission: Sendable {
    public var wire: Data
    public var recipients: [String]

    public init(wire: Data, recipients: [String]) {
        self.wire = wire
        self.recipients = recipients
    }
}

/// A message made ready to send: what is submitted, in order, and the owner's own copy for Sent.
public struct ProtectedSend: Sendable {
    public var submissions: [Submission]
    public var ownCopy: Data

    public init(submissions: [Submission], ownCopy: Data) {
        self.submissions = submissions
        self.ownCopy = ownCopy
    }
}

public enum ProtectionFailure: Error, Sendable {
    /// What the protection needs of these recipients is missing.
    case keyMissing([String])
}

/// A way of protecting mail, joined to the shared code at app start. The sync asks it when a draft
/// that asks for it is sent or saved, and never names it.
public protocol MailProtection: Sendable {
    var id: ProtectionID { get }
    /// Headers every message sent from the account carries.
    func headers(for account: Account) async -> [(name: String, value: String)]
    /// The message made ready for the wire, as the draft's requirement asks.
    func protect(_ message: OutgoingMessage, requirement: ProtectionRequirement, account: Account)
        async throws(ProtectionFailure) -> ProtectedSend
    /// The draft as it is kept on the server. Nil: it cannot be protected, and a draft whose
    /// requirement asks for protection then stays off the server (tried again later).
    func protectDraft(_ raw: Data, account: Account) async -> Data?
    /// A message was opened (or seen as it arrived), for what the protection learns from it.
    func learn(from message: MIMEMessage, facts: ProtectionFacts?, folder: FolderKind, account: Account) async
}
