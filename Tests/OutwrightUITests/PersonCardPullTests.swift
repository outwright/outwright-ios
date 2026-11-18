// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightFakes
import OutwrightModel
import OutwrightNet
import OutwrightStore
import OutwrightSync
import Testing

@testable import OutwrightUI

/// A pull on a contact's card brings in what changed on the server, as a pull on the list does.
@MainActor @Suite struct PersonCardPullTests {
    private func vcard(_ name: String) -> String {
        "BEGIN:VCARD\r\nVERSION:3.0\r\nUID:maja\r\nFN:\(name)\r\nN:;\(name);;;\r\n"
            + "EMAIL;TYPE=work:maja@example.org\r\nEND:VCARD\r\n"
    }

    @Test func aPullOnTheCardBringsTheServersChange() async throws {
        let server = FakeCardDAVServer()
        let port = try await server.start()
        defer { Task { await server.stop() } }
        var box = try Mailbox()
        var anna = try box.addAccount("anna@example.org")
        anna.user = "jk@example.org"
        anna.cardDAV = "http://127.0.0.1:\(port)/"
        try box.store.save(anna)
        let secrets = InMemorySecretStore()
        try secrets.setPassword(Secret("secret"), for: anna.id)
        let book = await server.addBook("Contacts")
        await server.putCard(vcard("Maja"), uid: "maja", in: book)
        let sync = offlineSync(store: box.store, secrets: secrets)
        let app = AppModel(store: box.store, sync: sync)
        await sync.refreshContacts(of: anna.id)
        let maja = try #require(try box.store.contacts(in: nil, matching: nil).first)

        let model = PersonCardModel(app: app, request: PersonRequest(contact: maja.id))
        model.reload()
        #expect(model.name == "Maja")
        await server.putCard(vcard("Maja Ek"), uid: "maja", in: book)

        await model.pull()
        model.reload()
        #expect(model.name == "Maja Ek")
    }
}
