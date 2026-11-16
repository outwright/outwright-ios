// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightDAV
import OutwrightFakes
import OutwrightModel
import OutwrightNet
import OutwrightStore
import OutwrightSync
import Synchronization
import Testing

/// A synthetic card.
func card(_ uid: String, given: String, family: String, email: String? = nil, extra: [String] = []) -> String {
    var lines = ["BEGIN:VCARD", "VERSION:4.0", "UID:\(uid)", "FN:\(given) \(family)", "N:\(family);\(given);;;"]
    if let email { lines.append("EMAIL;TYPE=work:\(email)") }
    lines += extra
    lines.append("END:VCARD")
    return lines.joined(separator: "\r\n") + "\r\n"
}

private let groupCard = """
    BEGIN:VCARD\r
    VERSION:4.0\r
    UID:group-1\r
    KIND:group\r
    FN:Friends\r
    MEMBER:urn:uuid:a\r
    END:VCARD\r

    """

struct ContactHarness {
    let server: FakeCardDAVServer
    let store: MailStore
    let secrets: InMemorySecretStore
    let account: Account

    func syncer() -> ContactSyncer {
        ContactSyncer(account: account, store: store, secrets: secrets, session: URLSession(configuration: .ephemeral))
    }

    /// The store's contacts as display names, sorted.
    func names() throws -> [String] {
        try store.contacts(in: nil, matching: nil).map(\.details.name).sorted()
    }

    /// The fake's person cards as display names, sorted.
    func serverNames(_ books: [URL]) async throws -> [String] {
        var names: [String] = []
        for book in books {
            for text in await server.cards(in: book).values {
                let parsed = try VCardReader.cards(Data(text.utf8))
                names += parsed.filter { !$0.isGroup }.map(\.fields.formattedName)
            }
        }
        return names.sorted()
    }

    func contact(named name: String) throws -> Contact {
        try #require(try store.contacts(in: nil, matching: nil).first { $0.details.name == name })
    }
}

/// A fake CardDAV server and an in-memory store with an account pointed at it (or at nothing,
/// with `cardDAV: false`).
func withContacts(
    sync: Bool = true, cardDAV: Bool = true, store given: MailStore? = nil, account base: Account? = nil,
    _ body: (ContactHarness) async throws -> Void
) async throws {
    let server = FakeCardDAVServer(offersSyncCollection: sync)
    let port = try await server.start()
    do {
        let store = try given ?? MailStore(path: nil)
        var account = base ?? Account(
            id: AccountID(), displayName: "Jörgen", email: "jk@example.org", colorIndex: 0,
            imap: MailEndpoint(host: "127.0.0.1", port: 1, security: "plainLoopbackOnly"),
            smtp: MailEndpoint(host: "127.0.0.1", port: 1, security: "plainLoopbackOnly"),
            user: "jk@example.org", signature: "", sortOrder: 0)
        account.cardDAV = cardDAV ? "http://127.0.0.1:\(port)/" : nil
        try store.save(account)
        let secrets = InMemorySecretStore()
        try secrets.setPassword(Secret("secret"), for: account.id)
        try await body(ContactHarness(server: server, store: store, secrets: secrets, account: account))
    } catch {
        await server.stop()
        throw error
    }
    await server.stop()
}

@Suite struct ContactSyncTests {
    @Test func firstSyncBringsEveryBookAndCard() async throws {
        try await withContacts { h in
            let work = await h.server.addBook("Work")
            let home = await h.server.addBook("Home")
            await h.server.putCard(card("a", given: "Ann", family: "Ek"), uid: "a", in: work)
            await h.server.putCard(card("b", given: "Bo", family: "Berg"), uid: "b", in: work)
            await h.server.putCard(card("c", given: "Cia", family: "Ceder"), uid: "c", in: work)
            await h.server.putCard(groupCard, uid: "group-1", in: work)
            await h.server.putCard(card("d", given: "Dan", family: "Dahl"), uid: "d", in: home)
            await h.server.putCard(card("e", given: "Eva", family: "Ek"), uid: "e", in: home)

            try await h.syncer().sync()

            #expect(try h.store.addressBooks(h.account.id).map(\.name).sorted() == ["Home", "Work"])
            #expect(try h.names() == ["Ann Ek", "Bo Berg", "Cia Ceder", "Dan Dahl", "Eva Ek"])
            #expect(await h.server.cards(in: work).count == 4)
        }
    }

    @Test func laterSyncAppliesChangesAndRemovals() async throws {
        try await withContacts { h in
            let book = await h.server.addBook("Work")
            await h.server.putCard(card("a", given: "Ann", family: "Ek"), uid: "a", in: book)
            await h.server.putCard(card("b", given: "Bo", family: "Berg"), uid: "b", in: book)
            let syncer = h.syncer()
            try await syncer.sync()

            await h.server.putCard(card("a", given: "Anna", family: "Ek"), uid: "a", in: book)
            await h.server.removeCard(uid: "b", in: book)
            await h.server.putCard(card("c", given: "Cia", family: "Ceder"), uid: "c", in: book)
            try await syncer.sync()

            #expect(try h.names() == ["Anna Ek", "Cia Ceder"])
        }
    }

    @Test func invalidTokenFallsBackToFullListing() async throws {
        try await withContacts { h in
            let book = await h.server.addBook("Work")
            for (uid, name) in [("a", "Ann"), ("b", "Bo"), ("c", "Cia")] {
                await h.server.putCard(card(uid, given: name, family: "Ek"), uid: uid, in: book)
            }
            let syncer = h.syncer()
            try await syncer.sync()

            await h.server.forgetSyncTokens()
            await h.server.removeCard(uid: "b", in: book)
            await h.server.putCard(card("c", given: "Cecilia", family: "Ek"), uid: "c", in: book)
            try await syncer.sync()

            #expect(try h.names() == (try await h.serverNames([book])))
            #expect(try h.names() == ["Ann Ek", "Cecilia Ek"])
        }
    }

    @Test func serverWithoutSyncCollectionUsesETags() async throws {
        try await withContacts(sync: false) { h in
            let book = await h.server.addBook("Work")
            await h.server.putCard(card("a", given: "Ann", family: "Ek"), uid: "a", in: book)
            await h.server.putCard(card("b", given: "Bo", family: "Berg"), uid: "b", in: book)
            let syncer = h.syncer()
            try await syncer.sync()
            #expect(try h.names() == ["Ann Ek", "Bo Berg"])

            await h.server.putCard(card("a", given: "Anna", family: "Ek"), uid: "a", in: book)
            await h.server.removeCard(uid: "b", in: book)
            await h.server.putCard(card("c", given: "Cia", family: "Ceder"), uid: "c", in: book)
            try await syncer.sync()

            #expect(try h.names() == ["Anna Ek", "Cia Ceder"])
        }
    }

    @Test func ownerCreateEditDeleteReachServer() async throws {
        try await withContacts { h in
            let book = await h.server.addBook("Work")
            await h.server.putCard(
                card("b", given: "Bo", family: "Berg", extra: ["X-SOCIALPROFILE;TYPE=x:https://social.example.org/bo"]),
                uid: "b", in: book)
            let syncer = h.syncer()
            try await syncer.sync()
            let stored = try #require(try h.store.addressBooks(h.account.id).first)

            let created = try h.store.createContact(
                ContactDetails(givenName: "Ny", familyName: "Person", emails: [Labeled(label: "home", value: "ny@example.org")]),
                in: stored.id)
            try await syncer.runChanges()
            let newCard = try #require(await h.server.cards(in: book).first { $0.key != "b" })
            let parsed = try #require(try VCardReader.cards(Data(newCard.value.utf8)).first)
            #expect(parsed.uid?.hasPrefix("urn:uuid:") == true)
            #expect(parsed.fields.emails.map(\.value) == ["ny@example.org"])
            #expect(try h.store.pendingContactChanges(h.account.id).isEmpty)

            let bo = try h.contact(named: "Bo Berg")
            var edited = bo.details
            edited.phones = [Labeled(label: "cell", value: "+46 70 000 00 00")]
            try h.store.updateContact(bo.id, edited)
            try await syncer.runChanges()
            let boText = try #require(await h.server.cards(in: book)["b"])
            let boCard = try #require(try VCardReader.cards(Data(boText.utf8)).first)
            #expect(boCard.fields.phones.map(\.value) == ["+46 70 000 00 00"])
            #expect(boCard.properties.contains { $0.name == "X-SOCIALPROFILE" })
            #expect(boCard.properties.contains { $0.name == "REV" })

            try h.store.deleteContact(bo.id)
            try h.store.deleteContact(created)
            try await syncer.runChanges()
            #expect(await h.server.cards(in: book).isEmpty)
            #expect(try h.store.contacts(in: nil, matching: nil).isEmpty)
            #expect(try h.store.pendingContactChanges(h.account.id).isEmpty)
        }
    }

    @Test func deleteWhileCreateIsSentLeavesNoCard() async throws {
        try await withContacts { h in
            let book = await h.server.addBook("Work")
            try await h.syncer().sync()
            let stored = try #require(try h.store.addressBooks(h.account.id).first)
            let id = try h.store.createContact(ContactDetails(givenName: "Ny", familyName: "Person"), in: stored.id)
            // The create's PUT goes out, and the owner deletes the contact before it is answered.
            let sent = try #require(try h.store.pendingContactChanges(h.account.id).first)
            let card = ContactMapping.newCard(ContactDetails(givenName: "Ny", familyName: "Person"))
            let href = try #require(URL(string: "orphan.vcf", relativeTo: book)?.absoluteURL)
            let client = CardDAVClient(
                context: book, credentials: DAVCredentials(user: "jk@example.org", password: "secret"),
                trustedHosts: ["127.0.0.1"], session: URLSession(configuration: .ephemeral))
            let etag = try await client.put(VCardWriter.write(card), at: href, ifMatch: nil)
            try h.store.deleteContact(id)
            try h.store.contactChangeDone(
                id, href: href.absoluteString, etag: etag, vcard: VCardWriter.write(card), revision: sent.revision)

            try await h.syncer().runChanges()

            #expect(await h.server.cards(in: book).isEmpty)
            #expect(try h.store.contact(id) == nil)
        }
    }

    @Test func createWhoseAnswerWasLostIsNotDuplicated() async throws {
        try await withContacts { h in
            let book = await h.server.addBook("Work")
            let syncer = h.syncer()
            try await syncer.sync()
            let stored = try #require(try h.store.addressBooks(h.account.id).first)
            let id = try h.store.createContact(ContactDetails(givenName: "Ny", familyName: "Person"), in: stored.id)
            await h.server.dropNextPutAnswer()
            await #expect(throws: SyncError.self) { try await syncer.runChanges() }
            #expect(await h.server.cards(in: book).count == 1)
            var edited = try #require(try h.store.contact(id)).details
            edited.organization = "Exempel AB"
            try h.store.updateContact(id, edited)

            try await syncer.runChanges()

            let cards = await h.server.cards(in: book)
            #expect(cards.count == 1)
            let parsed = try #require(try cards.values.first.flatMap { try VCardReader.cards(Data($0.utf8)).first })
            #expect(parsed.fields.organization == "Exempel AB")
            #expect(try h.store.pendingContactChanges(h.account.id).isEmpty)
            try await syncer.sync()
            #expect(try h.names() == ["Ny Person"])
        }
    }

    @Test func retriedCreateKeepsAnotherClientsEdits() async throws {
        try await withContacts { h in
            let book = await h.server.addBook("Work")
            let syncer = h.syncer()
            try await syncer.sync()
            let stored = try #require(try h.store.addressBooks(h.account.id).first)
            let id = try h.store.createContact(ContactDetails(givenName: "Ny", familyName: "Person"), in: stored.id)
            await h.server.dropNextPutAnswer()
            await #expect(throws: SyncError.self) { try await syncer.runChanges() }
            // Another client edits the card that landed.
            let (name, text) = try #require(await h.server.cards(in: book).first)
            let other = text.replacingOccurrences(
                of: "END:VCARD", with: "NOTE:From the other client\r\nX-SOCIALPROFILE:https://social.example.org/ny\r\nEND:VCARD")
            await h.server.putCard(other, uid: name, in: book)
            var edited = try #require(try h.store.contact(id)).details
            edited.organization = "Exempel AB"
            try h.store.updateContact(id, edited)

            try await syncer.runChanges()

            let final = try #require(await h.server.cards(in: book)[name])
            let parsed = try #require(try VCardReader.cards(Data(final.utf8)).first)
            #expect(parsed.fields.organization == "Exempel AB")
            #expect(parsed.fields.note == "From the other client")
            #expect(parsed.properties.contains { $0.name == "X-SOCIALPROFILE" })
        }
    }

    @Test func deleteAfterLostCreateAnswerRemovesTheCard() async throws {
        try await withContacts { h in
            let book = await h.server.addBook("Work")
            let syncer = h.syncer()
            try await syncer.sync()
            let stored = try #require(try h.store.addressBooks(h.account.id).first)
            let id = try h.store.createContact(ContactDetails(givenName: "Ny", familyName: "Person"), in: stored.id)
            await h.server.dropNextPutAnswer()
            await #expect(throws: SyncError.self) { try await syncer.runChanges() }
            try h.store.deleteContact(id)

            try await syncer.runChanges()

            #expect(await h.server.cards(in: book).isEmpty)
            #expect(try h.store.contact(id) == nil)
        }
    }

    @Test func ownContactSortsMailEvenWhenServerIsDown() async throws {
        let imap = await standardServer()
        await imap.deliver(mail("Club news", from: "bo@example.org", list: true), to: "INBOX")
        try await withHarness(imap) { mailHarness in
            let syncer = mailHarness.syncer()
            try await syncer.syncFolders()
            try await syncer.sync(try mailHarness.folder(.inbox).id)
            try await withContacts(store: mailHarness.store, account: mailHarness.account) { h in
                _ = await h.server.addBook("Work")
                let contacts = h.syncer()
                try await contacts.sync()
                let book = try #require(try h.store.addressBooks(h.account.id).first)
                await h.server.stop()
                _ = try h.store.createContact(
                    ContactDetails(givenName: "Bo", emails: [Labeled(label: "", value: "bo@example.org")]), in: book.id)
                await #expect(throws: SyncError.self) { try await contacts.sync() }
            }
            #expect(try mailHarness.rows(.inbox).first { $0.subject == "Club news" }?.inboxClass == .focused)
        }
    }

    @Test func deletedCreateNeverSentIsDroppedWithoutRequest() async throws {
        try await withContacts { h in
            _ = await h.server.addBook("Work")
            let syncer = h.syncer()
            try await syncer.sync()
            let stored = try #require(try h.store.addressBooks(h.account.id).first)
            let id = try h.store.createContact(ContactDetails(givenName: "Ny", familyName: "Person"), in: stored.id)
            try h.store.deleteContact(id)
            #expect(try h.store.contacts(in: nil, matching: nil).isEmpty)
            let before = await h.server.requests.count
            try await syncer.runChanges()
            #expect(await h.server.requests.count == before)
            #expect(try h.store.contact(id) == nil)
        }
    }

    @Test func conflictKeepsOwnEditAndServerVersion() async throws {
        try await withContacts { h in
            let book = await h.server.addBook("Work")
            await h.server.putCard(card("b", given: "Bo", family: "Berg"), uid: "b", in: book)
            let syncer = h.syncer()
            try await syncer.sync()
            let bo = try h.contact(named: "Bo Berg")
            var own = bo.details
            own.displayName = "Bo Own"
            try h.store.updateContact(bo.id, own)
            let serverText = card("b", given: "Bo", family: "Server")
            await h.server.putCard(serverText, uid: "b", in: book)

            try await syncer.sync()

            let after = try #require(try h.store.contact(bo.id))
            #expect(after.details.name == "Bo Server")
            #expect(after.conflict?.name == "Bo Own")
            #expect(await h.server.cards(in: book)["b"] == serverText)
            #expect(try h.store.pendingContactChanges(h.account.id).isEmpty)
        }
    }

    @Test func editDuringASendThatMeetsAConflictIsHeld() async throws {
        try await withContacts { h in
            let book = await h.server.addBook("Work")
            await h.server.putCard(card("b", given: "Bo", family: "Berg"), uid: "b", in: book)
            let syncer = h.syncer()
            try await syncer.sync()
            let bo = try h.contact(named: "Bo Berg")
            var first = bo.details
            first.organization = "First AB"
            try h.store.updateContact(bo.id, first)
            // Another client renames the card, and the owner edits again while the send is in flight.
            let serverText = card("b", given: "Bo", family: "Server")
            await h.server.putCard(serverText, uid: "b", in: book)
            var second = first
            second.organization = "Second AB"
            let store = h.store
            let id = bo.id
            let newer = second
            let edited = Mutex(false)
            await h.server.beforeNextPut {
                edited.withLock { $0 = (try? store.updateContact(id, newer)) != nil }
            }
            try await syncer.runChanges()
            try await syncer.sync()
            #expect(edited.withLock { $0 })
            #expect(await h.server.cards(in: book)["b"] == serverText)
            let after = try #require(try h.store.contact(bo.id))
            #expect(after.details.familyName == "Server")
            #expect(after.conflict?.organization == "Second AB")
            #expect(after.conflict?.familyName == "Berg")
            #expect(try h.store.pendingContactChanges(h.account.id).isEmpty)
        }
    }

    @Test func deleteThatMeetsAConflictIsAFailedChange() async throws {
        try await withContacts { h in
            let book = await h.server.addBook("Work")
            await h.server.putCard(card("b", given: "Bo", family: "Berg"), uid: "b", in: book)
            let syncer = h.syncer()
            try await syncer.sync()
            let bo = try h.contact(named: "Bo Berg")
            try h.store.deleteContact(bo.id)
            let serverText = card("b", given: "Bo", family: "Server")
            await h.server.putCard(serverText, uid: "b", in: book)
            try await syncer.sync()
            #expect(await h.server.cards(in: book)["b"] == serverText)
            let after = try h.contact(named: "Bo Server")
            #expect(after.id == bo.id)
            #expect(after.changeFailed && after.conflict == nil)
            #expect(try h.store.pendingContactChanges(h.account.id).isEmpty)
        }
    }

    @Test func goneBookFailsQueuedChange() async throws {
        try await withContacts { h in
            let book = await h.server.addBook("Work")
            await h.server.putCard(card("b", given: "Bo", family: "Berg"), uid: "b", in: book)
            let syncer = h.syncer()
            try await syncer.sync()
            let bo = try h.contact(named: "Bo Berg")
            var own = bo.details
            own.displayName = "Bo Own"
            try h.store.updateContact(bo.id, own)
            await h.server.removeBook(book)

            try? await syncer.sync()

            let after = try #require(try h.store.contact(bo.id))
            #expect(after.changeFailed)
            #expect(after.details.name == "Bo Own")
        }
    }

    @Test func accountWithoutCardDAVSyncsNothing() async throws {
        try await withContacts(cardDAV: false) { h in
            let book = await h.server.addBook("Work")
            await h.server.putCard(card("b", given: "Bo", family: "Berg"), uid: "b", in: book)
            let syncer = h.syncer()
            try await syncer.sync()
            try await syncer.runChanges()
            #expect(await h.server.requests.isEmpty)
            #expect(try h.store.addressBooks(h.account.id).isEmpty)
            #expect(try h.store.contacts(in: nil, matching: nil).isEmpty)
        }
    }

    @Test func contactSenderMovesStoredMailToFocused() async throws {
        let imap = await standardServer()
        await imap.deliver(mail("Club news", from: "bo@example.org", list: true), to: "INBOX")
        await imap.deliver(mail("Deals", from: "shop@example.org", list: true), to: "INBOX")
        try await withHarness(imap) { mailHarness in
            let syncer = mailHarness.syncer()
            try await syncer.syncFolders()
            try await syncer.sync(try mailHarness.folder(.inbox).id)
            #expect(try mailHarness.rows(.inbox).allSatisfy { $0.inboxClass == .other })
            try mailHarness.store.setOverride("shop@example.org", .other)

            try await withContacts(store: mailHarness.store, account: mailHarness.account) { h in
                let book = await h.server.addBook("Work")
                await h.server.putCard(card("b", given: "Bo", family: "Berg", email: "bo@example.org"), uid: "b", in: book)
                await h.server.putCard(card("s", given: "Shop", family: "Example", email: "shop@example.org"), uid: "s", in: book)
                try await h.syncer().sync()
            }

            let rows = try mailHarness.rows(.inbox)
            #expect(rows.first { $0.subject == "Club news" }?.inboxClass == .focused)
            #expect(rows.first { $0.subject == "Deals" }?.inboxClass == .other)
        }
    }

    @Test func newMailFromContactIsFocused() async throws {
        let imap = await standardServer()
        try await withHarness(imap) { mailHarness in
            try await withContacts(store: mailHarness.store, account: mailHarness.account) { h in
                let book = await h.server.addBook("Work")
                await h.server.putCard(card("b", given: "Bo", family: "Berg", email: "bo@example.org"), uid: "b", in: book)
                try await h.syncer().sync()
            }
            await imap.deliver(mail("Club news", from: "bo@example.org", list: true), to: "INBOX")
            let syncer = mailHarness.syncer()
            try await syncer.syncFolders()
            try await syncer.sync(try mailHarness.folder(.inbox).id)
            #expect(try mailHarness.rows(.inbox).first { $0.subject == "Club news" }?.inboxClass == .focused)
        }
    }
}
