// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightFakes
import OutwrightModel
import OutwrightStore
import OutwrightSync
import Testing

@Suite struct OlderMailTests {
    @Test func olderMailComesAPageAtATimeNewestFirst() async throws {
        let server = await standardServer()
        await server.deliver(mail("this week", date: daysAgo(2)), to: "INBOX")
        await server.deliver(mail("three months", date: daysAgo(100)), to: "INBOX")
        await server.deliver(mail("seven months", date: daysAgo(200)), to: "INBOX")
        await server.deliver(mail("eight years", date: daysAgo(3_000)), to: "INBOX")
        try await withHarness(server) { h in
            let syncer = h.syncer()
            try await syncer.syncFolders()
            let inbox = try h.folder(.inbox).id
            try await syncer.sync(inbox)
            #expect(try h.rows(.inbox).map(\.subject) == ["this week"])

            #expect(try await syncer.fetchOlder(inbox, atLeast: 1))
            #expect(Set(try h.rows(.inbox).map(\.subject)) == ["this week", "three months"])
            #expect(try await syncer.fetchOlder(inbox, atLeast: 1))
            #expect(Set(try h.rows(.inbox).map(\.subject)) == ["this week", "three months", "seven months"])
            #expect(try await syncer.fetchOlder(inbox, atLeast: 1) == false, "nothing is older than the last")
            #expect(try h.rows(.inbox).count == 4)
            #expect(try await syncer.fetchOlder(inbox, atLeast: 1) == false)
            #expect(try h.rows(.inbox).count == 4)
        }
    }

    @Test func mailAlreadyHeldIsNotFetchedAgainAndDoesNotStopThePaging() async throws {
        let server = await standardServer()
        await server.deliver(mail("found by a search", date: daysAgo(400)), to: "INBOX")
        await server.deliver(mail("older still", date: daysAgo(500)), to: "INBOX")
        try await withHarness(server) { h in
            let syncer = h.syncer()
            try await syncer.syncFolders()
            let inbox = try h.folder(.inbox).id
            try await syncer.sync(inbox)
            _ = try await syncer.searchServer("found by a search", limit: 5)
            #expect(try h.rows(.inbox).count == 1)
            #expect(try await syncer.fetchOlder(inbox, atLeast: 1) == false)
            #expect(Set(try h.rows(.inbox).map(\.subject)) == ["found by a search", "older still"])
        }
    }

    /// A folder the server renumbered since the last sync is searched by its new numbers, not
    /// matched against the old ones held here.
    @Test func aSearchOfARenumberedFolderFindsWhatTheOldNumbersHide() async throws {
        let server = await standardServer()
        let first = await server.deliver(mail("goes away"), to: "INBOX")
        await server.deliver(mail("stays"), to: "INBOX")
        try await withHarness(server) { h in
            let syncer = h.syncer()
            try await syncer.syncFolders()
            try await syncer.sync(try h.folder(.inbox).id)
            let side = try await h.sideClient()
            _ = try await side.select("INBOX")
            try await side.setFlags(["\\Deleted"], on: [first], add: true)
            try await side.expunge([first])
            await side.logout()
            await server.deliver(mail("zebra"), to: "INBOX")
            // "stays" is now uid 1 and "zebra" uid 2, the number "stays" had here.
            await server.renumber("INBOX", uidValidity: 9_999)
            let found = try await syncer.searchServer("zebra", limit: 5)
            #expect(try found.compactMap { try h.store.message($0)?.subject } == ["zebra"])
        }
    }

    @Test func laterSyncsKeepTheOlderMail() async throws {
        let server = await standardServer()
        await server.deliver(mail("old", date: daysAgo(150)), to: "INBOX")
        try await withHarness(server) { h in
            let syncer = h.syncer()
            try await syncer.syncFolders()
            let inbox = try h.folder(.inbox).id
            try await syncer.sync(inbox)
            _ = try await syncer.fetchOlder(inbox, atLeast: 1)
            try await syncer.sync(inbox)
            #expect(try h.rows(.inbox).map(\.subject) == ["old"])
        }
    }
}

@Suite struct OlderMailCoordinatorTests {
    @Test func everyAccountsInboxIsPagedForAllAccounts() async throws {
        let server = await standardServer()
        await server.deliver(mail("old", date: daysAgo(150)), to: "INBOX")
        await server.deliver(mail("old sent", date: daysAgo(150)), to: "Sent")
        try await withHarness(server) { h in
            let coordinator = offlineCoordinator(store: h.store, secrets: h.secrets, now: { fixedNow })
            await coordinator.refreshAll()
            #expect(try h.rows(.inbox).isEmpty)
            let more = await coordinator.fetchOlder(.allAccounts, atLeast: 10)
            #expect(more == .noneLeft)
            #expect(try h.rows(.inbox).map(\.subject) == ["old"])
            #expect(try h.rows(.sent).isEmpty, "only the Inboxes are in that list")
            let sent = try h.folder(.sent).id
            let moreSent = await coordinator.fetchOlder(.folder(sent), atLeast: 10)
            #expect(moreSent == .noneLeft)
            #expect(try h.rows(.sent).map(\.subject) == ["old sent"])
        }
    }

    @Test func anAccountWithNoPasswordFailsRatherThanHavingMore() async throws {
        let server = await standardServer()
        await server.deliver(mail("old", date: daysAgo(150)), to: "INBOX")
        try await withHarness(server) { h in
            await offlineCoordinator(store: h.store, secrets: h.secrets, now: { fixedNow }).refreshAll()
            // The password is gone from the phone since.
            let coordinator = offlineCoordinator(store: h.store, secrets: InMemorySecretStore(), now: { fixedNow })
            #expect(await coordinator.fetchOlder(.allAccounts, atLeast: 10) == .failed)
            #expect(await coordinator.lastErrors[h.account.id] == .noPassword)
        }
    }
}
