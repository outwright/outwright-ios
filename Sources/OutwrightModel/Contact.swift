// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation

public struct AddressBookID: Hashable, Codable, Sendable {
    public let raw: Int64
    public init(raw: Int64) { self.raw = raw }
}

public struct ContactID: Hashable, Codable, Sendable {
    public let raw: Int64
    public init(raw: Int64) { self.raw = raw }
}

public struct AddressBook: Sendable, Identifiable, Equatable {
    public var id: AddressBookID
    public var accountID: AccountID
    public var href: String
    public var name: String
    public var isReadOnly: Bool

    public init(id: AddressBookID, accountID: AccountID, href: String, name: String, isReadOnly: Bool) {
        self.id = id
        self.accountID = accountID
        self.href = href
        self.name = name
        self.isReadOnly = isReadOnly
    }
}

public struct Labeled: Sendable, Equatable, Codable {
    public var label: String
    public var value: String
    /// Where the entry was read from in the server's card (its place among that card's entries of
    /// its kind), so an edit goes back to that entry; nil for one added here.
    public var origin: Int?

    public init(label: String, value: String, origin: Int? = nil) {
        self.label = label
        self.value = value
        self.origin = origin
    }

    /// Tolerant of saved data missing a key.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        label = try values.decodeIfPresent(String.self, forKey: .label) ?? ""
        value = try values.decodeIfPresent(String.self, forKey: .value) ?? ""
        origin = try? values.decodeIfPresent(Int.self, forKey: .origin)
    }

    /// The entry itself; where it was read from is not part of it.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.label == rhs.label && lhs.value == rhs.value
    }
}

public struct PostalAddress: Sendable, Equatable, Codable {
    public var label: String
    public var street: String
    public var locality: String
    public var region: String
    public var postalCode: String
    public var country: String
    /// Where the address was read from, as for `Labeled.origin`.
    public var origin: Int?

    public init(
        label: String = "", street: String = "", locality: String = "", region: String = "",
        postalCode: String = "", country: String = "", origin: Int? = nil
    ) {
        self.label = label
        self.street = street
        self.locality = locality
        self.region = region
        self.postalCode = postalCode
        self.country = country
        self.origin = origin
    }

    /// The address itself; where it was read from is not part of it.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.label == rhs.label && lhs.street == rhs.street && lhs.locality == rhs.locality
            && lhs.region == rhs.region && lhs.postalCode == rhs.postalCode && lhs.country == rhs.country
    }

    /// Tolerant of saved data missing a key.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        label = try values.decodeIfPresent(String.self, forKey: .label) ?? ""
        street = try values.decodeIfPresent(String.self, forKey: .street) ?? ""
        locality = try values.decodeIfPresent(String.self, forKey: .locality) ?? ""
        region = try values.decodeIfPresent(String.self, forKey: .region) ?? ""
        postalCode = try values.decodeIfPresent(String.self, forKey: .postalCode) ?? ""
        country = try values.decodeIfPresent(String.self, forKey: .country) ?? ""
        origin = try? values.decodeIfPresent(Int.self, forKey: .origin)
    }
}

/// What the app shows and edits of a contact.
public struct ContactDetails: Sendable, Equatable, Codable {
    public var givenName: String
    public var familyName: String
    public var displayName: String
    public var organization: String
    /// The job title (vCard TITLE).
    public var title: String
    public var note: String
    public var emails: [Labeled]
    public var phones: [Labeled]
    public var addresses: [PostalAddress]

    public init(
        givenName: String = "", familyName: String = "", displayName: String = "",
        organization: String = "", title: String = "", note: String = "", emails: [Labeled] = [],
        phones: [Labeled] = [], addresses: [PostalAddress] = []
    ) {
        self.givenName = givenName
        self.familyName = familyName
        self.displayName = displayName
        self.organization = organization
        self.title = title
        self.note = note
        self.emails = emails
        self.phones = phones
        self.addresses = addresses
    }

    /// Tolerant of saved data missing a key (an older shape still reads).
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        givenName = try values.decodeIfPresent(String.self, forKey: .givenName) ?? ""
        familyName = try values.decodeIfPresent(String.self, forKey: .familyName) ?? ""
        displayName = try values.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        organization = try values.decodeIfPresent(String.self, forKey: .organization) ?? ""
        title = try values.decodeIfPresent(String.self, forKey: .title) ?? ""
        note = try values.decodeIfPresent(String.self, forKey: .note) ?? ""
        emails = try values.decodeIfPresent([Labeled].self, forKey: .emails) ?? []
        phones = try values.decodeIfPresent([Labeled].self, forKey: .phones) ?? []
        addresses = try values.decodeIfPresent([PostalAddress].self, forKey: .addresses) ?? []
    }

    /// The server's details with the owner's changes since `base` laid over them: a field the owner
    /// left as it was in `base` keeps what the server has now.
    public static func merged(base: ContactDetails, ours: ContactDetails, server: ContactDetails) -> ContactDetails {
        var result = server
        func take<T: Equatable>(_ path: WritableKeyPath<ContactDetails, T>) {
            if ours[keyPath: path] != base[keyPath: path] { result[keyPath: path] = ours[keyPath: path] }
        }
        take(\.givenName)
        take(\.familyName)
        take(\.displayName)
        take(\.organization)
        take(\.title)
        take(\.note)
        takeList(\.emails, &result, base: base, ours: ours, server: server)
        takeList(\.phones, &result, base: base, ours: ours, server: server)
        takeList(\.addresses, &result, base: base, ours: ours, server: server)
        return result
    }

    /// Our list when we changed it. Where its entries were read from points into the card as it
    /// was in `base`, so over a server list that changed meanwhile they are matched by value instead.
    private static func takeList<Item: ContactEntry>(
        _ path: WritableKeyPath<ContactDetails, [Item]>, _ result: inout ContactDetails,
        base: ContactDetails, ours: ContactDetails, server: ContactDetails
    ) {
        guard ours[keyPath: path] != base[keyPath: path] else { return }
        var list = ours[keyPath: path]
        if server[keyPath: path] != base[keyPath: path] { clear(&list) }
        result[keyPath: path] = list
    }

    /// The display name, else given and family name, else the organisation, else the first address.
    public var name: String {
        let trimmed = { (text: String) in text.trimmingCharacters(in: .whitespacesAndNewlines) }
        if !trimmed(displayName).isEmpty { return trimmed(displayName) }
        let person = trimmed([givenName, familyName].filter { !trimmed($0).isEmpty }.joined(separator: " "))
        if !person.isEmpty { return person }
        if !trimmed(organization).isEmpty { return trimmed(organization) }
        return emails.first.map { trimmed($0.value) } ?? ""
    }

    /// The family name, else the name, lower-cased with diacritics folded, except å, ä and ö, which
    /// become `{`, `|` and `}` so a plain byte order gives the Swedish alphabet (Z, then Å, Ä, Ö).
    public var sortKey: String {
        let family = familyName.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = (family.isEmpty ? name : family).precomposedStringWithCanonicalMapping.lowercased()
        let swedish = base.replacingOccurrences(of: "å", with: "{")
            .replacingOccurrences(of: "ä", with: "|").replacingOccurrences(of: "ö", with: "}")
        return String(swedish.prefix(256)).folding(options: .diacriticInsensitive, locale: nil)
    }
}

public struct Contact: Sendable, Identifiable, Equatable {
    public var id: ContactID
    public var accountID: AccountID
    public var addressBookID: AddressBookID
    public var details: ContactDetails
    public var photo: Data?
    /// The owner's version, kept when the server changed the card meanwhile (a 412).
    public var conflict: ContactDetails?
    public var changeFailed: Bool
    /// The failed change is a photo the server (Graph) did not take: Try again sends it once more.
    public var photoFailed: Bool

    public init(
        id: ContactID, accountID: AccountID, addressBookID: AddressBookID, details: ContactDetails,
        photo: Data? = nil, conflict: ContactDetails? = nil, changeFailed: Bool = false, photoFailed: Bool = false
    ) {
        self.id = id
        self.accountID = accountID
        self.addressBookID = addressBookID
        self.details = details
        self.photo = photo
        self.conflict = conflict
        self.changeFailed = changeFailed
        self.photoFailed = photoFailed
    }
}

public enum ContactChange: String, Sendable, Equatable {
    case create, update, delete
}

extension ContactDetails {
    /// The details with no entry remembering where it was read from: for a card other than the
    /// one they were read from, where those places mean nothing.
    public var withoutOrigins: ContactDetails {
        var result = self
        Self.clear(&result.emails)
        Self.clear(&result.phones)
        Self.clear(&result.addresses)
        return result
    }

    /// The details with each entry's place taken from the equal entry of `card` (the details of
    /// the card now held), in order; an entry `card` lacks remembers none.
    public func originsAdopted(from card: ContactDetails) -> ContactDetails {
        var result = self
        Self.adopt(&result.emails, card.emails)
        Self.adopt(&result.phones, card.phones)
        Self.adopt(&result.addresses, card.addresses)
        return result
    }

    private static func clear<Item: ContactEntry>(_ list: inout [Item]) {
        for index in list.indices { list[index].origin = nil }
    }

    private static func adopt<Item: ContactEntry>(_ list: inout [Item], _ card: [Item]) {
        var used = Set<Int>()
        for index in list.indices {
            let found = card.indices.first { !used.contains($0) && card[$0] == list[index] }
            if let found { used.insert(found) }
            list[index].origin = found.flatMap { card[$0].origin }
        }
    }
}

/// An entry of a contact's list that remembers where in the server's card it was read from.
protocol ContactEntry: Equatable {
    var origin: Int? { get set }
}

extension Labeled: ContactEntry {}
extension PostalAddress: ContactEntry {}
