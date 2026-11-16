// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import GRDB
import OutwrightModel
import Testing

@testable import OutwrightStore

private func details(
    _ given: String, _ family: String, email: String? = nil, org: String = ""
) -> ContactDetails {
    ContactDetails(
        givenName: given, familyName: family, organization: org,
        emails: email.map { [Labeled(label: "work", value: $0)] } ?? [])
}

private struct ContactFixture {
    let base: Fixture
    let book: AddressBook
    var store: MailStore { base.store }
    var account: AccountID { base.account.id }

    init() throws {
        base = try Fixture()
        var account = base.account
        account.cardDAV = "https://dav.example.org/"
        try base.store.save(account)
        base.store.replaceAddressBooksForTest(base.account.id)
        let books = try base.store.addressBooks(base.account.id)
        book = try #require(books.first)
    }

    @discardableResult
    func remote(_ href: String, _ details: ContactDetails, etag: String = "e1") throws -> Bool {
        try store.upsertRemote(
            href: href, etag: etag, vcard: Data("BEGIN:VCARD".utf8), details: details, photo: nil,
            in: book.id)
    }
}

extension MailStore {
    fileprivate func replaceAddressBooksForTest(_ account: AccountID) {
        try? replaceAddressBooks([(href: "/book/", name: "Contacts", isReadOnly: false)], for: account)
    }
}

@Suite struct ContactStoreTests {
    @Test func accountKeepsCardDAVFieldsAcrossSave() throws {
        let f = try Fixture()
        var account = f.account
        account.cardDAV = "https://dav.example.org/"
        account.cardDAVUnconfirmed = "https://other.example.net/"
        account.savesContactsToPhone = true
        try f.store.save(account)
        let read = try #require(try f.store.accounts().first)
        #expect(read.cardDAV == "https://dav.example.org/")
        #expect(read.cardDAVUnconfirmed == "https://other.example.net/")
        #expect(read.savesContactsToPhone)
    }

    @Test func migrationFromV3KeepsAccounts() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("v3-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let id = UUID().uuidString
        do {
            let old = try DatabaseQueue(path: url.path)
            try Schema.migrator().migrate(old, upTo: "v3")
            try old.write { database in
                try database.execute(
                    sql: """
                        INSERT INTO account (id, displayName, email, colorIndex, imapHost, imapPort,
                            imapSecurity, smtpHost, smtpPort, smtpSecurity, user, signature, sortOrder)
                        VALUES (?, 'Anna', 'anna@example.org', 0, 'm.example.org', 993, 'tls',
                            'm.example.org', 465, 'tls', 'anna', '', 0)
                        """, arguments: [id])
            }
        }
        let store = try MailStore(path: url)
        let account = try #require(try store.accounts().first)
        #expect(account.email == "anna@example.org")
        #expect(account.cardDAV == nil)
        #expect(!account.savesContactsToPhone)
    }

    @Test func upsertAndRemoveFollowTheServer() throws {
        let f = try ContactFixture()
        #expect(try f.remote("/book/a.vcf", details("Bo", "Berg", email: "Bo@Example.org")))
        #expect(try f.remote("/book/b.vcf", details("Cia", "Carlsson")))
        #expect(try f.store.remoteETags(f.book.id) == ["/book/a.vcf": "e1", "/book/b.vcf": "e1"])
        try f.remote("/book/a.vcf", details("Bo", "Bergman"), etag: "e2")
        let all = try f.store.contacts(in: nil, matching: nil)
        #expect(all.count == 2)
        #expect(all.first?.details.familyName == "Bergman")
        #expect(try f.store.remoteETags(f.book.id)["/book/a.vcf"] == "e2")
        try f.store.removeRemote(hrefs: ["/book/a.vcf"], in: f.book.id)
        #expect(try f.store.contacts(in: [f.book.id], matching: nil).map(\.details.familyName) == ["Carlsson"])
        try f.store.setSyncToken("tok", for: f.book.id)
        #expect(try f.store.syncToken(f.book.id) == "tok")
        try f.store.setSyncToken(nil, for: f.book.id)
        #expect(try f.store.syncToken(f.book.id) == nil)
    }

    @Test func contactsSortByFamilyNameIgnoringCaseAndAccents() throws {
        let f = try ContactFixture()
        try f.remote("/1", details("A", "Åberg"))
        try f.remote("/2", details("B", "abel"))
        try f.remote("/3", details("C", "Öst"))
        try f.remote("/4", details("D", "Zorn"))
        try f.remote("/5", details("E", "Éklund"))
        try f.remote("/6", details("F", "Ek"))
        let names = try f.store.contacts(in: nil, matching: nil).map(\.details.familyName)
        #expect(names == ["abel", "Ek", "Éklund", "Zorn", "Åberg", "Öst"])
    }

    @Test func searchMatchesNameOrganisationAndEmail() throws {
        let f = try ContactFixture()
        try f.remote("/1", details("Anna", "Lind", email: "anna@example.org"))
        try f.remote("/2", details("Bo", "Berg", org: "Acme Verkstad"))
        try f.remote("/3", details("Cia", "Ek", email: "cia@Work.example.org"))
        func found(_ text: String) throws -> [String] {
            try f.store.contacts(in: nil, matching: text).map(\.details.givenName)
        }
        #expect(try found("lind") == ["Anna"])
        #expect(try found("verkstad") == ["Bo"])
        #expect(try found("WORK.example") == ["Cia"])
        #expect(try found("zzz").isEmpty)
        #expect(try found("").count == 3)
    }

    @Test func ownerEditIsQueuedAndAnnounced() async throws {
        let f = try ContactFixture()
        var announced = f.store.queuedActions().makeAsyncIterator()
        let id = try f.store.createContact(details("Ny", "Person", email: "ny@example.org"), in: f.book.id)
        #expect(await announced.next() == f.account)
        var pending = try f.store.pendingContactChanges(f.account)
        #expect(pending.map(\.change) == [.create])
        #expect(pending.first?.href == nil)
        #expect(pending.first?.book == f.book.id)
        try f.store.contactChangeDone(
            id, href: "/book/ny.vcf", etag: "e9", vcard: Data("v".utf8), revision: try #require(pending.first?.revision))
        #expect(try f.store.pendingContactChanges(f.account).isEmpty)
        try f.store.updateContact(id, details("Ny", "Persson"))
        #expect(await announced.next() == f.account)
        pending = try f.store.pendingContactChanges(f.account)
        #expect(pending.map(\.change) == [.update])
        #expect(pending.first?.href == "/book/ny.vcf")
        #expect(pending.first?.etag == "e9")
        #expect(pending.first?.vcard == Data("v".utf8))
        try f.store.deleteContact(id)
        #expect(try f.store.contacts(in: nil, matching: nil).isEmpty)
        #expect(try f.store.pendingContactChanges(f.account).map(\.change) == [.delete])
        let last = try #require(try f.store.pendingContactChanges(f.account).first?.revision)
        try f.store.contactChangeDone(id, href: "/book/ny.vcf", etag: nil, vcard: Data(), revision: last)
        #expect(try f.store.contact(id) == nil)
    }

    @Test func queuedContactIsNotOverwrittenByServer() throws {
        let f = try ContactFixture()
        try f.remote("/1", details("Bo", "Berg"))
        let id = try #require(try f.store.contacts(in: nil, matching: nil).first?.id)
        try f.store.updateContact(id, details("Bo", "Own"))
        #expect(try f.remote("/1", details("Bo", "Server"), etag: "e2") == false)
        #expect(try f.store.contact(id)?.details.familyName == "Own")
        try f.store.removeRemote(hrefs: ["/1"], in: f.book.id)
        #expect(try f.store.contact(id) != nil)
    }

    private func conflicted() throws -> (ContactFixture, ContactID) {
        let f = try ContactFixture()
        try f.remote("/1", details("Bo", "Berg"))
        let id = try #require(try f.store.contacts(in: nil, matching: nil).first?.id)
        try f.store.updateContact(id, details("Bo", "Own"))
        try f.store.contactChangeConflicted(
            id, server: (etag: "e7", vcard: Data("s".utf8), details: details("Bo", "Server")))
        return (f, id)
    }

    @Test func freshOwnerEditSupersedesHeldConflict() throws {
        let (f, id) = try conflicted()
        try f.store.updateContact(id, details("Bo", "New"))
        let contact = try #require(try f.store.contact(id))
        #expect(contact.conflict == nil)
        #expect(!contact.changeFailed)
        #expect(try f.store.pendingContactChanges(f.account).map(\.change) == [.update])
    }

    @Test func readOnlyBookRefusesOwnerEdits() throws {
        let f = try ContactFixture()
        try f.remote("/1", details("Bo", "Berg"))
        let id = try #require(try f.store.contacts(in: nil, matching: nil).first?.id)
        try f.store.replaceAddressBooks([(href: "/book/", name: "Contacts", isReadOnly: true)], for: f.account)
        #expect(throws: StoreError.readOnlyAddressBook) { try f.store.updateContact(id, details("Bo", "X")) }
        #expect(throws: StoreError.readOnlyAddressBook) { try f.store.deleteContact(id) }
        #expect(throws: StoreError.readOnlyAddressBook) { _ = try f.store.createContact(details("Ny", "X"), in: f.book.id) }
        #expect(try f.store.pendingContactChanges(f.account).isEmpty)
        #expect(try f.store.contacts(in: nil, matching: nil).count == 1)
    }

    @Test func conflictKeepsBothVersions() throws {
        let (f, id) = try conflicted()
        let contact = try #require(try f.store.contact(id))
        #expect(contact.details.familyName == "Server")
        #expect(contact.conflict?.familyName == "Own")
        #expect(try f.store.pendingContactChanges(f.account).isEmpty)
        #expect(try f.store.remoteETags(f.book.id)["/1"] == "e7")
    }

    @Test func applyConflictAgainQueuesUpdate() throws {
        let (f, id) = try conflicted()
        try f.store.applyConflictAgain(id)
        let contact = try #require(try f.store.contact(id))
        #expect(contact.details.familyName == "Own")
        #expect(contact.conflict == nil)
        let pending = try f.store.pendingContactChanges(f.account)
        #expect(pending.map(\.change) == [.update])
        #expect(pending.first?.etag == "e7")
    }

    @Test func discardConflictDropsOwnVersion() throws {
        let (f, id) = try conflicted()
        try f.store.discardConflict(id)
        let contact = try #require(try f.store.contact(id))
        #expect(contact.details.familyName == "Server")
        #expect(contact.conflict == nil)
        #expect(try f.store.pendingContactChanges(f.account).isEmpty)
    }

    @Test func failedChangeStopsRetrying() throws {
        let f = try ContactFixture()
        let id = try f.store.createContact(details("Ny", "Person"), in: f.book.id)
        try f.store.contactChangeFailed(
            id, revision: try #require(try f.store.pendingContactChanges(f.account).first?.revision))
        #expect(try f.store.pendingContactChanges(f.account).isEmpty)
        #expect(try f.store.contact(id)?.changeFailed == true)
    }

    @Test func removedBookKeepsContactsWithQueuedChanges() throws {
        let f = try ContactFixture()
        try f.remote("/book/a.vcf", details("Bo", "Berg"))
        try f.remote("/book/b.vcf", details("Cia", "Carlsson"))
        let queued = try #require(try f.store.contacts(in: nil, matching: "Berg").first?.id)
        try f.store.updateContact(queued, details("Bo", "Own"))
        try f.store.replaceAddressBooks(
            [(href: "/other/", name: "Other", isReadOnly: true)], for: f.account)
        let books = try f.store.addressBooks(f.account)
        #expect(books.map(\.href) == ["/other/"])
        #expect(books.first?.isReadOnly == true)
        let left = try f.store.contacts(in: nil, matching: nil)
        #expect(left.map(\.id) == [queued])
        #expect(left.first?.changeFailed == true)
        #expect(try f.store.pendingContactChanges(f.account).isEmpty)
    }

    @Test func removedBookDropsContactsWithQueuedDelete() throws {
        let f = try ContactFixture()
        try f.remote("/book/a.vcf", details("Bo", "Berg"))
        let gone = try #require(try f.store.contacts(in: nil, matching: "Berg").first?.id)
        try f.store.deleteContact(gone)
        let unsent = try f.store.createContact(details("Ny", "Person"), in: f.book.id)
        try f.store.deleteContact(unsent)
        try f.store.replaceAddressBooks([], for: f.account)
        #expect(try f.store.contact(gone) == nil)
        #expect(try f.store.contact(unsent) == nil)
        #expect(try f.store.contacts(in: nil, matching: nil).isEmpty)
    }

    @Test func knownSendersIncludesContacts() throws {
        let f = try ContactFixture()
        _ = try f.base.store.upsert([
            row(f.account, f.base.sent.id, uid: 1, to: ["Sent@Example.org"])
        ])
        try f.remote("/1", details("Bo", "Berg", email: "Bo@Example.org"))
        #expect(try f.store.contactEmails(f.account) == ["bo@example.org"])
        #expect(try f.store.knownSenders(f.account) == ["sent@example.org", "bo@example.org"])
        #expect(try f.store.contacts(withEmail: "BO@example.org").count == 1)
    }

    @Test func focusContactsMailMovesOtherButNotOverridden() throws {
        let f = try ContactFixture()
        try f.remote("/1", details("Bo", "Berg", email: "bo@example.org"))
        try f.remote("/2", details("Cia", "Ek", email: "cia@example.org"))
        _ = try f.store.upsert([
            row(f.account, f.base.inbox.id, uid: 1, from: "Bo@example.org", cls: .other),
            row(f.account, f.base.inbox.id, uid: 2, from: "cia@example.org", cls: .other),
            row(f.account, f.base.inbox.id, uid: 3, from: "zed@example.org", cls: .other)
        ])
        try f.store.setOverride("cia@example.org", .other)
        #expect(try f.store.focusContactsMail(f.account) == 1)
        let rows = try f.store.messages(allInbox, limit: 10)
        let byUID = Dictionary(uniqueKeysWithValues: rows.map { ($0.uid, $0.inboxClass) })
        #expect(byUID[1] == .focused)
        #expect(byUID[2] == .other)
        #expect(byUID[3] == .other)
    }

    @Test func messagesInvolvingFindsSenderAndRecipients() throws {
        let f = try ContactFixture()
        _ = try f.base.store.upsert([
            row(f.account, f.base.inbox.id, uid: 1, from: "Bo@Example.org", minutes: 1),
            row(f.account, f.base.sent.id, uid: 2, to: ["x@example.org", "Bo@Example.org"], minutes: 3),
            row(f.account, f.base.inbox.id, uid: 3, from: "zed@example.org", minutes: 2),
            row(f.account, f.base.inbox.id, uid: 4, from: "bob@example.org", minutes: 4)
        ])
        let found = try f.store.messages(involving: "BO@example.org", limit: 10)
        #expect(found.map(\.uid) == [2, 1])
        #expect(try f.store.messages(involving: "bo@example.org", limit: 1).count == 1)
    }

    private func sent(_ f: ContactFixture) throws -> ContactID {
        try f.remote("/1", details("Bo", "Berg"))
        let id = try #require(try f.store.contacts(in: nil, matching: nil).first?.id)
        try f.store.updateContact(id, details("Bo", "First"))
        return id
    }

    @Test func theOwnersVersionOfAConflictForgetsWhereItsEntriesCameFrom() throws {
        let f = try ContactFixture()
        var bo = details("Bo", "Berg")
        bo.emails = [Labeled(label: "work", value: "a@example.org", origin: 0)]
        try f.remote("/1", bo)
        let id = try #require(try f.store.contacts(in: nil, matching: nil).first?.id)
        var own = bo
        own.emails[0].value = "a2@example.org"
        try f.store.updateContact(id, own)
        try f.store.contactChangeConflicted(
            id, server: (etag: "e7", vcard: Data("s".utf8), details: details("Bo", "Server")))
        // Its places were in the card it was edited from; the card held now is the server's.
        #expect(try f.store.contact(id)?.conflict?.emails.map(\.origin) == [nil])
        try f.store.applyConflictAgain(id)
        #expect(try f.store.contact(id)?.details.emails.map(\.origin) == [nil])
    }

    @Test func anEditMadeDuringASendForgetsWhereItsEntriesCameFrom() throws {
        let f = try ContactFixture()
        var bo = details("Bo", "Berg")
        bo.emails = [Labeled(label: "work", value: "a@example.org", origin: 0)]
        try f.remote("/1", bo)
        let id = try #require(try f.store.contacts(in: nil, matching: nil).first?.id)
        var first = bo
        first.familyName = "First"
        try f.store.updateContact(id, first)
        let rev = try #require(try f.store.pendingContactChanges(f.account).first?.revision)
        var second = first
        second.emails[0].value = "a2@example.org"
        try f.store.updateContact(id, second)
        try f.store.contactChangeDone(id, href: "/1", etag: "e5", vcard: Data("n".utf8), revision: rev)
        // The card held is now the one sent, which the edit's places were not counted in.
        #expect(try f.store.contact(id)?.details.emails.map(\.origin) == [nil])
    }

    @Test func conflictSurvivesBookRemovalAndServerDelete() throws {
        let (f, id) = try conflicted()
        try f.store.removeRemote(hrefs: ["/1"], in: f.book.id)
        #expect(try f.store.contact(id)?.conflict?.familyName == "Own")
        try f.store.replaceAddressBooks([(href: "/x/", name: "X", isReadOnly: false)], for: f.account)
        #expect(try f.store.contact(id)?.conflict?.familyName == "Own")
    }

    @Test func serverUpdateRefreshesCopyButKeepsConflict() throws {
        let (f, id) = try conflicted()
        #expect(try f.remote("/1", details("Bo", "Newer"), etag: "e8"))
        let contact = try #require(try f.store.contact(id))
        #expect(contact.details.familyName == "Newer")
        #expect(contact.conflict?.familyName == "Own")
        #expect(try f.store.remoteETags(f.book.id)["/1"] == "e8")
    }

    @Test func failedEditSurvivesServerAndBookRemoval() throws {
        let f = try ContactFixture()
        let id = try sent(f)
        let rev = try #require(try f.store.pendingContactChanges(f.account).first?.revision)
        try f.store.contactChangeFailed(id, revision: rev)
        #expect(try f.remote("/1", details("Bo", "Server"), etag: "e2") == false)
        try f.store.removeRemote(hrefs: ["/1"], in: f.book.id)
        try f.store.replaceAddressBooks([(href: "/x/", name: "X", isReadOnly: false)], for: f.account)
        let contact = try #require(try f.store.contact(id))
        #expect(contact.details.familyName == "First")
        #expect(contact.changeFailed)
    }

    @Test func editDuringSendKeepsNewerChange() throws {
        let f = try ContactFixture()
        let id = try sent(f)
        let rev = try #require(try f.store.pendingContactChanges(f.account).first?.revision)
        try f.store.updateContact(id, details("Bo", "Second"))
        try f.store.contactChangeDone(id, href: "/1", etag: "e5", vcard: Data("n".utf8), revision: rev)
        let pending = try #require(try f.store.pendingContactChanges(f.account).first)
        #expect(pending.change == .update)
        #expect(pending.etag == "e5")
        #expect(pending.vcard == Data("n".utf8))
        #expect(try f.store.contact(id)?.details.familyName == "Second")
    }

    @Test func deleteDuringSendStaysADelete() throws {
        let f = try ContactFixture()
        let id = try sent(f)
        let rev = try #require(try f.store.pendingContactChanges(f.account).first?.revision)
        try f.store.deleteContact(id)
        try f.store.contactChangeDone(id, href: "/1", etag: "e5", vcard: Data("n".utf8), revision: rev)
        let pending = try #require(try f.store.pendingContactChanges(f.account).first)
        #expect(pending.change == .delete)
        #expect(pending.etag == "e5")
    }

    @Test func conflictDuringNewerEditHoldsTheEdit() throws {
        let f = try ContactFixture()
        let id = try sent(f)
        try f.store.updateContact(id, details("Bo", "Second"))
        try f.store.contactChangeConflicted(
            id, server: (etag: "e6", vcard: Data("s".utf8), details: details("Bo", "Server")))
        let contact = try #require(try f.store.contact(id))
        #expect(contact.details.familyName == "Server")
        #expect(contact.conflict?.familyName == "Second")
        #expect(try f.store.pendingContactChanges(f.account).isEmpty)
        #expect(try f.store.remoteETags(f.book.id)["/1"] == "e6")
        try f.store.applyConflictAgain(id)
        let again = try #require(try f.store.pendingContactChanges(f.account).first)
        #expect(again.etag == "e6")
        #expect(try f.store.contact(id)?.details.familyName == "Second")
    }

    @Test func conflictDuringNewerDeleteIsAFailedChange() throws {
        let f = try ContactFixture()
        let id = try sent(f)
        try f.store.deleteContact(id)
        try f.store.contactChangeConflicted(
            id, server: (etag: "e6", vcard: Data("s".utf8), details: details("Bo", "Server")))
        let contact = try #require(try f.store.contacts(in: nil, matching: nil).first { $0.id == id })
        #expect(contact.details.familyName == "Server")
        #expect(contact.conflict == nil)
        #expect(contact.changeFailed)
        #expect(try f.store.pendingContactChanges(f.account).isEmpty)
        // Deleting again is a new delete, over the server's card.
        try f.store.deleteContact(id)
        let again = try #require(try f.store.pendingContactChanges(f.account).first)
        #expect(again.change == .delete && again.etag == "e6")
        #expect(try f.store.contact(id)?.changeFailed == false)
    }

    @Test func deleteThatMeetsAConflictIsAFailedChangeUntilDiscarded() throws {
        let f = try ContactFixture()
        try f.remote("/1", details("Bo", "Berg"))
        let id = try #require(try f.store.contacts(in: nil, matching: nil).first?.id)
        try f.store.deleteContact(id)
        try f.store.contactChangeConflicted(
            id, server: (etag: "e6", vcard: Data("s".utf8), details: details("Bo", "Server")))
        let contact = try #require(try f.store.contacts(in: nil, matching: nil).first { $0.id == id })
        #expect(contact.details.familyName == "Server")
        #expect(contact.changeFailed && contact.conflict == nil)
        #expect(try f.store.pendingContactChanges(f.account).isEmpty)
        try f.store.restoreServerVersion(id, details: details("Bo", "Server"), photo: nil)
        let discarded = try #require(try f.store.contact(id))
        #expect(!discarded.changeFailed && discarded.details.familyName == "Server")
        #expect(try f.store.pendingContactChanges(f.account).isEmpty)
    }

    @Test func aStaleFailureLeavesTheNewerEditQueued() throws {
        let f = try ContactFixture()
        let id = try sent(f)
        let rev = try #require(try f.store.pendingContactChanges(f.account).first?.revision)
        try f.store.updateContact(id, details("Bo", "Second"))
        try f.store.contactChangeFailed(id, revision: rev)
        let pending = try f.store.pendingContactChanges(f.account)
        #expect(pending.count == 1 && pending.first?.revision != rev)
        #expect(try f.store.contact(id)?.changeFailed == false)
        #expect(try f.store.contact(id)?.details.familyName == "Second")
    }

    @Test func conflictAfterDiscardDuringSendShowsTheServersCard() throws {
        let f = try ContactFixture()
        let id = try sent(f)
        try f.store.restoreServerVersion(id, details: details("Bo", "Berg"), photo: nil)
        try f.store.contactChangeConflicted(
            id, server: (etag: "e6", vcard: Data("s".utf8), details: details("Bo", "Server")))
        let contact = try #require(try f.store.contact(id))
        #expect(contact.details.familyName == "Server")
        #expect(contact.conflict == nil)
        #expect(try f.store.pendingContactChanges(f.account).isEmpty)
        #expect(try f.store.remoteETags(f.book.id)["/1"] == "e6")
    }

    @Test func editedCreateStaysACreateWithoutHref() throws {
        let f = try ContactFixture()
        let id = try f.store.createContact(details("Ny", "Person"), in: f.book.id)
        try f.store.contactChangeFailed(
            id, revision: try #require(try f.store.pendingContactChanges(f.account).first?.revision))
        try f.store.updateContact(id, details("Ny", "Persson"))
        #expect(try f.store.pendingContactChanges(f.account).map(\.change) == [.create])
        try f.store.updateContact(id, details("Ny", "Pers"))
        #expect(try f.store.pendingContactChanges(f.account).map(\.change) == [.create])
    }

    @Test func applyConflictAgainKeepsNewerEditAndClearsFailure() throws {
        let (f, id) = try conflicted()
        try f.store.updateContact(id, details("Bo", "Newest"))
        try f.store.applyConflictAgain(id)
        let contact = try #require(try f.store.contact(id))
        #expect(contact.details.familyName == "Newest")
        #expect(contact.conflict == nil)
        #expect(!contact.changeFailed)
        #expect(try f.store.pendingContactChanges(f.account).map(\.change) == [.update])
    }

    @Test func deletedUnsentCreateIsAQueuedDelete() throws {
        let f = try ContactFixture()
        let id = try f.store.createContact(details("Ny", "Person", email: "ny@example.org"), in: f.book.id)
        let sent = try #require(try f.store.pendingContactChanges(f.account).first)
        try f.store.deleteContact(id)
        #expect(try f.store.contacts(in: nil, matching: nil).isEmpty)
        #expect(try f.store.contactEmails(f.account).isEmpty)
        let pending = try #require(try f.store.pendingContactChanges(f.account).first)
        #expect(pending.change == .delete)
        #expect(pending.href == nil)
        #expect(pending.revision > sent.revision)
        // The create's PUT was answered after the delete: its address is kept, so the delete is sent.
        try f.store.contactChangeDone(
            id, href: "/book/ny.vcf", etag: "e1", vcard: Data("v".utf8), revision: sent.revision)
        let after = try #require(try f.store.pendingContactChanges(f.account).first)
        #expect(after.change == .delete)
        #expect(after.href == "/book/ny.vcf")
    }

    @Test func createTargetIsKeptUntilDone() throws {
        let f = try ContactFixture()
        let id = try f.store.createContact(details("Ny", "Person"), in: f.book.id)
        try f.store.setCreateTarget(id, href: "/book/ny.vcf", vcard: Data("v".utf8))
        #expect(try f.store.createTarget(id)?.href == "/book/ny.vcf")
        let sent = try #require(try f.store.pendingContactChanges(f.account).first)
        try f.store.contactChangeDone(id, href: "/book/ny.vcf", etag: "e1", vcard: Data("v".utf8), revision: sent.revision)
        #expect(try f.store.createTarget(id) == nil)
    }

    @Test func focusIgnoresContactWithQueuedDelete() throws {
        let f = try ContactFixture()
        try f.remote("/1", details("Bo", "Berg", email: "bo@example.org"))
        _ = try f.store.upsert([row(f.account, f.base.inbox.id, uid: 1, from: "bo@example.org", cls: .other)])
        try f.store.deleteContact(try #require(try f.store.contacts(in: nil, matching: nil).first?.id))
        #expect(try f.store.focusContactsMail(f.account) == 0)
    }

    @Test func decodeNeverTrapsAndReadsOlderShapes() throws {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            let bytes = (0..<Int.random(in: 0..<200, using: &generator)).map { _ in
                UInt8.random(in: 0...255, using: &generator)
            }
            _ = ContactRecords.decode(String(decoding: bytes, as: UTF8.self))
        }
        _ = ContactRecords.decode(nil)
        let older = try #require(ContactRecords.decode(#"{"givenName":"Bo"}"#))
        #expect(older.givenName == "Bo")
        #expect(older.emails.isEmpty)
        let f = try ContactFixture()
        try f.remote("/1", details("Bo", "Berg"))
        try f.store.write { database in
            try database.execute(sql: "UPDATE contact SET detailsJSON = 'not json'")
        }
        #expect(try f.store.contacts(in: nil, matching: nil).count == 1)
    }

    @Test func restoringTheServerVersionEndsAFailedChange() throws {
        let f = try ContactFixture()
        try f.remote("/book/b.vcf", details("Bo", "Berg"))
        let bo = try #require(try f.store.contacts(in: nil, matching: nil).first)
        try f.store.updateContact(bo.id, details("Bo", "Own"))
        try f.store.contactChangeFailed(
            bo.id, revision: try #require(try f.store.pendingContactChanges(f.account).first?.revision))
        #expect(try f.store.serverCard(bo.id) == Data("BEGIN:VCARD".utf8))

        try f.store.restoreServerVersion(bo.id, details: details("Bo", "Berg"), photo: nil)

        let after = try #require(try f.store.contact(bo.id))
        #expect(!after.changeFailed)
        #expect(after.details.familyName == "Berg")
        #expect(try f.store.pendingContactChanges(f.account).isEmpty)
        // The server's next version comes in again.
        #expect(try f.remote("/book/b.vcf", details("Bo", "Server"), etag: "e2"))
        #expect(try f.store.contact(bo.id)?.details.familyName == "Server")
    }

    @Test func restoringAContactTheServerNeverHadRemovesIt() throws {
        let f = try ContactFixture()
        let id = try f.store.createContact(details("Ny", "Person"), in: f.book.id)
        try f.store.contactChangeFailed(
            id, revision: try #require(try f.store.pendingContactChanges(f.account).first?.revision))
        #expect(try f.store.serverCard(id) == nil)

        try f.store.restoreServerVersion(id, details: nil, photo: nil)

        #expect(try f.store.contact(id) == nil)
    }

    @Test func unreadableDetailsCannotBeEditedUntilRepaired() throws {
        let f = try ContactFixture()
        try f.remote("/1", details("Bo", "Berg"))
        let bo = try #require(try f.store.contacts(in: nil, matching: nil).first)
        try f.store.write { database in
            try database.execute(sql: "UPDATE contact SET detailsJSON = 'not json'")
        }
        #expect(throws: StoreError.unreadableContact) { try f.store.updateContact(bo.id, details("Bo", "Own")) }
        #expect(try f.store.unreadableContacts(f.account).map(\.contact) == [bo.id])

        try f.store.repairDetails(bo.id, details("Bo", "Berg"), photo: nil)

        #expect(try f.store.unreadableContacts(f.account).isEmpty)
        #expect(try f.store.contact(bo.id)?.details.familyName == "Berg")
        try f.store.updateContact(bo.id, details("Bo", "Own"))
    }

    @Test func repairingDetailsUnderAQueuedEditMarksTheEditFailed() throws {
        let f = try ContactFixture()
        try f.remote("/1", details("Bo", "Berg"))
        let bo = try #require(try f.store.contacts(in: nil, matching: nil).first)
        try f.store.updateContact(bo.id, details("Bo", "Own"))
        try f.store.write { database in
            try database.execute(sql: "UPDATE contact SET detailsJSON = 'not json'")
        }

        try f.store.repairDetails(bo.id, details("Bo", "Berg"), photo: nil)

        #expect(try f.store.pendingContactChanges(f.account).isEmpty)
        #expect(try f.store.contact(bo.id)?.changeFailed == true)
    }

    @Test func repairingDetailsIsAnnouncedAndSeenByAnOpenList() async throws {
        let f = try ContactFixture()
        try f.remote("/1", details("Bo", "Berg"))
        let bo = try #require(try f.store.contacts(in: nil, matching: nil).first)
        try f.store.write { database in
            try database.execute(sql: "UPDATE contact SET detailsJSON = 'not json'")
        }
        let store = f.store
        let announced = store.queuedActions()
        let changes = store.observeContacts()
        let seen = try await withThrowingTaskGroup(of: (AccountID?, Bool)?.self) { group in
            group.addTask {
                var changed = changes.makeAsyncIterator()
                _ = try await changed.next()
                var queued = announced.makeAsyncIterator()
                try store.repairDetails(bo.id, details("Bo", "Berg"), photo: nil)
                let account = await queued.next()
                return (account, try await changed.next() != nil)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                return nil
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }
        #expect(seen?.0 == f.account)
        #expect(seen?.1 == true)
    }

    @Test func clearingContactsLeavesOtherAccountsAlone() throws {
        let f = try ContactFixture()
        var other = Fixture.makeAccount(name: "Bo", email: "bo@example.org", order: 1)
        other.cardDAV = "https://dav.example.org/"
        try f.store.save(other)
        try f.store.replaceAddressBooks([(href: "/other/", name: "Other", isReadOnly: false)], for: other.id)
        let otherBook = try #require(try f.store.addressBooks(other.id).first)
        try f.store.upsertRemote(
            href: "/other/1", etag: "e", vcard: Data(), details: details("Cia", "Carlsson"), photo: nil, in: otherBook.id)
        try f.remote("/book/1", details("Bo", "Berg"))
        _ = try f.store.createContact(details("Ny", "Person"), in: f.book.id)
        #expect(try f.store.pendingContactChangeCount(f.account) == 1)

        try f.store.clearContacts(of: f.account)

        #expect(try f.store.addressBooks(f.account).isEmpty)
        #expect(try f.store.contacts(in: nil, matching: nil).map(\.details.name) == ["Cia Carlsson"])
        #expect(try f.store.pendingContactChangeCount(f.account) == 0)
    }

    @Test func accountWithoutCardDAVTakesNoContactsOrEdits() throws {
        let f = try ContactFixture()
        try f.remote("/book/1", details("Bo", "Berg"))
        let bo = try #require(try f.store.contacts(in: nil, matching: nil).first)
        var account = try #require(try f.store.accounts().first { $0.id == f.account })
        account.cardDAV = nil
        try f.store.save(account)

        #expect(throws: StoreError.noCardDAV) { try f.store.createContact(details("Ny", "Person"), in: f.book.id) }
        #expect(throws: StoreError.noCardDAV) { try f.store.updateContact(bo.id, details("Bo", "Own")) }
        #expect(throws: StoreError.noCardDAV) { try f.store.deleteContact(bo.id) }
        try f.store.replaceAddressBooks([(href: "/new/", name: "New", isReadOnly: false)], for: f.account)
        #expect(try f.store.addressBooks(f.account).isEmpty)
    }

    /// A Microsoft account's contacts come through Graph: it takes books and edits without CardDAV.
    @Test func microsoftAccountAcceptsEdits() throws {
        let f = try ContactFixture()
        try f.remote("/book/1", details("Bo", "Berg"))
        let bo = try #require(try f.store.contacts(in: nil, matching: nil).first)
        var account = try #require(try f.store.accounts().first { $0.id == f.account })
        account.cardDAV = nil
        account.contactsVia = .graph
        try f.store.save(account)

        _ = try f.store.createContact(details("Ny", "Person"), in: f.book.id)
        try f.store.updateContact(bo.id, details("Bo", "Own"))
        try f.store.replaceAddressBooks([(href: "me", name: "Contacts", isReadOnly: false)], for: f.account)
        #expect(try f.store.addressBooks(f.account).map(\.href) == ["me"])
    }
}
