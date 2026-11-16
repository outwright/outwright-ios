// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightModel
import OutwrightStore
import OutwrightSync
import Testing

@testable import OutwrightUI

/// The contact shown beside the list on a wide phone, as the list changes under it.
@MainActor @Suite struct ContactsSelectionTests {
    /// Anna, Bo and Cecilia in one book.
    private func fixture() throws -> (model: ContactsModel, store: MailStore, ids: [ContactID]) {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org", cardDAV: true)
        try box.store.replaceAddressBooks([("/work/", "Work", false)], for: anna.id)
        let book = try #require(try box.store.addressBooks(anna.id).first)
        let ids = try ["Anna", "Bo", "Cecilia"].map { name in
            try box.store.createContact(
                ContactDetails(givenName: name, emails: [Labeled(label: "work", value: "\(name)@example.org")]),
                in: book.id)
        }
        let app = AppModel(store: box.store, sync: offlineSync(store: box.store, secrets: InMemorySecretStore()))
        let model = ContactsModel(app: app)
        model.reload()
        return (model, box.store, ids)
    }

    @Test func removingTheSelectedContactSelectsTheNext() throws {
        let (model, store, ids) = try fixture()
        model.selected = ids[1]
        try store.deleteContact(ids[1])
        model.reload()
        #expect(model.selected == ids[2])
    }

    @Test func searchThatHidesTheSelectionMovesIt() throws {
        let (model, _, ids) = try fixture()
        model.selected = ids[0]
        model.searchText = "Cecilia"
        #expect(model.selected == ids[2])
    }
}
