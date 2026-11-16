// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// Which protection a message asks for: the id of a registered `MailProtection`.
public struct ProtectionID: Hashable, Codable, Sendable {
    public let raw: String
    public init(raw: String) { self.raw = raw }
}

/// What a draft has been asked to be sent with, and for whom that was decided.
public struct ProtectionRequirement: Codable, Sendable, Equatable {
    public var protection: ProtectionID
    /// Lower-case, sorted: the recipients this was decided for.
    public var recipients: [String]
    /// The owner chose to send it plain to exactly `recipients`.
    public var plainChosen: Bool
    /// What the protection does to it.
    public var kind: Kind

    public enum Kind: String, Codable, Sendable {
        /// Readable only by its recipients (and signed).
        case encrypt
        /// Readable by anyone, and shown to be from the owner: nothing is hidden, so nothing is
        /// decided per recipient.
        case sign
    }

    public init(protection: ProtectionID, recipients: [String], plainChosen: Bool, kind: Kind = .encrypt) {
        self.protection = protection
        self.recipients = recipients
        self.plainChosen = plainChosen
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey { case protection, recipients, plainChosen, kind }

    /// One kept before there were kinds asks for encryption, as it did then.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        protection = try values.decode(ProtectionID.self, forKey: .protection)
        recipients = try values.decode([String].self, forKey: .recipients)
        plainChosen = try values.decode(Bool.self, forKey: .plainChosen)
        kind = try values.decodeIfPresent(Kind.self, forKey: .kind) ?? .encrypt
    }
}
