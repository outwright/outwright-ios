// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightFakes
import OutwrightModel
import OutwrightNet
import OutwrightStore
import OutwrightSync
import Synchronization
import Testing

@testable import OutwrightUI

/// What the server's well-known lookup answers, changed while a test runs.
private final class Answer: Sendable {
    private let value: Mutex<String?>
    init(_ url: String?) { value = Mutex(url) }
    func set(_ url: String?) { value.withLock { $0 = url } }
    var url: URL? { value.withLock { $0 }.flatMap { URL(string: $0) } }
}

/// The account settings' switches for its calendar and its contacts (#60).
@MainActor @Suite struct DAVSwitchTests {
    private func lookup(_ answer: Answer) -> @Sendable (URL) async -> URL? {
        { _ in answer.url }
    }

    private func stored(_ box: Mailbox, _ id: AccountID) throws -> Account {
        try #require(try box.store.accounts().first { $0.id == id })
    }

    @Test func theCalendarTurnedOffIsGoneAndNotLookedFor() async throws {
        var box = try Mailbox()
        var anna = try box.addAccount("anna@example.org")
        anna.calDAV = "https://example.org/dav/"
        try box.store.save(anna)
        let answers = Answer("https://example.org/dav/")
        let sync = offlineSync(store: box.store, secrets: InMemorySecretStore(), probe: lookup(answers))
        let app = AppModel(store: box.store, sync: sync)

        try await app.setCalendarOn(false, for: anna.id)
        await sync.refreshCalendars(of: anna.id)
        // Kept for turning it on again, but not used while off.
        #expect(try stored(box, anna.id).calDAV == "https://example.org/dav/")
        #expect(try stored(box, anna.id).calDAVOff)
    }

    @Test func theCalendarTurnedOnAgainIsLookedForAgain() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let answers = Answer(nil)
        let sync = offlineSync(store: box.store, secrets: InMemorySecretStore(), probe: lookup(answers))
        let app = AppModel(store: box.store, sync: sync)
        // Looked for once in this run, and nothing was there.
        await sync.refreshCalendars(of: anna.id)
        #expect(try stored(box, anna.id).calDAV == nil)

        try await app.setCalendarOn(false, for: anna.id)
        answers.set("https://example.org/dav/")
        try await app.setCalendarOn(true, for: anna.id)
        #expect(try !stored(box, anna.id).calDAVOff)
        await sync.refreshCalendars(of: anna.id)
        #expect(try stored(box, anna.id).calDAV == "https://example.org/dav/")
    }

    @Test func theContactsTurnedOffAreGoneAndNotLookedFor() async throws {
        var box = try Mailbox()
        var anna = try box.addAccount("anna@example.org")
        anna.cardDAV = "https://example.org/dav/"
        try box.store.save(anna)
        let answers = Answer("https://example.org/dav/")
        let sync = offlineSync(store: box.store, secrets: InMemorySecretStore(), probe: lookup(answers))
        let app = AppModel(store: box.store, sync: sync)

        try await app.setContactsOn(false, for: anna.id)
        await sync.refreshContacts(of: anna.id)
        // Kept for turning it on again, but not used while off.
        #expect(try stored(box, anna.id).cardDAV == "https://example.org/dav/")
        #expect(try stored(box, anna.id).cardDAVOff)
    }

    @Test func theContactsTurnedOnAgainAreLookedForAgain() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let answers = Answer(nil)
        let sync = offlineSync(store: box.store, secrets: InMemorySecretStore(), probe: lookup(answers))
        let app = AppModel(store: box.store, sync: sync)
        await sync.refreshContacts(of: anna.id)
        #expect(try stored(box, anna.id).cardDAV == nil)

        try await app.setContactsOn(false, for: anna.id)
        answers.set("https://example.org/dav/")
        try await app.setContactsOn(true, for: anna.id)
        #expect(try !stored(box, anna.id).cardDAVOff)
        await sync.refreshContacts(of: anna.id)
        #expect(try stored(box, anna.id).cardDAV == "https://example.org/dav/")
    }

    // An address typed by hand, which no lookup finds, survives off and on (review of #60).
    @Test func aTypedCalendarAddressSurvivesOffAndOn() async throws {
        let server = FakeCalDAVServer()
        let port = try await server.start()
        _ = await server.addCalendar("Work")
        var box = try Mailbox()
        var anna = try box.addAccount("anna@example.org")
        anna.user = "jk@example.org"
        anna.calDAV = "http://127.0.0.1:\(port)/"
        try box.store.save(anna)
        let secrets = InMemorySecretStore()
        try secrets.setPassword(Secret("secret"), for: anna.id)
        let sync = offlineSync(store: box.store, secrets: secrets, probe: lookup(Answer(nil)))
        let app = AppModel(store: box.store, sync: sync)
        await sync.refreshCalendars(of: anna.id)
        #expect(try !box.store.calendars(anna.id).isEmpty)

        try await app.setCalendarOn(false, for: anna.id)
        await sync.refreshCalendars(of: anna.id)
        #expect(try box.store.calendars(anna.id).isEmpty)

        try await app.setCalendarOn(true, for: anna.id)
        await sync.refreshCalendars(of: anna.id)
        #expect(try stored(box, anna.id).calDAV == "http://127.0.0.1:\(port)/")
        #expect(try !box.store.calendars(anna.id).isEmpty)
        await server.stop()
    }

    @Test func aTypedContactsAddressSurvivesOffAndOn() async throws {
        let server = FakeCardDAVServer()
        let port = try await server.start()
        _ = await server.addBook("Contacts")
        var box = try Mailbox()
        var anna = try box.addAccount("anna@example.org")
        anna.user = "jk@example.org"
        anna.cardDAV = "http://127.0.0.1:\(port)/"
        try box.store.save(anna)
        let secrets = InMemorySecretStore()
        try secrets.setPassword(Secret("secret"), for: anna.id)
        let sync = offlineSync(store: box.store, secrets: secrets, probe: lookup(Answer(nil)))
        let app = AppModel(store: box.store, sync: sync)
        await sync.refreshContacts(of: anna.id)
        #expect(try !box.store.addressBooks(anna.id).isEmpty)

        try await app.setContactsOn(false, for: anna.id)
        await sync.refreshContacts(of: anna.id)
        #expect(try box.store.addressBooks(anna.id).isEmpty)

        try await app.setContactsOn(true, for: anna.id)
        await sync.refreshContacts(of: anna.id)
        #expect(try stored(box, anna.id).cardDAV == "http://127.0.0.1:\(port)/")
        #expect(try !box.store.addressBooks(anna.id).isEmpty)
        await server.stop()
    }
}
