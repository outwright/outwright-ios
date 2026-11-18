// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightFakes
import OutwrightModel
import OutwrightNet
import OutwrightSetup
import OutwrightStore
import Testing

@testable import OutwrightSync

@testable import OutwrightUI

/// The app with one account on fake servers, its password in memory.
@MainActor
private func withFakeAccount(_ body: (AppModel, FakeIMAPServer, Account) async throws -> Void) async throws {
    let server = FakeIMAPServer()
    let smtp = FakeSMTPServer()
    let imapPort = try await server.start()
    let smtpPort = try await smtp.start()
    let store = try MailStore(path: nil)
    let account = Account(
        id: AccountID(), displayName: "Jörgen", email: "jk@example.org", colorIndex: 0,
        imap: MailEndpoint(host: "127.0.0.1", port: imapPort, security: "plainLoopbackOnly"),
        smtp: MailEndpoint(host: "127.0.0.1", port: smtpPort, security: "plainLoopbackOnly"),
        user: FakeIMAPServer.user, signature: "", sortOrder: 0)
    let secrets = InMemorySecretStore()
    // A minute between tries: a watcher whose connection is cut does not come back within the test.
    let app = AppModel(
        store: store, sync: offlineSync(store: store, secrets: secrets, backoff: .seconds(60) ... .seconds(60)))
    do {
        try secrets.setPassword(Secret(FakeIMAPServer.password), for: account.id)
        try await body(app, server, account)
    } catch {
        await app.sync.stopForeground()
        await server.stop()
        await smtp.stop()
        throw error
    }
    await app.sync.stopForeground()
    await server.stop()
    await smtp.stop()
}

/// A CalDAV server with a calendar and a CardDAV server with an address book, both on loopback,
/// taking the fake IMAP server's user and password.
private struct DAVFakes {
    let calendars: FakeCalDAVServer
    let books: FakeCardDAVServer
    let calDAV: String
    let cardDAV: String

    static func start() async throws -> DAVFakes {
        let calendars = FakeCalDAVServer(user: FakeIMAPServer.user, password: FakeIMAPServer.password)
        let books = FakeCardDAVServer(user: FakeIMAPServer.user, password: FakeIMAPServer.password)
        let calendarPort = try await calendars.start()
        let bookPort = try await books.start()
        _ = await calendars.addCalendar("Work")
        _ = await books.addBook("Contacts")
        return DAVFakes(
            calendars: calendars, books: books, calDAV: "http://127.0.0.1:\(calendarPort)/",
            cardDAV: "http://127.0.0.1:\(bookPort)/")
    }

    func stop() async {
        await calendars.stop()
        await books.stop()
    }
}

/// Counts the times it is asked.
private actor AskCount {
    private var count = 0

    func next() -> Int {
        count &+= 1
        return count
    }
}

private func eventually(seconds: Double = 60, _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return await condition()
}

@MainActor @Suite(.serialized) struct ForegroundTests {
    @Test func aNewAccountIsWatchedAtOnce() async throws {
        try await withFakeAccount { app, server, account in
            try app.store.save(account)
            await app.accountAdded(account)
            let idling0 = await eventually { await server.idlingSessions == 1 }
            #expect(idling0)
        }
    }

    /// A restored account's Inbox is watched and its contacts and calendars synced at once, while a
    /// large folder of it is still being read.
    @Test func aRestoredAccountIsWatchedAndItsCalendarsSyncedAtOnce() async throws {
        try await withFakeAccount { app, server, account in
            try await Self.showsAtOnce(app, server, account) { _ in await app.restoredFromSetup() }
        }
    }

    @Test func anAddedAccountIsWatchedAndItsCalendarsSyncedAtOnce() async throws {
        try await withFakeAccount { app, server, account in
            try await Self.showsAtOnce(app, server, account) { added in await app.accountAdded(added) }
        }
    }

    /// The app in front, `account` (with a calendar and an address book) is stored and `arrive`
    /// told of it while its folder "Slow" holds the full sync: its Inbox is watched, and its
    /// calendars and contacts are in the store, before that folder is answered.
    private static func showsAtOnce(
        _ app: AppModel, _ server: FakeIMAPServer, _ account: Account,
        _ arrive: @escaping @MainActor (Account) async -> Void
    ) async throws {
        let dav = try await DAVFakes.start()
        var account = account
        account.calDAV = dav.calDAV
        account.cardDAV = dav.cardDAV
        await server.addFolder("Slow", specialUse: nil)
        await server.holdSelects(of: "Slow")
        await app.sceneChanged(toActive: true).value
        try app.store.save(account)
        let added = account
        let arrival = Task { await arrive(added) }
        let store = app.store
        let watched = await eventually { await server.idlingSessions == 1 }
        let calendars = await eventually { !((try? store.calendars(added.id)) ?? []).isEmpty }
        let books = await eventually { !((try? store.addressBooks(added.id)) ?? []).isEmpty }
        await server.releaseSelects()
        await arrival.value
        await dav.stop()
        #expect(watched)
        #expect(calendars)
        #expect(books)
    }

    /// Back in front with the app already there (an account came while it was), the new account's
    /// contacts and calendars are synced too, not only those of the first return.
    @Test func aSecondStartForegroundSyncsANewAccountsContactsAndCalendars() async throws {
        try await withFakeAccount { app, _, account in
            let dav = try await DAVFakes.start()
            await app.sceneChanged(toActive: true).value
            var account = account
            account.calDAV = dav.calDAV
            account.cardDAV = dav.cardDAV
            try app.store.save(account)
            await app.sync.startForeground()
            let store = app.store
            let id = account.id
            let calendars = await eventually { !((try? store.calendars(id)) ?? []).isEmpty }
            let books = await eventually { !((try? store.addressBooks(id)) ?? []).isEmpty }
            await dav.stop()
            #expect(calendars)
            #expect(books)
        }
    }

    /// The device holds a wrong password for the account and the owner takes the file's instead:
    /// the account's syncer, the same one, signs in with it and reads the Inbox, with no restart.
    @Test func aRestoredPasswordSignsInWithoutARestart() async throws {
        try await withFakeAccount { app, _, account in
            let id = account.id
            try app.sync.secrets.setPassword(Secret("wrong"), for: id)
            try app.store.save(account)
            app.reloadAccounts()
            await app.sceneChanged(toActive: true).value
            let refused = await eventually { await app.sync.lastErrors[id] == .imap(.authenticationFailed) }
            #expect(refused)
            let first = await app.sync.syncers[id].map(\.syncer)
            let before = try #require(first)

            // The other device's file: the same account with the server's password.
            let other = try MailStore(path: nil)
            let otherSecrets = InMemorySecretStore()
            try other.save(account)
            try otherSecrets.setPassword(Secret(FakeIMAPServer.password), for: id)
            let part = AccountsSetupPart(
                store: other, secrets: otherSecrets, providers: ProviderSet([OwnServerProvider()]))
            let sender = SetupExchange(parts: [part], device: "Other phone")
            let bundle = try await sender.exportBundle().bundle
            let exchange = app.setupExchange()
            let preview = await exchange.preview(bundle)
            #expect(preview.differences.map(\.id) == ["jk@example.org"])
            let report = await exchange.restore(preview, replacing: Set(preview.differences))
            #expect(report.replaced.map(\.label) == ["jk@example.org"])
            await app.restoredFromSetup()

            let store = app.store
            let synced = await eventually {
                ((try? store.folders(id)) ?? []).contains { $0.kind == .inbox }
            }
            #expect(synced)
            let lastError = await app.sync.lastErrors[id]
            #expect(lastError == nil)
            let after = await app.sync.syncers[id].map(\.syncer)
            #expect(after === before)
        }
    }

    /// A restored account's Inbox says its mail is on its way at once, not once every folder is read.
    @Test func firstSyncStateShowsAtOnce() async throws {
        try await withFakeAccount { app, server, account in
            await server.holdSelects(of: "INBOX")
            await app.sceneChanged(toActive: true).value
            // What the return to the front looks at afterwards is done before the account comes.
            await app.frontFollowUps?.value
            try app.store.save(account)
            let restore = Task { await app.restoredFromSetup() }
            let id = account.id
            let awaiting = await eventually { await app.awaitingFirstInbox.contains(id) }
            await server.releaseSelects()
            await restore.value
            #expect(awaiting)
        }
    }

    /// An account added while the app is in the front on Wi-Fi gets its Inbox bodies at once, as on a
    /// return to the front: an invitation in it goes in the calendar without waiting for the next one.
    @Test func aNewAccountOnWiFiHasItsInboxBodiesAtOnce() async throws {
        try await withFakeAccount { app, server, account in
            // Off Wi-Fi for the return to the front's own prefetch, on for any later ask: only the
            // added account's prefetch, asking again, can fetch a body.
            let asks = AskCount()
            await app.sceneChanged(toActive: true) { await asks.next() > 1 }.value
            _ = await server.deliver(Self.message("waiting"), to: "INBOX")
            try app.store.save(account)
            await app.accountAdded(account)
            let store = app.store
            let fetched = await eventually {
                guard let inbox = try? store.folders(account.id).first(where: { $0.kind == .inbox }),
                    let rows = try? store.messages(
                        InboxQuery(scope: .folder(inbox.id), inboxClass: nil, filter: .all), limit: 10)
                else { return false }
                return rows.count == 1 && rows.allSatisfy(\.hasBody)
            }
            #expect(fetched)
        }
    }

    @Test func aQuickTripToTheBackgroundLeavesTheInboxWatched() async throws {
        try await withFakeAccount { app, server, account in
            try app.store.save(account)
            await app.sceneChanged(toActive: true).value
            let idling1 = await eventually { await server.idlingSessions == 1 }
            #expect(idling1)
            let away = app.sceneChanged(toActive: false)
            let back = app.sceneChanged(toActive: true)
            await away.value
            await back.value
            let idling2 = await eventually { await server.idlingSessions == 1 }
            #expect(idling2)
            try? await Task.sleep(for: .milliseconds(300))
            let stillIdling = await server.idlingSessions
            #expect(stillIdling == 1)
        }
    }

    /// A network change in the front watches the Inbox again on a new connection; one that comes
    /// right after a trip to the background waits for it and opens nothing.
    @Test func aNetworkChangeWatchesAgainOnlyInTheFront() async throws {
        try await withFakeAccount { app, server, account in
            try app.store.save(account)
            await app.sceneChanged(toActive: true).value
            let idling = await eventually { await server.idlingSessions == 1 }
            #expect(idling)
            let logins = await server.loginAttempts
            await app.networkChanged().value
            let relogged = await eventually { await server.loginAttempts > logins }
            #expect(relogged)
            let again = await eventually { await server.idlingSessions == 1 }
            #expect(again)
            let away = app.sceneChanged(toActive: false)
            let change = app.networkChanged()
            await away.value
            await change.value
            let stopped = await eventually { await server.idlingSessions == 0 }
            #expect(stopped)
            let loginsAway = await server.loginAttempts
            try? await Task.sleep(for: .milliseconds(300))
            let still = await server.loginAttempts
            #expect(still == loginsAway)
        }
    }

    /// A pull brings the Inbox before it ends; the other folders follow behind it.
    @Test func aPullBringsTheInboxAtOnceAndTheRestAfter() async throws {
        try await withFakeAccount { app, server, account in
            await server.addFolder("Sent", specialUse: "\\Sent")
            try app.store.save(account)
            await app.refresh()
            _ = await server.deliver(Self.message("pulled"), to: "INBOX")
            _ = await server.deliver(Self.message("sent meanwhile"), to: "Sent")
            await app.pullRefresh()
            let inbox = try Self.held(app.store, account, .inbox)
            #expect(inbox == 1)
            let store = app.store
            let sentFollows = await eventually { (try? Self.held(store, account, .sent)) == 1 }
            #expect(sentFollows)
        }
    }

    private nonisolated static func message(_ subject: String) -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        let lines = [
            "From: Bo <bo@example.org>", "To: jk@example.org", "Subject: \(subject)",
            "Date: \(formatter.string(from: Date()))", "Message-ID: <\(UUID().uuidString)@example.org>",
        ]
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\nHej\r\n").utf8)
    }

    private nonisolated static func held(_ store: MailStore, _ account: Account, _ kind: FolderKind) throws -> Int {
        guard let folder = try store.folders(account.id).first(where: { $0.kind == kind }) else { return 0 }
        return try store.folderIndex(folder.id).count
    }

    @Test func aNewPasswordIsKeptOnlyWhenTheServersTakeIt() async throws {
        try await withFakeAccount { app, _, account in
            try app.store.save(account)
            await #expect(throws: AccountSettingsError.self) {
                try await app.changePassword("wrong", for: account)
            }
            #expect(try app.sync.secrets.password(for: account.id)?.reveal() == FakeIMAPServer.password)
            try app.sync.secrets.remove(for: account.id)
            try await app.changePassword(FakeIMAPServer.password, for: account)
            #expect(try app.sync.secrets.password(for: account.id)?.reveal() == FakeIMAPServer.password)
        }
    }
}
