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
        #expect(model.letters == ["A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q",
            "R", "S", "T", "U", "V", "W", "X", "Y", "Z", "Å", "Ä", "Ö", "#"])
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

    @Test func indexJumpsToTheLetterOrTheNextWithASection() {
        let letters = ContactsModel.alphabet
        let have: Set<String> = ["B", "Å", "#"]
        #expect(AlphabetIndex.target(from: 1, in: letters, available: have) == "B")
        #expect(AlphabetIndex.target(from: 2, in: letters, available: have) == "Å")
        #expect(AlphabetIndex.target(from: 27, in: letters, available: have) == "#")
        #expect(AlphabetIndex.target(from: 28, in: letters, available: ["B"]) == "B", "past the last: the last with one")
        #expect(AlphabetIndex.target(from: 3, in: letters, available: []) == nil)
        #expect(AlphabetIndex.target(from: 99, in: letters, available: have) == nil)
        #expect(AlphabetIndex.target(from: -1, in: letters, available: have) == nil)
    }
}
