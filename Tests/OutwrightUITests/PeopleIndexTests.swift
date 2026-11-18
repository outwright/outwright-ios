// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightMIME
import OutwrightModel
import OutwrightStore
import Testing

@testable import OutwrightUI

@Suite struct PeopleIndexTests {
    private func contact(_ box: Mailbox, _ given: String, _ family: String, _ emails: [String], in book: AddressBook)
        throws {
        _ = try box.store.createContact(
            ContactDetails(
                givenName: given, familyName: family, emails: emails.map { Labeled(label: "work", value: $0) }),
            in: book.id)
    }

    @Test func contactsJoinCorrespondentsOnceEach() throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org", cardDAV: true)
        try box.add(anna, uid: 1, from: "bo@example.org")
        try box.add(anna, uid: 2, from: "bo@example.org")
        try box.add(anna, uid: 3, from: "cia@example.org")
        try box.store.replaceAddressBooks([(href: "/book/", name: "Contacts", isReadOnly: false)], for: anna.id)
        let book = try #require(try box.store.addressBooks(anna.id).first)
        try contact(box, "Bo", "Berg", ["BO@example.org"], in: book)
        try contact(box, "Dan", "Dahl", ["dan@example.org", "dan.dahl@example.org"], in: book)
        try contact(box, "Adam", "Ahl", ["adam@example.org"], in: book)
        try contact(box, "Anna", "Själv", ["anna@example.org"], in: book)

        let known = PeopleIndex.known(box.store, accounts: box.accounts)

        #expect(known.map { $0.email.lowercased() } == [
            "bo@example.org", "cia@example.org", "adam@example.org", "dan@example.org", "dan.dahl@example.org",
        ])
        #expect(known.last?.name == "Dan Dahl")
    }

    @Test func contactNameFillsMissingName() throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org", cardDAV: true)
        try box.add(anna, .sent, uid: 1, to: ["eva@example.org"])
        try box.store.replaceAddressBooks([(href: "/book/", name: "Contacts", isReadOnly: false)], for: anna.id)
        let book = try #require(try box.store.addressBooks(anna.id).first)
        try contact(box, "Eva", "Ek", ["Eva@Example.org"], in: book)

        let known = PeopleIndex.known(box.store, accounts: box.accounts)

        #expect(known.map(\.email) == ["eva@example.org"])
        #expect(known.first?.name == "Eva Ek")
    }

    @Test func fullNameFindsThePerson() {
        let anna = Address(name: "Anna Svensson", email: "a.s@example.org")
        #expect(PeopleIndex.matches(anna, "anna s"))
        #expect(PeopleIndex.matches(anna, "Sven ann"))
        #expect(PeopleIndex.matches(anna, "a.s@"))
        #expect(!PeopleIndex.matches(anna, "anna b"))
    }
}
