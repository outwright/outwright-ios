// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation

public struct AccountID: Hashable, Codable, Sendable {
    public let raw: UUID
    public init(raw: UUID = UUID()) { self.raw = raw }
}

public struct FolderID: Hashable, Codable, Sendable {
    public let raw: Int64
    public init(raw: Int64) { self.raw = raw }
}

public struct MessageID: Hashable, Codable, Sendable {
    public let raw: Int64
    public init(raw: Int64) { self.raw = raw }
}

public struct ThreadID: Hashable, Codable, Sendable {
    public let raw: String
    public init(raw: String) { self.raw = raw }
}

/// Where a protocol is spoken: mirrored here so the model does not depend on the network layer.
public struct MailEndpoint: Codable, Hashable, Sendable {
    public var host: String
    public var port: UInt16
    public var security: String

    public init(host: String, port: UInt16, security: String) {
        self.host = host
        self.port = port
        self.security = security
    }
}

/// How an account proves who it is to its servers: a password, or an OAuth access token its
/// provider renews (XOAUTH2 for IMAP and SMTP).
public enum AccountAuth: String, Codable, Sendable {
    case password, oauth
}

/// Who an account is with: the provider that brought its sign-in, servers and quirks. A string,
/// so an account whose provider this build does not carry is kept as it is.
public struct ProviderID: Hashable, Codable, Sendable {
    public let raw: String
    public init(raw: String) { self.raw = raw }

    /// Written as the bare string, as the store keeps it.
    public init(from decoder: any Decoder) throws {
        raw = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }

    /// The owner's own server: IMAP and SMTP with CalDAV and CardDAV, or JMAP.
    public static let ownServer = ProviderID(raw: "own-server")
}

/// Which protocol an account's calendars come over.
public enum CalendarVia: String, Codable, Sendable {
    case calDAV, graph
}

/// Which protocol an account's contacts come over.
public enum ContactsVia: String, Codable, Sendable {
    case cardDAV, graph
}

/// A mail account. The password or token is not here; it lives in the keychain.
public struct Account: Codable, Sendable, Identifiable {
    public var id: AccountID
    public var displayName: String
    public var email: String
    /// 0..<8
    public var colorIndex: Int
    public var imap: MailEndpoint
    public var smtp: MailEndpoint
    public var user: String
    public var signature: String
    public var sortOrder: Int
    /// The confirmed CardDAV context URL.
    public var cardDAV: String?
    /// A CardDAV address found off the account's domain, awaiting the owner.
    public var cardDAVUnconfirmed: String?
    public var savesContactsToPhone: Bool
    /// The owner chose no CardDAV address: none is looked for.
    public var cardDAVOff: Bool
    /// The confirmed CalDAV context URL.
    public var calDAV: String?
    /// A CalDAV address found off the account's domain, awaiting the owner.
    public var calDAVUnconfirmed: String?
    /// The owner chose no CalDAV address: none is looked for.
    public var calDAVOff: Bool

    public var auth: AccountAuth
    public var provider: ProviderID
    public var calendarVia: CalendarVia
    public var contactsVia: ContactsVia

    public init(
        id: AccountID, displayName: String, email: String, colorIndex: Int, imap: MailEndpoint,
        smtp: MailEndpoint, user: String, signature: String, sortOrder: Int, cardDAV: String? = nil,
        cardDAVUnconfirmed: String? = nil, savesContactsToPhone: Bool = false,
        cardDAVOff: Bool = false, calDAV: String? = nil, calDAVUnconfirmed: String? = nil,
        calDAVOff: Bool = false, auth: AccountAuth = .password, provider: ProviderID = .ownServer,
        calendarVia: CalendarVia = .calDAV, contactsVia: ContactsVia = .cardDAV
    ) {
        self.id = id
        self.displayName = displayName
        self.email = email
        self.colorIndex = colorIndex
        self.imap = imap
        self.smtp = smtp
        self.user = user
        self.signature = signature
        self.sortOrder = sortOrder
        self.cardDAV = cardDAV
        self.cardDAVUnconfirmed = cardDAVUnconfirmed
        self.savesContactsToPhone = savesContactsToPhone
        self.cardDAVOff = cardDAVOff
        self.calDAV = calDAV
        self.calDAVUnconfirmed = calDAVUnconfirmed
        self.calDAVOff = calDAVOff
        self.auth = auth
        self.provider = provider
        self.calendarVia = calendarVia
        self.contactsVia = contactsVia
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, email, colorIndex, imap, smtp, user, signature, sortOrder
        case cardDAV, cardDAVUnconfirmed, savesContactsToPhone, cardDAVOff, calDAV, calDAVUnconfirmed, calDAVOff
        case auth, provider, calendarVia, contactsVia
    }

    /// What `auth` was called for a Microsoft account before providers.
    static let oldMicrosoftAuth = "microsoft"

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(AccountID.self, forKey: .id)
        displayName = try values.decode(String.self, forKey: .displayName)
        email = try values.decode(String.self, forKey: .email)
        colorIndex = try values.decode(Int.self, forKey: .colorIndex)
        imap = try values.decode(MailEndpoint.self, forKey: .imap)
        smtp = try values.decode(MailEndpoint.self, forKey: .smtp)
        user = try values.decode(String.self, forKey: .user)
        signature = try values.decode(String.self, forKey: .signature)
        sortOrder = try values.decode(Int.self, forKey: .sortOrder)
        cardDAV = try values.decodeIfPresent(String.self, forKey: .cardDAV)
        cardDAVUnconfirmed = try values.decodeIfPresent(String.self, forKey: .cardDAVUnconfirmed)
        savesContactsToPhone = try values.decodeIfPresent(Bool.self, forKey: .savesContactsToPhone) ?? false
        cardDAVOff = try values.decodeIfPresent(Bool.self, forKey: .cardDAVOff) ?? false
        calDAV = try values.decodeIfPresent(String.self, forKey: .calDAV)
        calDAVUnconfirmed = try values.decodeIfPresent(String.self, forKey: .calDAVUnconfirmed)
        calDAVOff = try values.decodeIfPresent(Bool.self, forKey: .calDAVOff) ?? false
        let rawAuth = (try? values.decodeIfPresent(String.self, forKey: .auth)) ?? ""
        let oldMicrosoft = rawAuth == Self.oldMicrosoftAuth
        auth = oldMicrosoft ? .oauth : AccountAuth(rawValue: rawAuth) ?? .password
        let rawProvider = (try? values.decodeIfPresent(ProviderID.self, forKey: .provider))
        provider = rawProvider ?? (oldMicrosoft ? ProviderID(raw: Self.oldMicrosoftAuth) : .ownServer)
        calendarVia = (try? values.decodeIfPresent(CalendarVia.self, forKey: .calendarVia))
            ?? (oldMicrosoft ? .graph : .calDAV)
        contactsVia = (try? values.decodeIfPresent(ContactsVia.self, forKey: .contactsVia))
            ?? (oldMicrosoft ? .graph : .cardDAV)
    }
}
