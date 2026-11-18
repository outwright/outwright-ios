// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightMIME
import OutwrightModel
import OutwrightStore
import OutwrightSync
import Testing

@testable import OutwrightUI

@MainActor @Suite struct PersonCardModelTests {
    private func fixture() throws -> (app: AppModel, box: Mailbox, accounts: [Account], books: [AddressBook]) {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org", cardDAV: true)
        let home = try box.addAccount("home@example.org", cardDAV: true)
        try box.store.replaceAddressBooks([("/c/", "Contacts", false)], for: anna.id)
        try box.store.replaceAddressBooks([("/c/", "Contacts", false)], for: home.id)
        let books = try box.store.addressBooks(anna.id) + box.store.addressBooks(home.id)
        let app = AppModel(store: box.store, sync: offlineSync(store: box.store, secrets: InMemorySecretStore()))
        return (app, box, [anna, home], books)
    }

    private func details(_ name: String, email: String = "maja@example.org") -> ContactDetails {
        ContactDetails(
            givenName: name, organization: "Ek AB", emails: [Labeled(label: "work", value: email)],
            phones: [Labeled(label: "mobile", value: "+46 70 000 00 00")])
    }

    @Test func addressOfContactOpensThatContact() throws {
        let (app, box, _, books) = try fixture()
        let id = try box.store.createContact(details("Maja"), in: books[0].id)
        let model = PersonCardModel(
            app: app, request: PersonRequest(address: Address(name: nil, email: "Maja@Example.org")))
        model.reload()
        #expect(model.contact?.id == id)
        #expect(model.name == "Maja")
        #expect(model.emails.map(\.value) == ["maja@example.org"])
        #expect(model.phones.count == 1)
        #expect(!model.canAddContact)
        let byID = PersonCardModel(app: app, request: PersonRequest(contact: id))
        byID.reload()
        #expect(byID.contact?.id == id)
    }

    @Test func addressInTwoAccountsPrefersMessageAccount() throws {
        let (app, box, accounts, books) = try fixture()
        let first = try box.store.createContact(details("Aaa"), in: books[0].id)
        let second = try box.store.createContact(details("Zzz"), in: books[1].id)
        let address = Address(name: nil, email: "maja@example.org")
        let preferred = PersonCardModel(app: app, request: PersonRequest(address: address, account: accounts[1].id))
        preferred.reload()
        #expect(preferred.contact?.id == second)
        let plain = PersonCardModel(app: app, request: PersonRequest(address: address))
        plain.reload()
        #expect(plain.contact?.id == first, "else the first by name")
    }

    @Test func unknownAddressGivesCardWithAddContact() throws {
        let (app, _, _, _) = try fixture()
        let model = PersonCardModel(
            app: app, request: PersonRequest(address: Address(name: "Stranger", email: "who@example.org")))
        model.reload()
        #expect(model.contact == nil)
        #expect(model.name == "Stranger")
        #expect(model.emails.map(\.value) == ["who@example.org"])
        #expect(model.canAddContact)
    }

    @Test func latestMessagesAreThreeNewest() throws {
        let (app, box, accounts, _) = try fixture()
        for index in 1...5 {
            try box.add(
                accounts[0], uid: UInt32(index), from: "who@example.org", subject: "m\(index)",
                date: Date(timeIntervalSince1970: 1_800_000_000 + Double(index) * 100))
        }
        try box.add(accounts[0], uid: 9, from: "other@example.org", subject: "not theirs")
        let model = PersonCardModel(
            app: app, request: PersonRequest(address: Address(name: nil, email: "who@example.org")))
        model.reload()
        #expect(model.latest.map(\.subject) == ["m5", "m4", "m3"])
    }

    @Test func editFromAPaneOpensAtOnce() throws {
        let (app, box, _, books) = try fixture()
        let id = try box.store.createContact(details("Maja"), in: books[0].id)
        app.afterCard { app.contactEditor = ContactEditorRequest(editing: id) }
        #expect(app.contactEditor?.editing == id, "no card sheet in front: the editor opens now")
        app.contactEditor = nil
        app.openPending()
        #expect(app.contactEditor == nil, "nothing was left waiting")
    }

    @Test func editFromASheetWaitsForItToClose() throws {
        let (app, box, _, books) = try fixture()
        let id = try box.store.createContact(details("Maja"), in: books[0].id)
        app.personToShow = PersonRequest(contact: id)
        app.afterCard { app.contactEditor = ContactEditorRequest(editing: id) }
        #expect(app.personToShow == nil, "the card sheet closes")
        #expect(app.contactEditor == nil, "the editor waits for it")
        app.openPending()
        #expect(app.contactEditor?.editing == id)
    }

    @Test func aSecondTapWhileTheSheetGoesWaitsToo() throws {
        let (app, box, _, books) = try fixture()
        let id = try box.store.createContact(details("Maja"), in: books[0].id)
        app.personToShow = PersonRequest(contact: id)
        app.afterCard { app.contactEditor = ContactEditorRequest(editing: id) }
        app.afterCard { app.compose(.to(Address(name: nil, email: "maja@example.org"))) }
        #expect(app.composeRequest == nil && app.contactEditor == nil, "the sheet is still going")
        app.openPending()
        #expect(app.composeRequest != nil, "the last tap opens")
        #expect(app.contactEditor == nil, "the earlier one was replaced")
    }

    @Test func anEventAddedWhileTheCardIsOpenShows() async throws {
        let fixture = try CalendarFixture()
        fixture.app.now = { calendarNow }
        let card = PersonCardModel(
            app: fixture.app, request: PersonRequest(address: Address(name: "Maja", email: "maja@example.org")))
        let watching = Task { await card.observe() }
        defer { watching.cancel() }
        for _ in 0..<100 where card.lookups == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(card.events.isEmpty)
        let start = fixture.at(day: 12, 9)
        try fixture.add(EventDetails(
            title: "Planning", start: .utc(start), end: .utc(start.addingTimeInterval(3_600)),
            attendees: [Attendee(email: "maja@example.org")]))
        for _ in 0..<150 where card.events.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(card.events.map(\.occurrence.details.title) == ["Planning"])
    }

    @Test func cardListsEventsWithThePerson() throws {
        let fixture = try CalendarFixture()
        fixture.app.now = { calendarNow }
        func meeting(_ title: String, day: Int, attendees: [String] = [], organizer: String? = nil) throws {
            let start = fixture.at(day: day, 9)
            try fixture.add(EventDetails(
                title: title, start: .utc(start), end: .utc(start.addingTimeInterval(3_600)),
                attendees: attendees.map { Attendee(email: $0) }, organizer: organizer))
        }
        try meeting("Planning", day: 12, attendees: ["anna@example.org", "Maja@Example.org"])
        try meeting("Review", day: 20, organizer: "maja@example.org")
        try meeting("Kickoff", day: 3, attendees: ["maja@example.org"])
        try meeting("Without her", day: 13, attendees: ["bo@example.org"])
        let card = PersonCardModel(
            app: fixture.app, request: PersonRequest(address: Address(name: "Maja", email: "maja@example.org")))
        card.reload()
        #expect(card.events.map(\.occurrence.details.title) == ["Planning", "Review", "Kickoff"],
            "the coming ones first, then the past")
    }

    @Test func dialUrlsKeepOnlyDialCharacters() {
        #expect(PersonCardModel.url("tel", "+46 (70) 100-20 30")?.absoluteString == "tel:+46701002030")
        #expect(PersonCardModel.url("sms", "070 1<script>2")?.absoluteString == "sms:07012")
        #expect(PersonCardModel.url("tel", "call me") == nil)
        #expect(PersonCardModel.url("tel", "+++ ,;") == nil)
        let long = PersonCardModel.url("tel", String(repeating: "1", count: 500))
        #expect(long?.absoluteString.count == 4 + 64)
    }

    @Test func mailButtonOpensComposeToAddress() throws {
        let (app, box, _, books) = try fixture()
        _ = try box.store.createContact(details("Maja"), in: books[0].id)
        let model = PersonCardModel(
            app: app, request: PersonRequest(address: Address(name: nil, email: "maja@example.org")))
        model.reload()
        app.personToShow = PersonRequest(address: Address(name: nil, email: "maja@example.org"))
        model.mail()
        #expect(app.composeRequest == nil, "waits for the card sheet to close")
        app.openPending()
        #expect(app.composeRequest?.kind == .to(Address(name: "Maja", email: "maja@example.org")))
        let bare = PersonCardModel(app: app, request: PersonRequest(contact: ContactID(raw: 9_999)))
        bare.reload()
        app.composeRequest = nil
        bare.mail()
        app.openPending()
        #expect(app.composeRequest == nil, "nothing to write to")
    }

    // MARK: - Files

    private func mail(from sender: String, files: [(name: String, inline: Bool)], minutes: Double) throws -> Data {
        try MIMEWriter.write(
            OutgoingMessage(
                from: Address(name: nil, email: sender), to: [Address(name: nil, email: "anna@example.org")],
                cc: [], bcc: [], subject: "Bilagor", textBody: "Se bilagorna.", htmlBody: nil,
                attachments: files.map { file in
                    Attachment(
                        filename: file.name, mimeType: file.inline ? "image/png" : "application/pdf",
                        contentID: file.inline ? "pic@example.org" : nil, isInline: file.inline,
                        data: Data("data \(file.name)".utf8))
                },
                inReplyTo: nil, references: [], date: Date(timeIntervalSince1970: 1_800_000_000 + minutes * 60),
                messageID: "\(UUID().uuidString)@example.org"),
            includeBcc: false)
    }

    private func addMail(
        _ box: Mailbox, _ account: Account, uid: UInt32, from: String, files: [(name: String, inline: Bool)]
    ) throws {
        let id = try box.add(
            account, uid: uid, from: from, date: Date(timeIntervalSince1970: 1_800_000_000 + Double(uid) * 60),
            body: try mail(from: from, files: files, minutes: Double(uid)))
        var row = try #require(try box.store.message(id))
        row.hasAttachment = true
        _ = try box.store.upsert([row])
    }

    @Test func cardListsTheFilesOfTheMailWithThePerson() throws {
        let (app, box, accounts, _) = try fixture()
        try addMail(box, accounts[0], uid: 1, from: "maja@example.org", files: [("gammal.pdf", false)])
        try addMail(
            box, accounts[0], uid: 2, from: "maja@example.org", files: [("ny.pdf", false), ("logga.png", true)])
        try addMail(box, accounts[0], uid: 3, from: "carl@example.org", files: [("carl.pdf", false)])
        let model = PersonCardModel(app: app, request: PersonRequest(address: Address(name: nil, email: "maja@example.org")))
        model.reload()
        #expect(model.files.map(\.name) == ["ny.pdf", "gammal.pdf"])
        #expect(model.files.first?.size == Data("data ny.pdf".utf8).count)
    }

    @Test func cardFilesAreCappedAtFifty() throws {
        let (app, box, accounts, _) = try fixture()
        for uid in UInt32(1)...30 {
            try addMail(box, accounts[0], uid: uid, from: "maja@example.org", files: [("a\(uid).pdf", false), ("b\(uid).pdf", false)])
        }
        let model = PersonCardModel(app: app, request: PersonRequest(address: Address(name: nil, email: "maja@example.org")))
        model.reload()
        #expect(model.files.count == 50)
        #expect(model.files.first?.name == "a30.pdf")
    }
}

