// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightDAV
import OutwrightFakes
import OutwrightModel
import OutwrightStore
import OutwrightSync
import Testing

/// The parsed card the fake holds under `uid`.
private func serverCard(_ h: ContactHarness, _ book: URL, _ uid: String) async throws -> VCard {
    let text = try #require(await h.server.cards(in: book)[uid])
    return try #require(try VCardReader.cards(Data(text.utf8)).first)
}

@Suite struct ContactWriteTests {
    @Test func createdContactReachesServerWithFN() async throws {
        try await withContacts { h in
            let book = await h.server.addBook("Work")
            let syncer = h.syncer()
            try await syncer.sync()
            let stored = try #require(try h.store.addressBooks(h.account.id).first)
            _ = try h.store.createContact(ContactDetails(givenName: "Ny", familyName: "Person"), in: stored.id)

            try await syncer.runChanges()

            let (uid, _) = try #require(await h.server.cards(in: book).first)
            let card = try await serverCard(h, book, uid)
            #expect(card.fields.formattedName == "Ny Person")
        }
    }

    @Test func createdContactCarriesItsTitleAndPhoto() async throws {
        try await withContacts { h in
            let book = await h.server.addBook("Work")
            let syncer = h.syncer()
            try await syncer.sync()
            let stored = try #require(try h.store.addressBooks(h.account.id).first)
            let photo = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3])
            _ = try h.store.createContact(
                ContactDetails(givenName: "Ny", familyName: "Person", title: "Chef"), photo: photo, in: stored.id)

            try await syncer.runChanges()

            let (uid, _) = try #require(await h.server.cards(in: book).first)
            let card = try await serverCard(h, book, uid)
            #expect(card.fields.title == "Chef")
            #expect(card.fields.photo == photo)
            #expect(try h.store.photosToSend(h.account.id).isEmpty, "a card carries its photo: none waits apart")
        }
    }

    @Test func renamedContactKeepsFNOnServer() async throws {
        try await withContacts { h in
            let book = await h.server.addBook("Work")
            await h.server.putCard(card("b", given: "Bo", family: "Berg"), uid: "b", in: book)
            let syncer = h.syncer()
            try await syncer.sync()
            let bo = try h.contact(named: "Bo Berg")
            var renamed = bo.details
            // The editor blanks the display name when the name changes.
            renamed.givenName = "Bosse"
            renamed.displayName = ""
            try h.store.updateContact(bo.id, renamed)

            try await syncer.runChanges()

            let card = try await serverCard(h, book, "b")
            #expect(card.fields.formattedName == "Bosse Berg")
            #expect(card.fields.givenName == "Bosse")
        }
    }

    @Test func aSecondEditAfterASendReachesTheEntryItWasMeantFor() async throws {
        try await withContacts { h in
            let book = await h.server.addBook("Work")
            await h.server.putCard(
                card("b", given: "Bo", family: "Berg", extra: [
                    "item1.EMAIL;TYPE=work:a@example.org", "item1.X-ABLabel:Jobb",
                    "item2.EMAIL;TYPE=home:b@example.org", "item2.X-ABLabel:Privat",
                    "item3.EMAIL;TYPE=other:c@example.org", "item3.X-ABLabel:Klubb",
                ]), uid: "b", in: book)
            let syncer = h.syncer()
            try await syncer.sync()
            var details = try h.contact(named: "Bo Berg").details
            details.emails.removeFirst()
            try h.store.updateContact(try h.contact(named: "Bo Berg").id, details)
            try await syncer.runChanges()
            // The second edit starts from what the phone now holds, after the first was sent.
            let bo = try h.contact(named: "Bo Berg")
            var second = bo.details
            second.emails[1].value = "c2@example.org"
            try h.store.updateContact(bo.id, second)
            try await syncer.runChanges()

            let emails = try await serverCard(h, book, "b").properties.filter { $0.name == "EMAIL" }
            #expect(emails.map(\.group) == ["item2", "item3"])
            #expect(emails.map(\.value) == ["b@example.org", "c2@example.org"])
            #expect(emails.map { $0.parameters.flatMap(\.values) } == [["home"], ["other"]])
        }
    }

    /// Bo Berg on the server and synced, with the owner's new phone number queued.
    private func queuedEdit(_ h: ContactHarness) async throws -> (URL, ContactSyncer, Contact) {
        let book = await h.server.addBook("Work")
        await h.server.putCard(card("b", given: "Bo", family: "Berg"), uid: "b", in: book)
        let syncer = h.syncer()
        try await syncer.sync()
        let bo = try h.contact(named: "Bo Berg")
        var edited = bo.details
        edited.phones = [Labeled(label: "cell", value: "+46 70 000 00 00")]
        try h.store.updateContact(bo.id, edited)
        return (book, syncer, bo)
    }

    @Test func lockedCardIsTriedAgainLater() async throws {
        try await withContacts { h in
            let (book, syncer, bo) = try await queuedEdit(h)
            await h.server.failWrites(status: 423, count: 1)
            await #expect(throws: SyncError.self) { try await syncer.runChanges() }
            #expect(try h.store.contact(bo.id)?.changeFailed == false)
            #expect(try h.store.pendingContactChanges(h.account.id).count == 1)

            try await syncer.runChanges()

            #expect(try await serverCard(h, book, "b").fields.phones.map(\.value) == ["+46 70 000 00 00"])
        }
    }

    @Test func stuckChangeDoesNotStopIncomingSync() async throws {
        try await withContacts { h in
            let (book, syncer, _) = try await queuedEdit(h)
            await h.server.failWrites(status: 503, count: 1_000)
            await h.server.putCard(card("c", given: "Cia", family: "Ceder"), uid: "c", in: book)

            await #expect(throws: SyncError.self) { try await syncer.sync() }

            #expect(try h.names() == ["Bo Berg", "Cia Ceder"])
            #expect(try h.store.pendingContactChanges(h.account.id).count == 1)
        }
    }

    @Test func changeRefusedByTheServerTenTimesIsMarkedFailed() async throws {
        try await withContacts { h in
            let (_, syncer, bo) = try await queuedEdit(h)
            await h.server.failWrites(status: 500, count: 1_000)
            for _ in 0..<9 {
                await #expect(throws: SyncError.self) { try await syncer.sync() }
            }
            #expect(try h.store.pendingContactChanges(h.account.id).count == 1)
            #expect(try h.store.contact(bo.id)?.changeFailed == false)

            try? await syncer.sync()

            #expect(try h.store.pendingContactChanges(h.account.id).isEmpty)
            let after = try #require(try h.store.contact(bo.id))
            #expect(after.changeFailed)
            #expect(after.details.phones.map(\.value) == ["+46 70 000 00 00"])
        }
    }

    @Test func connectionFailuresDoNotCountTowardsFailing() async throws {
        try await withContacts { h in
            let (_, syncer, bo) = try await queuedEdit(h)
            await h.server.stop()
            for _ in 0..<12 {
                await #expect(throws: SyncError.self) { try await syncer.runChanges() }
            }
            #expect(try h.store.contact(bo.id)?.changeFailed == false)
            #expect(try h.store.pendingContactChanges(h.account.id).count == 1)
        }
    }

    @Test func configurationErrorsDoNotCountTowardsFailing() async throws {
        try await withContacts { h in
            let (book, syncer, bo) = try await queuedEdit(h)
            await h.server.redirect(
                book.path(percentEncoded: true) + "b.vcf", to: "https://elsewhere.example.net/b.vcf")
            for _ in 0..<12 {
                await #expect(throws: SyncError.dav(.offDomainRedirect(host: "elsewhere.example.net"))) {
                    try await syncer.runChanges()
                }
            }
            #expect(try h.store.contact(bo.id)?.changeFailed == false)
            #expect(try h.store.pendingContactChanges(h.account.id).count == 1)
        }
    }
}
