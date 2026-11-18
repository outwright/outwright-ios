// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightModel
import OutwrightStore
import OutwrightSync
import Testing

@testable import OutwrightUI

@MainActor @Suite struct ContactsModelTests {
    /// A store with two accounts; the first has books "Work" and "Friends", the second "Family".
    private func fixture() throws -> (app: AppModel, books: [AddressBook], box: Mailbox) {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org", cardDAV: true)
        let home = try box.addAccount("home@example.org", cardDAV: true)
        try box.store.replaceAddressBooks(
            [("/work/", "Work", false), ("/friends/", "Friends", false)], for: anna.id)
        try box.store.replaceAddressBooks([("/family/", "Family", false)], for: home.id)
        let books = try box.store.addressBooks(anna.id) + box.store.addressBooks(home.id)
        let app = AppModel(store: box.store, sync: offlineSync(store: box.store, secrets: InMemorySecretStore()))
        return (app, books, box)
    }

    private func add(_ box: Mailbox, _ name: String, family: String = "", in book: AddressBook) throws {
        _ = try box.store.createContact(
            ContactDetails(
                givenName: name, familyName: family,
                emails: [Labeled(label: "work", value: "\(name.lowercased())@example.org")]),
            in: book.id)
    }

    @Test func sectionsFollowSwedishAlphabet() throws {
        let (app, books, box) = try fixture()
        let book = try #require(books.first)
        for name in ["Örjan", "Zorro", "Åsa", "Äke", "Adam", "Émile", "Bo", "42"] { try add(box, name, in: book) }
        let model = ContactsModel(app: app)
        model.reload()
        #expect(model.sections.map(\.letter) == ["A", "B", "E", "Z", "Å", "Ä", "Ö", "#"])
        #expect(model.sections.first { $0.letter == "E" }?.contacts.count == 1)
    }

    @Test func indexShowsOnlyLettersInUse() throws {
        let (app, books, box) = try fixture()
        let book = try #require(books.first)
        for name in ["Bo", "Erik", "Zorro"] { try add(box, name, in: book) }
        let model = ContactsModel(app: app)
        model.reload()
        #expect(model.indexLetters(height: 1_000).map(\.title) == ["B", "E", "Z"])
        model.searchText = "bo"
        #expect(model.indexLetters(height: 1_000).isEmpty, "no index while searching")
    }

    @Test func indexThinsWhenShort() {
        let letters = (UInt8(ascii: "A")...UInt8(ascii: "Z")).map { String(UnicodeScalar($0)) }
        let entries = ContactsModel.thinned(letters, height: 120)
        #expect(entries.contains { $0.title == "•" })
        #expect(CGFloat(entries.count) * 14 <= 120, "every entry has its 14 points")
        #expect(entries.first?.title == "A" && entries.last?.title == "Z")
        #expect(entries.allSatisfy { letters.contains($0.letter) }, "a dot jumps to a letter it stands for")
        #expect(ContactsModel.thinned(letters, height: 26 * 14).map(\.title) == letters, "room for all: all")
    }

    @Test func aDeletedContactLeavesTheStack() throws {
        let (app, books, box) = try fixture()
        let book = try #require(books.first)
        try add(box, "Bo", in: book)
        try add(box, "Eva", in: book)
        let model = ContactsModel(app: app)
        model.reload()
        let ids = model.sections.flatMap(\.contacts).map(\.id)
        model.path = ids
        try box.store.deleteContact(ids[1])
        model.reload()
        #expect(model.path == [ids[0]])
    }

    @Test func aBookTurningWritableEnablesAddWhileWatching() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org", cardDAV: true)
        try box.store.replaceAddressBooks([("/own/", "Own", true)], for: anna.id)
        let app = AppModel(store: box.store, sync: offlineSync(store: box.store, secrets: InMemorySecretStore()))
        let model = ContactsModel(app: app)
        let watching = Task { await model.observe() }
        defer { watching.cancel() }
        for _ in 0..<100 where model.bookGroups.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.addState == .readOnly)
        try box.store.replaceAddressBooks([("/own/", "Own", false)], for: anna.id)
        for _ in 0..<100 where !model.canAdd { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.canAdd)
    }

    @Test func emptyStateOffersAddAccountOnlyWithoutContacts() throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org", cardDAV: true)
        let app = AppModel(store: box.store, sync: offlineSync(store: box.store, secrets: InMemorySecretStore()))
        let model = ContactsModel(app: app)
        model.reload()
        #expect(model.addState == .noBook, "no account has contacts: Add account")
        try box.store.replaceAddressBooks([("/shared/", "Shared", true)], for: anna.id)
        model.reload()
        #expect(model.addState == .readOnly, "contacts, but none can be added: no Add account")
        try box.store.replaceAddressBooks([("/own/", "Own", false)], for: anna.id)
        model.reload()
        #expect(model.addState == .canAdd)
    }

    @Test func noWritableBookDisablesAdd() throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org", cardDAV: true)
        try box.store.replaceAddressBooks([("/shared/", "Shared", true)], for: anna.id)
        let app = AppModel(store: box.store, sync: offlineSync(store: box.store, secrets: InMemorySecretStore()))
        let model = ContactsModel(app: app)
        model.reload()
        #expect(!model.canAdd)
        try box.store.replaceAddressBooks([("/shared/", "Shared", true), ("/own/", "Own", false)], for: anna.id)
        model.reload()
        #expect(model.canAdd)
    }

    @Test func filterShowsOnlyChosenBooks() throws {
        let (app, books, box) = try fixture()
        try add(box, "Anna", in: books[0])
        try add(box, "Bo", in: books[1])
        try add(box, "Cia", in: books[2])
        let model = ContactsModel(app: app)
        model.reload()
        #expect(model.sections.flatMap(\.contacts).count == 3)
        model.shownBooks = [books[1].id, books[2].id]
        #expect(Set(model.sections.flatMap(\.contacts).map(\.details.givenName)) == ["Bo", "Cia"])
        model.shownBooks = nil
        #expect(model.sections.flatMap(\.contacts).count == 3)
    }

    @Test func searchNarrowsTheList() throws {
        let (app, books, box) = try fixture()
        try add(box, "Anna", family: "Lind", in: books[0])
        try add(box, "Bo", family: "Berg", in: books[0])
        let model = ContactsModel(app: app)
        model.reload()
        model.searchText = "lind"
        #expect(model.sections.flatMap(\.contacts).map(\.details.givenName) == ["Anna"])
        model.searchText = ""
        #expect(model.sections.flatMap(\.contacts).count == 2)
    }

    @Test func groupsListBooksUnderTheirAccount() throws {
        let (app, books, box) = try fixture()
        _ = box
        let model = ContactsModel(app: app)
        model.reload()
        #expect(model.bookGroups.count == 2)
        #expect(model.bookGroups[0].account.email == "anna@example.org")
        #expect(Set(model.bookGroups[0].books.map(\.id)) == [books[0].id, books[1].id])
        #expect(model.bookGroups[1].books.map(\.id) == [books[2].id])
    }

    @Test func listFollowsChangesToTheStore() async throws {
        let (app, books, box) = try fixture()
        let model = ContactsModel(app: app)
        let watching = Task { await model.observe() }
        defer { watching.cancel() }
        try add(box, "Anna", in: books[0])
        for _ in 0..<100 where model.sections.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.sections.flatMap(\.contacts).map(\.details.givenName) == ["Anna"])
    }
}
