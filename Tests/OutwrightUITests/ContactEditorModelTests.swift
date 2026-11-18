// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import ImageIO
import OutwrightFakes
import OutwrightMIME
import OutwrightModel
import OutwrightStore
import OutwrightSync
import Testing

@testable import OutwrightUI

@MainActor @Suite struct ContactEditorModelTests {
    private struct Fixture {
        let app: AppModel
        let box: Mailbox
        let accounts: [Account]
        /// Anna's writable book, Anna's read-only book, Home's writable book.
        let books: [AddressBook]
    }

    private func fixture() throws -> Fixture {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org", cardDAV: true)
        let home = try box.addAccount("home@example.org", cardDAV: true)
        try box.store.replaceAddressBooks(
            [("/a/", "Anna work", false), ("/b/", "Shared", true)], for: anna.id)
        try box.store.replaceAddressBooks([("/c/", "Home", false)], for: home.id)
        let annaBooks = try box.store.addressBooks(anna.id)
        let books = try annaBooks.filter { !$0.isReadOnly } + annaBooks.filter(\.isReadOnly)
            + box.store.addressBooks(home.id)
        let app = AppModel(store: box.store, sync: offlineSync(store: box.store, secrets: InMemorySecretStore()))
        return Fixture(app: app, box: box, accounts: [anna, home], books: books)
    }

    private func put(_ f: Fixture, in book: AddressBook, family: String = "Ek") throws -> ContactID {
        try f.box.store.createContact(
            ContactDetails(
                givenName: "Maja", familyName: family, emails: [Labeled(label: "work", value: "maja@example.org")]),
            in: book.id)
    }

    @Test func newContactDefaultsToCurrentAccountsFirstBook() throws {
        let f = try fixture()
        let first = ContactEditorModel(app: f.app, editing: nil, prefill: nil)
        #expect(first.book == f.books[0].id, "no account in view: the first account's first book")
        let home = try f.box.folder(f.accounts[1], .inbox)
        f.app.open(home.id)
        let model = ContactEditorModel(app: f.app, editing: nil, prefill: nil)
        #expect(model.book == f.books[2].id)
    }

    @Test func readOnlyBooksAreNotOffered() throws {
        let f = try fixture()
        let model = ContactEditorModel(app: f.app, editing: nil, prefill: nil)
        let offered = model.writableBooks.flatMap(\.books).map(\.id)
        #expect(offered == [f.books[0].id, f.books[2].id])
        #expect(model.writableBooks.map(\.account.id) == f.accounts.map(\.id))
    }

    @Test func accountWithOnlyReadOnlyBooksFallsToNext() throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org", cardDAV: true)
        let home = try box.addAccount("home@example.org", cardDAV: true)
        try box.store.replaceAddressBooks([("/b/", "Shared", true)], for: anna.id)
        try box.store.replaceAddressBooks([("/c/", "Home", false)], for: home.id)
        let app = AppModel(store: box.store, sync: offlineSync(store: box.store, secrets: InMemorySecretStore()))
        let model = ContactEditorModel(app: app, editing: nil, prefill: nil)
        #expect(model.writableBooks.map(\.account.id) == [home.id])
        #expect(model.book == (try box.store.addressBooks(home.id)).first?.id)
    }

    @Test func prefilledAddressBecomesFirstEmail() throws {
        let f = try fixture()
        let model = ContactEditorModel(
            app: f.app, editing: nil, prefill: Address(name: "Stina Berg", email: "stina@example.org"))
        #expect(model.details.emails == [Labeled(label: "", value: "stina@example.org")])
        #expect(model.details.givenName == "Stina")
        #expect(model.details.familyName == "Berg")
        let bare = ContactEditorModel(app: f.app, editing: nil, prefill: Address(name: nil, email: "x@example.org"))
        #expect(bare.details.givenName.isEmpty && bare.details.emails.first?.value == "x@example.org")
    }

    @Test func jobTitleAndPhotoAreSaved() throws {
        let f = try fixture()
        let photo = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3])
        let model = ContactEditorModel(app: f.app, editing: nil, prefill: nil)
        model.details.givenName = "Maja"
        model.details.title = "  Chef "
        model.photo = photo
        let id = try model.save()
        let saved = try #require(try f.box.store.contact(id))
        #expect(saved.details.title == "Chef")
        #expect(saved.photo == photo)
        let edit = ContactEditorModel(app: f.app, editing: id, prefill: nil)
        #expect(edit.photo == photo)
        edit.photo = nil
        #expect(edit.hasChanges)
        _ = try edit.save()
        #expect(try f.box.store.contact(id)?.photo == nil, "a removed photo goes")
        #expect(try f.box.store.contact(id)?.details.title == "Chef")
    }

    @Test func pickedPhotoIsScaledDownToAJPEG() throws {
        let big = try #require(testPNG(width: 1_200, height: 900))
        let prepared = try #require(ContactPhotos.prepared(big))
        #expect(prepared.starts(with: [0xFF, 0xD8]), "a JPEG")
        let source = try #require(CGImageSourceCreateWithData(prepared as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let width = try #require((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue)
        let height = try #require((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue)
        #expect(max(width, height) == 512)
        #expect(ContactPhotos.prepared(Data("not a picture".utf8)) == nil)
    }

    @Test func anOddEmailIsFlaggedButStillSaved() throws {
        #expect(!ContactEditorModel.looksWrong(email: "maja@example.org"))
        #expect(!ContactEditorModel.looksWrong(email: ""))
        for odd in ["maja", "maja@", "@example.org", "maja@example", "ma ja@example.org", "a@b@example.org"] {
            #expect(ContactEditorModel.looksWrong(email: odd), "\(odd)")
        }
        let f = try fixture()
        let model = ContactEditorModel(app: f.app, editing: nil, prefill: nil)
        model.details.emails = [Labeled(label: "work", value: "maja")]
        #expect(model.canSave)
        let id = try model.save()
        #expect(try f.box.store.contact(id)?.details.emails.map(\.value) == ["maja"])
    }

    @Test func editorSaysWhenThereIsNoBook() throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org", cardDAV: true)
        try box.store.replaceAddressBooks([("/shared/", "Shared", true)], for: anna.id)
        let app = AppModel(store: box.store, sync: offlineSync(store: box.store, secrets: InMemorySecretStore()))
        let model = ContactEditorModel(app: app, editing: nil, prefill: nil)
        #expect(model.hasNoBook)
    }

    @Test func emptyContactCannotBeSaved() throws {
        let f = try fixture()
        let model = ContactEditorModel(app: f.app, editing: nil, prefill: nil)
        #expect(!model.canSave)
        #expect(throws: ContactEditError.empty) { try model.save() }
        model.details.emails = [Labeled(label: "", value: "   ")]
        #expect(!model.canSave, "blank rows are nothing")
        model.details.givenName = "Maja"
        #expect(model.canSave)
        model.book = nil
        #expect(!model.canSave)
        #expect(throws: ContactEditError.noBook) { try model.save() }
    }

    @Test func newContactIsSavedQueuedAndTrimmed() throws {
        let f = try fixture()
        let model = ContactEditorModel(app: f.app, editing: nil, prefill: nil)
        model.details.givenName = " Maja "
        model.details.phones = [Labeled(label: "mobile", value: "070 1"), Labeled(label: "home", value: "")]
        let id = try model.save()
        let stored = try #require(try f.box.store.contact(id))
        #expect(stored.details.givenName == "Maja")
        #expect(stored.details.phones.map(\.value) == ["070 1"], "blank rows dropped")
        #expect(stored.addressBookID == f.books[0].id)
        #expect(try f.box.store.pendingContactChanges(f.accounts[0].id).map(\.change) == [.create])
    }

    @Test func editSavesAndQueues() throws {
        let f = try fixture()
        let id = try put(f, in: f.books[0])
        let model = ContactEditorModel(app: f.app, editing: id, prefill: nil)
        #expect(model.details.familyName == "Ek")
        #expect(model.book == f.books[0].id)
        model.details.familyName = "Berg"
        model.details.emails.append(Labeled(label: "home", value: "m@example.org"))
        _ = try model.save()
        let stored = try #require(try f.box.store.contact(id))
        #expect(stored.details.familyName == "Berg")
        #expect(stored.details.emails.count == 2)
        #expect(stored.details.name == "Maja Berg", "a changed name is not held back by an old display name")
        #expect(try f.box.store.pendingContactChanges(f.accounts[0].id).count == 1)
    }

    @Test func anEditedEntryKeepsWhereItCameFromWhenAnotherIsRemoved() throws {
        let f = try fixture()
        let id = try f.box.store.createContact(
            ContactDetails(
                givenName: "Maja",
                emails: [
                    Labeled(label: "work", value: "maja@example.org", origin: 0),
                    Labeled(label: "home", value: "m@example.org", origin: 1),
                ],
                addresses: [
                    PostalAddress(label: "work", street: "Storgatan 1", origin: 0),
                    PostalAddress(label: "home", street: "Lillgatan 2", origin: 1),
                ]),
            in: f.books[0].id)
        let model = ContactEditorModel(app: f.app, editing: id, prefill: nil)
        model.details.emails.removeFirst()
        model.details.emails[0].value = " m2@example.org "
        model.details.addresses.removeFirst()
        model.details.addresses[0].street = "Lillgatan 3"
        _ = try model.save()
        let stored = try #require(try f.box.store.contact(id))
        #expect(stored.details.emails == [Labeled(label: "home", value: "m2@example.org")])
        #expect(stored.details.emails.map(\.origin) == [1])
        #expect(stored.details.addresses.map(\.origin) == [1])
    }

    @Test func saveKeepsWhatSyncChangedMeanwhile() throws {
        let f = try fixture()
        let id = try put(f, in: f.books[0])
        let store = f.box.store
        let sent = try #require(try store.pendingContactChanges(f.accounts[0].id).first)
        try store.contactChangeDone(id, href: "/a/1", etag: "e1", vcard: Data("v".utf8), revision: sent.revision)
        let model = ContactEditorModel(app: f.app, editing: id, prefill: nil)
        var server = model.details
        server.note = "From the server"
        try store.upsertRemote(
            href: "/a/1", etag: "e2", vcard: Data("v2".utf8), details: server, photo: nil, in: f.books[0].id)
        model.details.phones = [Labeled(label: "mobile", value: "070 9")]
        _ = try model.save()
        let stored = try #require(try store.contact(id))
        #expect(stored.details.note == "From the server")
        #expect(stored.details.phones.map(\.value) == ["070 9"])
    }

    @Test func hasChangesOnlyAfterAnEdit() throws {
        let f = try fixture()
        let id = try put(f, in: f.books[0])
        let model = ContactEditorModel(app: f.app, editing: id, prefill: nil)
        #expect(!model.hasChanges)
        model.details.note = "x"
        #expect(model.hasChanges)
        let fresh = ContactEditorModel(app: f.app, editing: nil, prefill: Address(name: nil, email: "a@example.org"))
        #expect(!fresh.hasChanges, "a prefilled address is not typed input")
    }

    @Test func contactInReadOnlyBookCannotBeEdited() throws {
        let f = try fixture()
        let id = try put(f, in: f.books[0])
        let card = PersonCardModel(app: f.app, request: PersonRequest(contact: id))
        card.reload()
        #expect(card.canEdit)
        try f.box.store.replaceAddressBooks(
            [("/a/", "Anna work", true), ("/b/", "Shared", true)], for: f.accounts[0].id)
        card.reload()
        #expect(!card.canEdit)
        let stranger = PersonCardModel(
            app: f.app, request: PersonRequest(address: Address(name: nil, email: "who@example.org")))
        stranger.reload()
        #expect(!stranger.canEdit, "no contact, nothing to edit")
    }

    @Test func failedObservationSurfacesButCancellationDoesNot() async throws {
        let f = try fixture()
        let failing = ContactsModel(app: f.app)
        let broken = AsyncThrowingStream<Void, any Error> { $0.finish(throwing: StoreError.database) }
        await failing.watch(broken)
        #expect(failing.failed)
        let cancelled = ContactsModel(app: f.app)
        let stopped = AsyncThrowingStream<Void, any Error> { $0.finish(throwing: CancellationError()) }
        await cancelled.watch(stopped)
        #expect(!cancelled.failed)
    }

    @Test func deleteQueuesAndHides() throws {
        let f = try fixture()
        let id = try put(f, in: f.books[0])
        let editor = ContactEditorModel(app: f.app, editing: id, prefill: nil)
        try editor.delete()
        #expect(try f.box.store.contacts(in: nil, matching: nil).isEmpty)
        #expect(try f.box.store.pendingContactChanges(f.accounts[0].id).map(\.change) == [.delete])
    }

    private func conflicted(_ f: Fixture) throws -> ContactID {
        let id = try put(f, in: f.books[0], family: "Mine")
        let store = f.box.store
        let sent = try #require(try store.pendingContactChanges(f.accounts[0].id).first { $0.contact == id })
        try store.contactChangeDone(id, href: "/a/1", etag: "e1", vcard: Data("v".utf8), revision: sent.revision)
        try store.updateContact(id, ContactDetails(givenName: "Maja", familyName: "Mine2"))
        try store.contactChangeConflicted(
            id, server: (etag: "e2", vcard: Data("s".utf8), details: ContactDetails(givenName: "Maja", familyName: "Server")))
        return id
    }

    @Test func applyAgainAndDiscardResolveConflict() throws {
        let f = try fixture()
        let id = try conflicted(f)
        let card = PersonCardModel(app: f.app, request: PersonRequest(contact: id))
        card.reload()
        #expect(card.conflict?.familyName == "Mine2")
        #expect(card.name == "Maja Server")
        try card.applyAgain()
        #expect(card.conflict == nil)
        #expect(card.name == "Maja Mine2")
        #expect(try f.box.store.pendingContactChanges(f.accounts[0].id).map(\.change) == [.update])

        let other = try conflicted(f)
        let second = PersonCardModel(app: f.app, request: PersonRequest(contact: other))
        second.reload()
        try second.discard()
        #expect(second.conflict == nil)
        #expect(second.name == "Maja Server")
    }

    @Test func failedChangeShowsOnTheCard() throws {
        let f = try fixture()
        let id = try put(f, in: f.books[0])
        let sent = try #require(try f.box.store.pendingContactChanges(f.accounts[0].id).first)
        try f.box.store.contactChangeFailed(id, revision: sent.revision)
        let card = PersonCardModel(app: f.app, request: PersonRequest(contact: id))
        card.reload()
        #expect(card.changeFailed)
    }

    @Test func discardingAFailedChangeOnTheCardEndsIt() throws {
        let f = try fixture()
        let store = f.box.store
        try store.upsertRemote(
            href: "/a/1.vcf", etag: "e1", vcard: Data("BEGIN:VCARD\r\nVERSION:4.0\r\nFN:Maja Ek\r\nN:Ek;Maja;;;\r\nEND:VCARD\r\n".utf8),
            details: ContactDetails(givenName: "Maja", familyName: "Ek"), photo: nil, in: f.books[0].id)
        let id = try #require(try store.contacts(in: nil, matching: nil).first?.id)
        try store.updateContact(id, ContactDetails(givenName: "Maja", familyName: "Own"))
        let sent = try #require(try store.pendingContactChanges(f.accounts[0].id).first)
        try store.contactChangeFailed(id, revision: sent.revision)
        let card = PersonCardModel(app: f.app, request: PersonRequest(contact: id))
        card.reload()

        try card.discardFailedChange()

        #expect(!card.changeFailed)
        #expect(card.name == "Maja Ek")
    }

    @Test func aRefusedPhotoOnTheCardCanBeTriedAgain() throws {
        let f = try fixture()
        let id = try put(f, in: f.books[0])
        let sent = try #require(try f.box.store.pendingContactChanges(f.accounts[0].id).first)
        try f.box.store.photoGivenUp(id, revision: sent.revision)
        let card = PersonCardModel(app: f.app, request: PersonRequest(contact: id))
        card.reload()
        #expect(card.changeFailed && card.photoFailed)

        try card.retryPhoto()

        #expect(!card.changeFailed && !card.photoFailed)
    }

    @Test func cardRefreshesWhenMailArrives() async throws {
        let f = try fixture()
        let card = PersonCardModel(
            app: f.app, request: PersonRequest(address: Address(name: nil, email: "who@example.org")))
        card.reload()
        let watching = Task { await card.observe() }
        defer { watching.cancel() }
        try await Task.sleep(for: .milliseconds(100))
        try f.box.add(f.accounts[0], uid: 1, from: "who@example.org", subject: "fresh")
        for _ in 0..<100 where card.latest.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(card.latest.map(\.subject) == ["fresh"])
    }

    @Test func aBurstOfMailIsLookedUpOnceItSettles() async throws {
        let f = try fixture()
        let card = PersonCardModel(
            app: f.app, request: PersonRequest(address: Address(name: nil, email: "who@example.org")))
        let watching = Task { await card.observe() }
        defer { watching.cancel() }
        for _ in 0..<100 where card.lookups == 0 { try await Task.sleep(for: .milliseconds(10)) }
        for uid in 1...20 {
            try f.box.add(f.accounts[0], uid: UInt32(uid), from: "who@example.org", subject: "burst \(uid)")
            try await Task.sleep(for: .milliseconds(15))
        }
        for _ in 0..<200 where card.latest.first?.subject != "burst 20" {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(card.latest.first?.subject == "burst 20")
        #expect(card.lookups <= 4)
    }

    @Test func photoOfSameLengthButOtherBytesIsNotServedFromCache() throws {
        let png = Data(
            base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==")
        let good = try #require(png)
        let id = ContactID(raw: 4_242)
        let account = AccountID(raw: UUID())
        func contact(_ photo: Data) -> Contact {
            Contact(id: id, accountID: account, addressBookID: AddressBookID(raw: 1), details: ContactDetails(), photo: photo)
        }
        #expect(ContactPhotos.image(for: contact(good), pixels: 8) != nil)
        let broken = Data(repeating: 0, count: good.count)
        #expect(ContactPhotos.image(for: contact(broken), pixels: 8) == nil)
    }

    @Test func photoWithASidePastTheCapIsNeverDecoded() {
        #expect(ContactPhotos.thumbnail(SyntheticImage.png(width: 9_000, height: 1), pixels: 64) == nil)
        #expect(ContactPhotos.thumbnail(SyntheticImage.png(width: 1, height: 9_000), pixels: 64) == nil)
        #expect(ContactPhotos.thumbnail(SyntheticImage.png(width: 200, height: 100), pixels: 64) != nil)
    }

    private func microsoftFixture() throws -> (AppModel, AddressBook) {
        var box = try Mailbox()
        var account = try box.addAccount("ms@example.org")
        account.auth = .oauth
        account.contactsVia = .graph
        try box.store.save(account)
        try box.store.replaceAddressBooks([("me", "Contacts", false)], for: account.id)
        let book = try #require(try box.store.addressBooks(account.id).first)
        let app = AppModel(store: box.store, sync: SyncCoordinator(store: box.store, secrets: InMemorySecretStore()))
        return (app, book)
    }

    /// What Graph cannot hold is not offered: a fourth address, a second mobile, an `other` phone,
    /// two addresses of one kind.
    @Test func editorLimitsForMicrosoft() throws {
        let (app, book) = try microsoftFixture()
        let model = ContactEditorModel(app: app, editing: nil, prefill: nil)
        #expect(model.book == book.id)
        model.details.emails = (1...3).map { Labeled(label: "other", value: "e\($0)@example.org") }
        #expect(!model.canAddEmail)
        model.details.phones = [Labeled(label: "mobile", value: "1"), Labeled(label: "work", value: "2")]
        #expect(!model.phoneLabels(for: 1).contains("mobile"))
        #expect(model.phoneLabels(for: 0).contains("mobile"))
        #expect(!model.phoneLabels(for: 0).contains("other"))
        #expect(model.newPhoneLabel == "work")
        model.details.addresses = [PostalAddress(label: "home"), PostalAddress(label: "work")]
        #expect(model.addressLabels(for: 1) == ["work", "other"])
        #expect(model.newAddressLabel == "other")
        model.details.addresses.append(PostalAddress(label: "other"))
        #expect(!model.canAddAddress)
    }

    @Test func editorUnlimitedForOwnServer() throws {
        let f = try fixture()
        let model = ContactEditorModel(app: f.app, editing: nil, prefill: nil)
        model.details.emails = (1...5).map { Labeled(label: "work", value: "e\($0)@example.org") }
        #expect(model.canAddEmail)
        model.details.phones = [Labeled(label: "mobile", value: "1")]
        #expect(model.phoneLabels(for: 1) == ["mobile", "work", "home", "other"])
        model.details.addresses = (1...4).map { _ in PostalAddress(label: "home") }
        #expect(model.canAddAddress)
        #expect(model.addressLabels(for: 0) == ["home", "work", "other"])
    }

    /// A CardDAV contact takes a phone with no label, or one of its own: it is saved as it is.
    @Test func ownServerTakesAPhoneWithoutALabel() throws {
        let f = try fixture()
        let model = ContactEditorModel(app: f.app, editing: nil, prefill: nil)
        model.details.givenName = "Sari"
        model.details.phones = [Labeled(label: "", value: "0700000000"), Labeled(label: "fax", value: "1")]
        #expect(!model.isOverLimits && model.canSave)
    }

    /// Rows typed for an own-server book that Graph cannot hold keep a Microsoft book from saving
    /// until they fit: nothing is dropped on the way.
    @Test func switchingToAMicrosoftBookOverItsLimitsBlocksSaving() throws {
        var box = try Mailbox()
        let own = try box.addAccount("own@example.org", cardDAV: true)
        try box.store.replaceAddressBooks([("/own/", "Own", false)], for: own.id)
        var microsoft = try box.addAccount("ms@example.org")
        microsoft.auth = .oauth
        microsoft.contactsVia = .graph
        try box.store.save(microsoft)
        try box.store.replaceAddressBooks([("me", "Contacts", false)], for: microsoft.id)
        let app = AppModel(store: box.store, sync: SyncCoordinator(store: box.store, secrets: InMemorySecretStore()))
        let ownBook = try #require(try box.store.addressBooks(own.id).first)
        let msBook = try #require(try box.store.addressBooks(microsoft.id).first)

        let model = ContactEditorModel(app: app, editing: nil, prefill: nil)
        model.book = ownBook.id
        model.details.givenName = "Many"
        model.details.emails = (1...4).map { Labeled(label: "work", value: "m\($0)@example.org") }
        model.details.phones = [Labeled(label: "mobile", value: "1"), Labeled(label: "mobile", value: "2")]
        #expect(model.canSave && !model.isOverLimits)

        model.book = msBook.id
        #expect(model.isOverLimits && !model.canSave)
        model.details.emails.removeLast()
        model.details.phones[1].label = "work"
        #expect(!model.isOverLimits && model.canSave)
        model.details.addresses = [PostalAddress(label: "home", street: "A"), PostalAddress(label: "home", street: "B")]
        #expect(model.isOverLimits)
    }
}

/// A PNG of one colour, of the size given.
func testPNG(width: Int, height: Int) -> Data? {
    guard let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let image = context.makeImage() else { return nil }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
        return nil
    }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination) ? data as Data : nil
}
