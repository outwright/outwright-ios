// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Observation
import OutwrightMIME
import OutwrightModel
import OutwrightStore

/// A request to open the contact editor: for a new contact (perhaps from an address) or an existing one.
struct ContactEditorRequest: Identifiable, Equatable {
    let id = UUID()
    var editing: ContactID?
    var prefill: Address?
}

enum ContactEditError: Error, Equatable {
    /// No address book to put the contact in.
    case noBook
    /// Nothing has been filled in.
    case empty
    /// The store refused.
    case store
}

/// The editor of one contact: a new one (in the chosen address book) or an existing one.
@Observable @MainActor
final class ContactEditorModel {
    var details: ContactDetails
    var book: AddressBookID?
    /// Where a new contact can go: the books that can be written to, by account.
    private(set) var writableBooks: [(account: Account, books: [AddressBook])] = []
    let editing: ContactID?

    @ObservationIgnored private let app: AppModel
    @ObservationIgnored private let original: ContactDetails?
    /// The details as the editor opened, to tell what the owner changed.
    @ObservationIgnored private let opened: ContactDetails

    init(app: AppModel, editing: ContactID?, prefill: Address?) {
        self.app = app
        self.editing = editing
        let stored = editing.flatMap { try? app.store.contact($0) }
        original = stored?.details
        opened = stored?.details ?? Self.details(from: prefill)
        details = opened
        book = stored?.addressBookID
        writableBooks = app.writableAccounts.compactMap { account in
            let books = ((try? app.store.addressBooks(account.id)) ?? []).filter { !$0.isReadOnly }
            return books.isEmpty ? nil : (account: account, books: books)
        }
        if book == nil {
            let inView = app.accountInView.flatMap { account in writableBooks.first { $0.account.id == account.id } }
            book = (inView ?? writableBooks.first)?.books.first?.id
        }
    }

    /// The book and its account, for showing which one the contact goes to.
    var chosen: (account: Account, book: AddressBook)? {
        for group in writableBooks {
            if let found = group.books.first(where: { $0.id == book }) { return (group.account, found) }
        }
        guard let editing, let stored = try? app.store.contact(editing),
            let account = app.accounts.first(where: { $0.id == stored.accountID }),
            let found = try? app.store.addressBooks(account.id).first(where: { $0.id == stored.addressBookID })
        else { return nil }
        return (account, found)
    }

    /// What the chosen account's server can hold: Graph has three addresses, one mobile number,
    /// no `other` phone and one address of each kind.
    var limits: ContactLimits {
        chosen?.account.contactsVia == .graph ? .graph : .none
    }

    var canAddEmail: Bool {
        limits.maxEmails.map { details.emails.count < $0 } ?? true
    }

    var canAddAddress: Bool {
        !limits.onePerAddressLabel || !addressLabels(for: details.addresses.count).isEmpty
    }

    /// The labels the phone row at `index` may take (a row past the end: a new one).
    func phoneLabels(for index: Int) -> [String] {
        guard let maxMobile = limits.maxMobile else { return limits.phoneLabels }
        let others = details.phones.enumerated().filter { $0.offset != index && $0.element.label == "mobile" }
        return others.count < maxMobile ? limits.phoneLabels : limits.phoneLabels.filter { $0 != "mobile" }
    }

    var emailLabels: [String] { limits.emailLabels }

    /// The labels the address at `index` may take (a row past the end: a new one).
    func addressLabels(for index: Int) -> [String] {
        guard limits.onePerAddressLabel else { return ContactLimits.addressLabels }
        let taken = Set(details.addresses.enumerated().filter { $0.offset != index }.map(\.element.label))
        return ContactLimits.addressLabels.filter { !taken.contains($0) }
    }

    var newPhoneLabel: String { phoneLabels(for: details.phones.count).first ?? "" }
    var newAddressLabel: String { addressLabels(for: details.addresses.count).first ?? "home" }

    /// Something has been typed, added or removed since the editor opened.
    var hasChanges: Bool { details != opened }

    var canSave: Bool { book != nil && !cleaned().isBlank && !isOverLimits }

    /// What is typed holds more than the chosen book's server can (rows typed for another book):
    /// it is not saved until it fits, so nothing is dropped on the way.
    var isOverLimits: Bool {
        let typed = cleaned()
        let mobile: Set<String> = ["mobile", "cell"]
        if let maxEmails = limits.maxEmails, typed.emails.count > maxEmails { return true }
        if let maxMobile = limits.maxMobile, typed.phones.filter({ mobile.contains($0.label) }).count > maxMobile {
            return true
        }
        if typed.phones.contains(where: { !limits.phoneLabels.contains($0.label) && !mobile.contains($0.label) }) {
            return true
        }
        guard limits.onePerAddressLabel else { return false }
        let labels = typed.addresses.map(\.label)
        return Set(labels).count < labels.count || labels.contains { !ContactLimits.addressLabels.contains($0) }
    }

    /// Stores the contact and queues it for the server.
    func save() throws(ContactEditError) -> ContactID {
        guard let book else { throw .noBook }
        let result = cleaned()
        if result.isBlank { throw .empty }
        do {
            if let editing {
                // Only what the owner changed goes over what is stored now (sync may have changed the rest).
                let now = try app.store.contact(editing)?.details ?? opened
                let merged = ContactDetails.merged(base: cleaned(opened), ours: result, server: now)
                try app.store.updateContact(editing, merged)
                return editing
            }
            return try app.store.createContact(result, in: book)
        } catch {
            throw .store
        }
    }

    /// What is typed, trimmed, with the empty rows left out.
    private func cleaned(_ details: ContactDetails? = nil) -> ContactDetails {
        let details = details ?? self.details
        let trim = { (text: String) in text.trimmingCharacters(in: .whitespacesAndNewlines) }
        var result = details
        result.givenName = trim(details.givenName)
        result.familyName = trim(details.familyName)
        result.organization = trim(details.organization)
        result.note = trim(details.note)
        result.displayName = trim(details.displayName)
        let rows = { (items: [Labeled]) in
            items.map { Labeled(label: trim($0.label), value: trim($0.value), origin: $0.origin) }
                .filter { !$0.value.isEmpty }
        }
        result.emails = rows(details.emails)
        result.phones = rows(details.phones)
        result.addresses = details.addresses.map {
            PostalAddress(
                label: trim($0.label), street: trim($0.street), locality: trim($0.locality),
                region: trim($0.region), postalCode: trim($0.postalCode), country: trim($0.country),
                origin: $0.origin)
        }.filter { !$0.isBlank }
        // A new name would not show behind an old display name.
        if let original, original.givenName != result.givenName || original.familyName != result.familyName,
            original.displayName == result.displayName {
            result.displayName = ""
        }
        return result
    }

    private static func details(from address: Address?) -> ContactDetails {
        guard let address else { return ContactDetails() }
        var result = ContactDetails(emails: [Labeled(label: "", value: address.email)])
        let name = (address.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty && name.lowercased() != address.email.lowercased() {
            if let space = name.lastIndex(of: " ") {
                result.givenName = String(name[..<space]).trimmingCharacters(in: .whitespaces)
                result.familyName = String(name[name.index(after: space)...])
            } else {
                result.givenName = name
            }
        }
        return result
    }
}

extension ContactDetails {
    /// Nothing worth keeping is filled in.
    fileprivate var isBlank: Bool {
        givenName.isEmpty && familyName.isEmpty && displayName.isEmpty && organization.isEmpty && note.isEmpty
            && emails.isEmpty && phones.isEmpty && addresses.isEmpty
    }
}

extension PostalAddress {
    fileprivate var isBlank: Bool {
        street.isEmpty && locality.isEmpty && region.isEmpty && postalCode.isEmpty && country.isEmpty
    }
}

/// What an account's contacts can hold, for the editor to offer no more.
struct ContactLimits: Equatable {
    static let addressLabels = ["home", "work", "other"]

    var maxEmails: Int?
    var phoneLabels: [String]
    var emailLabels: [String]
    var maxMobile: Int?
    var onePerAddressLabel: Bool

    static let none = ContactLimits(
        maxEmails: nil, phoneLabels: ["mobile", "work", "home", "other"], emailLabels: ["work", "home", "other"],
        maxMobile: nil, onePerAddressLabel: false)
    /// Graph.
    static let graph = ContactLimits(
        maxEmails: 3, phoneLabels: ["mobile", "work", "home"], emailLabels: ["other"], maxMobile: 1,
        onePerAddressLabel: true)
}
