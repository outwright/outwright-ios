// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightFakes
import OutwrightIMAP
import OutwrightMIME
import OutwrightModel
import OutwrightNet
import OutwrightStore
import OutwrightSync
import Synchronization
import Testing

@Suite struct SyncTests {
    @Test func firstSyncFetchesNinetyDays() async throws {
        let server = await standardServer()
        await server.deliver(mail("ten days", date: daysAgo(10)), to: "INBOX")
        await server.deliver(mail("old", date: daysAgo(120)), to: "INBOX")
        try await withHarness(server) { h in
            let syncer = h.syncer()
            try await syncer.syncFolders()
            #expect(Set(try h.store.folders(h.account.id).map(\.kind)).isSuperset(of: [.inbox, .sent, .drafts, .trash]))
            try await syncer.sync(try h.folder(.inbox).id)
            let rows = try h.rows(.inbox)
            #expect(rows.map(\.subject) == ["ten days"])
            #expect(rows.first?.preview == "Hello there")
            #expect(rows.first?.from.email == "bo@example.org")
            #expect(rows.first?.date == daysAgo(10).rounded())
        }
    }

    @Test func windowStartsAtTheStartOfTheNinetiethDay() async throws {
        // 90 days before 6 Nov 12:00 is 8 Aug 12:00; IMAP's SINCE counts the whole of 8 Aug.
        let server = await standardServer()
        await server.deliver(mail("early on the 90th day", date: daysAgo(90.4)), to: "INBOX")
        await server.deliver(mail("late on the 91st day", date: daysAgo(90.6)), to: "INBOX")
        try await withHarness(server) { h in
            let syncer = h.syncer()
            try await syncer.syncFolders()
            try await syncer.sync(try h.folder(.inbox).id)
            #expect(try h.rows(.inbox).map(\.subject) == ["early on the 90th day"])
        }
    }

    @Test func uidValidityChangeRefetchesFolder() async throws {
        let server = await standardServer()
        await server.deliver(mail("a"), to: "INBOX")
        await server.deliver(mail("b"), to: "INBOX")
        try await withHarness(server) { h in
            let syncer = h.syncer()
            try await syncer.syncFolders()
            let inbox = try h.folder(.inbox)
            try await syncer.sync(inbox.id)
            let before = Set(try h.store.folderIndex(inbox.id).values)
            #expect(before.count == 2)

            await server.setUIDValidity(4242, for: "INBOX")
            await server.deliver(mail("c"), to: "INBOX")
            try await syncer.sync(inbox.id)

            let index = try h.store.folderIndex(inbox.id)
            #expect(Set(index.keys) == Set(await server.messages(in: "INBOX").map(\.uid)))
            #expect(Set(index.values).isDisjoint(with: before))
            #expect(try h.folder(.inbox).uidValidity == 4242)
            #expect(Set(try h.rows(.inbox).map(\.subject)) == ["a", "b", "c"])
        }
    }

    @Test func newsletterFromStrangerLandsInOther() async throws {
        let server = await standardServer()
        await server.deliver(mail("Weekly deals", from: "news@shop.example", list: true), to: "INBOX")
        await server.deliver(mail("Lunch?", from: "stranger@example.org"), to: "INBOX")
        try await withHarness(server) { h in
            let syncer = h.syncer()
            try await syncer.syncFolders()
            try await syncer.sync(try h.folder(.inbox).id)
            let rows = try h.rows(.inbox)
            #expect(rows.first { $0.subject == "Weekly deals" }?.inboxClass == .other)
            #expect(rows.first { $0.subject == "Lunch?" }?.inboxClass == .focused)
        }
    }

    @Test func replyFromCorrespondentLandsInFocused() async throws {
        let server = await standardServer()
        await server.deliver(
            mail("Plans", from: "jk@example.org", to: "bo@example.org", date: daysAgo(3), id: "s1@example.org"),
            to: "Sent", flags: ["\\Seen"])
        await server.deliver(mail("Club news", from: "bo@example.org", list: true), to: "INBOX")
        await server.deliver(
            mail("Re: Plans", from: "carl@lists.example", id: "r1@example.org", inReplyTo: "s1@example.org", list: true),
            to: "INBOX")
        try await withHarness(server) { h in
            let syncer = h.syncer()
            try await syncer.syncFolders()
            try await syncer.sync(try h.folder(.sent).id)
            try await syncer.sync(try h.folder(.inbox).id)
            let rows = try h.rows(.inbox)
            // Bulk, but from somebody the owner writes to.
            #expect(rows.first { $0.subject == "Club news" }?.inboxClass == .focused)
            // Bulk from a stranger, but a reply in a thread the owner took part in.
            let reply = try #require(rows.first { $0.subject == "Re: Plans" })
            #expect(reply.inboxClass == .focused)
            #expect(reply.threadID == (try h.rows(.sent).first?.threadID))
        }
    }

    @Test func repliesInOneBatchJoinTheirParentsThread() async throws {
        let server = await standardServer()
        await server.deliver(mail("Möte", id: "p@example.org"), to: "INBOX")
        await server.deliver(mail("Sv: Möte", id: "c@example.org", inReplyTo: "p@example.org"), to: "INBOX")
        try await withHarness(server) { h in
            let syncer = h.syncer()
            try await syncer.syncFolders()
            try await syncer.sync(try h.folder(.inbox).id)
            #expect(Set(try h.rows(.inbox).map(\.threadID)) == [ThreadID(raw: "p@example.org")])
        }
    }

    @Test(arguments: ResyncOffer.allCases)
    func serverChangesToFlagsAndRemovalsReachTheStore(offer: ResyncOffer) async throws {
        let server = await standardServer(offer)
        let read = await server.deliver(mail("read elsewhere"), to: "INBOX")
        let gone = await server.deliver(mail("deleted elsewhere"), to: "INBOX")
        let old = await server.deliver(mail("old but kept", date: daysAgo(200)), to: "INBOX")
        try await withHarness(server) { h in
            let syncer = h.syncer()
            try await syncer.syncFolders()
            let inbox = try h.folder(.inbox)
            try await syncer.sync(inbox.id)
            #expect(try h.rows(.inbox).count == 2)

            let side = try await h.sideClient()
            _ = try await side.select("INBOX")
            try await side.setFlags(["\\Seen", "\\Flagged"], on: [read], add: true)
            try await side.setFlags(["\\Deleted"], on: [gone], add: true)
            try await side.expunge([gone])
            try await side.setFlags(["\\Seen"], on: [old], add: true)
            await side.logout()

            try await syncer.sync(inbox.id)
            let rows = try h.rows(.inbox)
            #expect(rows.map(\.uid) == [read])
            #expect(rows.first?.isRead == true)
            #expect(rows.first?.isFlagged == true)
        }
    }

    @Test func fetchBodyKeepsTheWholeMessage() async throws {
        let server = await standardServer()
        let raw = mail("with body", body: "The whole text")
        await server.deliver(raw, to: "INBOX")
        try await withHarness(server) { h in
            let syncer = h.syncer()
            try await syncer.syncFolders()
            try await syncer.sync(try h.folder(.inbox).id)
            let row = try #require(try h.rows(.inbox).first)
            #expect(row.hasBody == false)
            try await syncer.fetchBody(row.id)
            #expect(try h.store.body(row.id) == raw)
            #expect(try h.store.message(row.id)?.hasBody == true)
            // Fetching for a body does not mark the message read on the server.
            #expect(await server.messages(in: "INBOX").first?.flags.contains("\\Seen") == false)
        }
    }

    @Test func idleInboxReturnsTrueOnNewMail() async throws {
        try await withHarness { h in
            let syncer = h.syncer()
            try await syncer.syncFolders()
            let delivery = Task {
                await h.imap.waitUntilIdling()
                await h.imap.deliver(mail("fresh"), to: "INBOX")
            }
            #expect(try await syncer.idleInbox() == true)
            await delivery.value
        }
    }

    @Test func missingPasswordIsReportedWithoutConnecting() async throws {
        try await withHarness { h in
            try h.secrets.remove(for: h.account.id)
            await #expect(throws: SyncError.noPassword) {
                try await h.syncer().syncFolders()
            }
            #expect(await h.imap.loginAttempts == 0)
        }
    }

    @Test func wrongPasswordErrorDoesNotCarryIt() async throws {
        try await withHarness { h in
            try h.secrets.setPassword(Secret("hunter2-wrong"), for: h.account.id)
            do {
                try await h.syncer().syncFolders()
                Issue.record("sync succeeded with a wrong password")
            } catch {
                #expect(error as? SyncError == .imap(.authenticationFailed))
                #expect(!"\(error)".contains("hunter2"))
            }
        }
    }

    @Test func inMemorySecretsKeepOnePasswordPerAccount() throws {
        let secrets = InMemorySecretStore()
        let first = AccountID()
        let second = AccountID()
        try secrets.setPassword(Secret("one"), for: first)
        try secrets.setPassword(Secret("two"), for: second)
        try secrets.setPassword(Secret("uno"), for: first)
        #expect(try secrets.password(for: first)?.reveal() == "uno")
        try secrets.remove(for: second)
        #expect(try secrets.password(for: second) == nil)
    }

    @Test func coordinatorRefreshesEveryAccountAndRecordsErrors() async throws {
        let server = await standardServer()
        await server.deliver(mail("for the coordinator"), to: "INBOX")
        await server.deliver(mail("sent", from: "jk@example.org"), to: "Sent")
        try await withHarness(server) { h in
            let broken = Account(
                id: AccountID(), displayName: "No password", email: "np@example.org", colorIndex: 1,
                imap: h.account.imap, smtp: h.account.smtp, user: "np@example.org", signature: "", sortOrder: 1)
            try h.store.save(broken)
            let coordinator = offlineCoordinator(store: h.store, secrets: h.secrets, now: { fixedNow })
            await coordinator.refreshAll()
            #expect(try h.rows(.inbox).map(\.subject) == ["for the coordinator"])
            #expect(try h.rows(.sent).map(\.subject) == ["sent"])
            let errors = await coordinator.lastErrors
            #expect(errors[broken.id] == .noPassword)
            #expect(errors[h.account.id] == nil)

            let row = try #require(try h.rows(.inbox).first)
            try await coordinator.fetchBody(row.id)
            #expect(try h.store.message(row.id)?.hasBody == true)
        }
    }

    @Test func prefetchOnWiFiFetchesInboxBodies() async throws {
        let server = await standardServer()
        await server.deliver(mail("one"), to: "INBOX")
        await server.deliver(mail("two"), to: "INBOX")
        try await withHarness(server) { h in
            let coordinator = offlineCoordinator(store: h.store, secrets: h.secrets, now: { fixedNow })
            await coordinator.refreshAll()
            await coordinator.prefetchInboxBodies(onWiFi: false)
            let before = try h.rows(.inbox)
            #expect(before.count == 2 && before.allSatisfy { !$0.hasBody })
            await coordinator.prefetchInboxBodies(onWiFi: true)
            let after = try h.rows(.inbox)
            #expect(after.count == 2 && after.allSatisfy(\.hasBody))
        }
    }

    @Test func replacingASyncerMidSendSendsOnce() async throws {
        let smtp = FakeSMTPServer(acceptDelay: .milliseconds(500))
        try await withHarness(smtp: smtp) { h in
            let coordinator = offlineCoordinator(store: h.store, secrets: h.secrets, now: { fixedNow })
            await coordinator.refreshAll()
            try h.store.apply(.send(draftID: try draftRow(h)))

            let first = Task { await coordinator.refreshAll() }
            #expect(await eventually { await smtp.authAttempts == 1 })
            // A change of account settings while the message is being taken gets the account a
            // new syncer, which must not send it again.
            var changed = h.account
            changed.email = "JK@example.org"
            try h.store.save(changed)
            await coordinator.refreshAll()
            await first.value
            await coordinator.refreshAll()
            #expect(await smtp.received.count == 1)
            #expect(try h.store.pendingActions().isEmpty)
        }
    }

    @Test func replacingASyncerDoesNotWaitForADeadIdle() async throws {
        try await withHarness { h in
            let coordinator = offlineCoordinator(store: h.store, secrets: h.secrets, now: { fixedNow })
            await coordinator.startForeground()
            await h.imap.waitUntilIdling()
            // The server goes silent: it will never answer the DONE that ends the IDLE.
            await h.imap.stopAnswering()
            var changed = h.account
            changed.email = "JK@example.org"
            try h.store.save(changed)
            let returned = Flag()
            let call = Task {
                await coordinator.startForeground()
                returned.set()
            }
            #expect(await eventually { returned.isSet })
            await h.imap.stop()
            await call.value
            await coordinator.stopForeground()
        }
    }

    @Test func displayNameChangeKeepsTheConnectionsAndSignsNewMail() async throws {
        try await withHarness { h in
            let coordinator = offlineCoordinator(store: h.store, secrets: h.secrets, now: { fixedNow })
            await coordinator.refreshAll()
            await coordinator.startForeground()
            await h.imap.waitUntilIdling()
            let logins = await h.imap.loginAttempts

            var renamed = h.account
            renamed.displayName = "Jörgen K"
            try h.store.save(renamed)
            try h.store.apply(.send(draftID: try draftRow(h)))
            await coordinator.refreshAll()
            #expect(await h.imap.loginAttempts == logins)
            let sentData = await h.smtp.received.first?.data ?? Data()
            #expect(try MIMEParser.parseHeaders(sentData).from.first?.name == "Jörgen K")
            await coordinator.stopForeground()
        }
    }

    @Test func comingBackToTheFrontIsNotHeldUpByASilentServer() async throws {
        try await withHarness { h in
            let coordinator = offlineCoordinator(store: h.store, secrets: h.secrets, now: { fixedNow })
            await coordinator.startForeground()
            await h.imap.waitUntilIdling()
            // The server stops answering: the DONE that ends the IDLE gets no reply.
            await h.imap.stopAnswering()
            let returned = Flag()
            let call = Task {
                await coordinator.stopForeground()
                await coordinator.startForeground()
                returned.set()
            }
            #expect(await eventually { returned.isSet })
            await h.imap.stop()
            await call.value
            await coordinator.stopForeground()
        }
    }

    /// Another network (Wi-Fi to mobile, a new Wi-Fi): the IDLE starts again on a new connection
    /// at once, so mail isn't missed on one the old network took down without a word.
    @Test func aNetworkChangeStartsTheIdleAgainOnANewConnection() async throws {
        try await withHarness { h in
            let coordinator = offlineCoordinator(store: h.store, secrets: h.secrets, now: { fixedNow })
            await coordinator.startForeground()
            await h.imap.waitUntilIdling()
            let logins = await h.imap.loginAttempts
            await coordinator.networkChanged()
            #expect(await eventually { await h.imap.loginAttempts > logins })
            await h.imap.waitUntilIdling()
            await h.imap.deliver(mail("after the change"), to: "INBOX")
            let arrived = try await eventually { try h.rows(.inbox).count == 1 }
            #expect(arrived)
            await coordinator.stopForeground()
        }
    }

    /// In the background there is no watching to start again: a network change opens nothing.
    @Test func aNetworkChangeInTheBackgroundOpensNothing() async throws {
        try await withHarness { h in
            let coordinator = offlineCoordinator(store: h.store, secrets: h.secrets, now: { fixedNow })
            await coordinator.networkChanged()
            try await Task.sleep(for: .milliseconds(300))
            #expect(await h.imap.loginAttempts == 0)
        }
    }

    @Test func foregroundBringsNewMailWithoutARefresh() async throws {
        try await withHarness { h in
            let coordinator = offlineCoordinator(store: h.store, secrets: h.secrets, now: { fixedNow })
            await coordinator.startForeground()
            await h.imap.waitUntilIdling()
            await h.imap.deliver(mail("pushed"), to: "INBOX")
            let arrived = try await eventually {
                try h.store.folders(h.account.id).contains { $0.kind == .inbox } && (try h.rows(.inbox).count == 1)
            }
            #expect(arrived)
            await coordinator.stopForeground()
        }
    }
}

extension Date {
    /// Whole seconds, as a Date header carries it.
    func rounded() -> Date {
        Date(timeIntervalSince1970: timeIntervalSince1970.rounded(.down))
    }
}

/// An unsaved draft in Drafts, ready to send.
func draftRow(_ h: Harness) throws -> MessageID {
    let drafts = try h.folder(.drafts)
    let message = OutgoingMessage(
        from: Address(name: nil, email: "jk@example.org"), to: [Address(name: nil, email: "bo@example.org")],
        cc: [], bcc: [], subject: "Once", textBody: "Only once", htmlBody: nil, attachments: [], inReplyTo: nil,
        references: [], date: fixedNow, messageID: "once@example.org")
    let row = MessageRow(
        id: MessageID(raw: 0), accountID: h.account.id, folderID: drafts.id, uid: 0,
        threadID: ThreadID(raw: "once@example.org"), from: message.from, to: message.to, cc: [], subject: "Once",
        preview: "", date: fixedNow, isRead: true, isFlagged: false, hasAttachment: false, isInvitation: false,
        inboxClass: .focused, hasBody: false, threadCount: 1, messageIDHeader: "once@example.org")
    let id = try #require(try h.store.upsert([row]).first)
    try h.store.setBody(try MIMEWriter.write(message, includeBcc: true), for: id)
    return id
}

final class Flag: Sendable {
    private let value = Mutex(false)

    var isSet: Bool {
        value.withLock { $0 }
    }

    func set() {
        value.withLock { $0 = true }
    }
}
