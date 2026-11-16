// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import OutwrightModel

/// A contact in a phone group: its identifier, the name it shows and its first e-mail address
/// (lower-cased, empty when it has none).
public struct PhoneMember: Sendable, Equatable {
    public var identifier: String
    public var name: String
    public var email: String

    public init(identifier: String, name: String, email: String) {
        self.identifier = identifier
        self.name = name
        self.email = email
    }
}

/// The iPhone's own Contacts, as far as Outwright writes to it: a copy of an account's contacts,
/// one way, every contact in the account's group. Without access every call throws
/// `.phoneContactsDenied`.
public protocol PhoneContacts: Sendable {
    /// Asks the owner for access to Contacts (only the first time is a question); true when given.
    func requestAccess() async -> Bool
    /// The group `identifier` when it is still there; else a group called `name` in the default
    /// container (`adopted`); else a new one.
    func group(identifier: String?, name: String) throws(SyncError) -> (identifier: String, adopted: Bool)
    func members(ofGroup group: String) throws(SyncError) -> [PhoneMember]
    /// Saves the contact as the phone contact `identifier` (a new one, put in `group`, when nil or no
    /// longer there); `addToGroup` puts an existing one back in the group. Returns its identifier.
    func upsert(_ contact: Contact, identifier: String?, group: String, addToGroup: Bool) throws(SyncError) -> String
    /// Deletes these phone contacts (those still there), then `group` when it is left empty.
    func remove(identifiers: [String], group: String?) throws(SyncError)
}

#if canImport(Contacts)
import Contacts
import Foundation

/// The phone's Contacts over `CNContactStore`: contacts go in the default container, in one group
/// named after the account. Only identifiers Outwright recorded are ever changed or deleted.
public struct SystemPhoneContacts: PhoneContacts {
    public init() {}

    public func requestAccess() async -> Bool {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized, .limited:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return (try? await CNContactStore().requestAccess(for: .contacts)) ?? false
        @unknown default:
            return false
        }
    }

    public func group(identifier: String?, name: String) throws(SyncError) -> (identifier: String, adopted: Bool) {
        try Self.run { store in
            if let identifier, try Self.group(identifier, store) != nil {
                return (identifier, false)
            }
            let container = store.defaultContainerIdentifier()
            let predicate = CNGroup.predicateForGroupsInContainer(withIdentifier: container)
            if let found = try store.groups(matching: predicate).first(where: { $0.name == name }) {
                return (found.identifier, true)
            }
            // A save of its own: a member can't be added to a group made in the same save.
            let made = CNMutableGroup()
            made.name = name
            let request = CNSaveRequest()
            request.add(made, toContainerWithIdentifier: nil)
            try store.execute(request)
            return (made.identifier, false)
        }
    }

    public func members(ofGroup group: String) throws(SyncError) -> [PhoneMember] {
        try Self.run { store in
            try Self.fetch(inGroup: group, store, keys: Self.keys).map { contact in
                let person = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
                return PhoneMember(
                    identifier: contact.identifier,
                    name: contact.contactType == .organization ? contact.organizationName : person,
                    email: ((contact.emailAddresses.first?.value as String?) ?? "").lowercased())
            }
        }
    }

    public func upsert(
        _ contact: Contact, identifier: String?, group: String, addToGroup: Bool
    ) throws(SyncError) -> String {
        try Self.run { store in
            let request = CNSaveRequest()
            var changed = false
            let saved: String
            if let identifier, let existing = try Self.fetch([identifier], store, keys: Self.keys).first,
                let mutable = existing.mutableCopy() as? CNMutableContact {
                let wanted = CNMutableContact()
                Self.fill(wanted, contact.details, photo: contact.photo)
                if !Self.same(existing, wanted) {
                    Self.fill(mutable, contact.details, photo: contact.photo)
                    request.update(mutable)
                    changed = true
                }
                if addToGroup, let found = try Self.group(group, store) {
                    request.addMember(existing, to: found)
                    changed = true
                }
                saved = identifier
            } else {
                let new = CNMutableContact()
                Self.fill(new, contact.details, photo: contact.photo)
                request.add(new, toContainerWithIdentifier: nil)
                if let found = try Self.group(group, store) {
                    request.addMember(new, to: found)
                }
                changed = true
                saved = new.identifier
            }
            if changed {
                try store.execute(request)
            }
            return saved
        }
    }

    public func remove(identifiers: [String], group: String?) throws(SyncError) {
        try Self.run { store in
            let found = identifiers.isEmpty
                ? [] : try Self.fetch(identifiers, store, keys: [CNContactIdentifierKey as NSString])
            if !found.isEmpty {
                let request = CNSaveRequest()
                for contact in found {
                    if let mutable = contact.mutableCopy() as? CNMutableContact {
                        request.delete(mutable)
                    }
                }
                try store.execute(request)
            }
            // Only the account's own group, recorded when it was made or adopted, and only empty.
            if let group, let ours = try Self.group(group, store),
                try Self.fetch(inGroup: group, store, keys: [CNContactIdentifierKey as NSString]).isEmpty,
                let mutable = ours.mutableCopy() as? CNMutableGroup {
                let request = CNSaveRequest()
                request.delete(mutable)
                try store.execute(request)
            }
        }
    }

    /// Runs Contacts calls with access checked, their errors as `SyncError`.
    private static func run<T>(_ body: (CNContactStore) throws -> T) throws(SyncError) -> T {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized, .limited:
            break
        default:
            throw .phoneContactsDenied
        }
        do {
            return try body(CNContactStore())
        } catch let error as CNError where error.code == .authorizationDenied {
            throw .phoneContactsDenied
        } catch {
            throw .phoneContacts
        }
    }

    private static func group(_ identifier: String, _ store: CNContactStore) throws -> CNGroup? {
        try store.groups(matching: CNGroup.predicateForGroups(withIdentifiers: [identifier])).first
    }

    // The note is left out: writing it needs an entitlement Apple grants on request.
    private static var keys: [any CNKeyDescriptor] {
        [
            CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey, CNContactTypeKey,
            CNContactEmailAddressesKey, CNContactPhoneNumbersKey, CNContactPostalAddressesKey, CNContactImageDataKey
        ].map { $0 as NSString }
    }

    private static func fetch(
        _ identifiers: [String], _ store: CNContactStore, keys: [any CNKeyDescriptor]
    ) throws -> [CNContact] {
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.predicate = CNContact.predicateForContacts(withIdentifiers: identifiers)
        return try collect(request, store)
    }

    private static func fetch(
        inGroup group: String, _ store: CNContactStore, keys: [any CNKeyDescriptor]
    ) throws -> [CNContact] {
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.predicate = CNContact.predicateForContactsInGroup(withIdentifier: group)
        return try collect(request, store)
    }

    private static func collect(_ request: CNContactFetchRequest, _ store: CNContactStore) throws -> [CNContact] {
        request.unifyResults = false
        var found: [CNContact] = []
        try store.enumerateContacts(with: request) { contact, _ in found.append(contact) }
        return found
    }

    private static func fill(_ target: CNMutableContact, _ details: ContactDetails, photo: Data?) {
        target.givenName = details.givenName
        target.familyName = details.familyName
        target.organizationName = details.organization
        target.contactType = .person
        if details.givenName.isEmpty, details.familyName.isEmpty {
            if details.organization.isEmpty {
                target.givenName = details.name
            } else {
                target.contactType = .organization
            }
        }
        target.emailAddresses = details.emails.map {
            CNLabeledValue(label: label($0.label, phone: false), value: $0.value as NSString)
        }
        target.phoneNumbers = details.phones.map {
            CNLabeledValue(label: label($0.label, phone: true), value: CNPhoneNumber(stringValue: $0.value))
        }
        target.postalAddresses = details.addresses.map { address in
            let postal = CNMutablePostalAddress()
            postal.street = address.street
            postal.city = address.locality
            postal.state = address.region
            postal.postalCode = address.postalCode
            postal.country = address.country
            return CNLabeledValue(label: label(address.label, phone: false), value: postal as CNPostalAddress)
        }
        target.imageData = ContactPhoto.safe(photo)
    }

    private static func same(_ first: CNContact, _ second: CNContact) -> Bool {
        first.givenName == second.givenName && first.familyName == second.familyName
            && first.organizationName == second.organizationName && first.contactType == second.contactType
            && first.emailAddresses.map { [$0.label, $0.value as String] }
                == second.emailAddresses.map { [$0.label, $0.value as String] }
            && first.phoneNumbers.map { [$0.label, $0.value.stringValue] }
                == second.phoneNumbers.map { [$0.label, $0.value.stringValue] }
            && first.postalAddresses.map(\.label) == second.postalAddresses.map(\.label)
            && first.postalAddresses.map(\.value) == second.postalAddresses.map(\.value)
            && first.imageData == second.imageData
    }

    /// The vCard TYPE as a Contacts label; an unknown one is kept as written.
    private static func label(_ type: String, phone: Bool) -> String? {
        switch type.lowercased() {
        case "": nil
        case "work": CNLabelWork
        case "home": CNLabelHome
        case "other": CNLabelOther
        case "cell" where phone, "mobile" where phone: CNLabelPhoneNumberMobile
        case "main" where phone: CNLabelPhoneNumberMain
        case "iphone" where phone: CNLabelPhoneNumberiPhone
        case "fax" where phone: CNLabelPhoneNumberOtherFax
        case "pager" where phone: CNLabelPhoneNumberPager
        default: type
        }
    }
}
#endif
