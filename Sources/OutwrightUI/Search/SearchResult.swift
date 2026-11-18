// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import OutwrightMIME
public import OutwrightModel

/// A person in the results: a contact (one row whatever its addresses), or someone mail was
/// exchanged with.
public struct SearchPerson: Hashable, Sendable {
    public var name: String
    /// Lower-cased, the contact's in its order; empty for a contact without an address.
    public var emails: [String]
    /// The second line: the first address, else the first phone number, else the organization.
    public var detail: String
    public var contact: ContactID?

    public init(name: String, emails: [String], detail: String, contact: ContactID?) {
        self.name = name
        self.emails = emails
        self.detail = detail
        self.contact = contact
    }

    init(contact: Contact) {
        let details = contact.details
        let emails = details.emails.map { $0.value.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var seen = Set<String>()
        self.emails = emails.map { $0.lowercased() }.filter { seen.insert($0).inserted }
        name = details.name
        let phone = details.phones.map(\.value).first { !$0.isEmpty }
        detail = emails.first ?? phone ?? details.organization
        self.contact = contact.id
    }

    init(address: Address) {
        let name = address.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.name = name.isEmpty ? address.email : name
        emails = [address.email.lowercased()]
        detail = address.email
        contact = nil
    }

    /// The address a message to this person goes to.
    public var address: Address? {
        emails.first.map { Address(name: name == $0 ? nil : name, email: $0) }
    }
}

/// An attachment in the results: where it is in its message (`index` among the parsed attachments).
public struct FileHit: Equatable, Sendable {
    public var name: String
    public var mimeType: String
    public var size: Int
    public var index: Int
    public var message: MessageRow

    public init(name: String, mimeType: String, size: Int, index: Int, message: MessageRow) {
        self.name = name
        self.mimeType = mimeType
        self.size = size
        self.index = index
        self.message = message
    }
}

/// One line of the results.
public enum SearchResult: Identifiable, Sendable {
    case person(SearchPerson)
    case event(CalendarEvent)
    case file(FileHit)
    case message(MessageRow)
    /// A completion of what was typed.
    case suggestion(String)

    public var id: String {
        switch self {
        case .person(let person):
            "p:" + (person.contact.map { "c\($0.raw)" } ?? person.emails.joined(separator: ","))
        case .event(let event): "e:\(event.id.raw)"
        case .file(let file): "f:\(file.message.id.raw):\(file.index):\(file.name)"
        case .message(let row): "m:\(row.id.raw)"
        case .suggestion(let text): "s:" + text
        }
    }

    public var kind: SearchSection.Kind {
        switch self {
        case .person: .people
        case .event: .events
        case .file: .files
        case .message: .messages
        case .suggestion: .suggestions
        }
    }

    public var message: MessageRow? {
        if case .message(let row) = self { return row }
        return nil
    }

    public var person: SearchPerson? {
        if case .person(let person) = self { return person }
        return nil
    }

    public var event: CalendarEvent? {
        if case .event(let event) = self { return event }
        return nil
    }

    public var file: FileHit? {
        if case .file(let file) = self { return file }
        return nil
    }

    public var fileName: String? { file?.name }

    public var suggestion: String? {
        if case .suggestion(let text) = self { return text }
        return nil
    }
}
