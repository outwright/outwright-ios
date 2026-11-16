// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightFakes
import OutwrightModel
import OutwrightNet
import OutwrightStore
import OutwrightSync
import Testing

@Suite struct AccountCheckTests {
    @Test func rightPasswordSignsInToBothServers() async throws {
        try await withHarness { h in
            try await AccountCheck.signIn(h.account, password: Secret(FakeIMAPServer.password))
            let logins = await h.imap.loginAttempts
            let auths = await h.smtp.authAttempts
            let received = await h.smtp.received
            #expect(logins == 1)
            #expect(auths == 1)
            #expect(received.isEmpty)
        }
    }

    @Test func wrongPasswordStopsAtIMAP() async throws {
        try await withHarness { h in
            var failure: SyncError?
            do {
                try await AccountCheck.signIn(h.account, password: Secret("wrong-pass"))
            } catch {
                failure = error as? SyncError
            }
            let auths = await h.smtp.authAttempts
            #expect(failure == .imap(.authenticationFailed))
            #expect(auths == 0)
            #expect(!String(describing: failure).contains("wrong-pass"))
        }
    }
}

@Suite struct ServerSearchTests {
    @Test func searchFindsOlderMailOnTheServer() async throws {
        let server = await standardServer()
        await server.deliver(mail("Zebra crossing", date: daysAgo(200), body: "stripes"), to: "INBOX")
        await server.deliver(mail("Recent", date: daysAgo(2)), to: "INBOX")
        try await withHarness(server) { h in
            let coordinator = offlineCoordinator(store: h.store, secrets: h.secrets, now: { fixedNow })
            await coordinator.refreshAll()
            let before = try h.store.search("zebra", limit: 10)
            #expect(before.isEmpty)
            let found = await coordinator.searchServer("zebra")
            #expect(found.count == 1)
            #expect(try h.store.search("zebra", limit: 10).map(\.subject) == ["Zebra crossing"])
            // Asking again brings nothing twice.
            _ = await coordinator.searchServer("zebra")
            #expect(try h.rows(.inbox).count == 2)
        }
    }
}

@Suite struct ExpiryTests {
    @Test func aCancelledRefreshStopsBeforeTouchingTheServer() async throws {
        let server = await standardServer()
        await server.deliver(mail("New"), to: "INBOX")
        try await withHarness(server) { h in
            let coordinator = offlineCoordinator(store: h.store, secrets: h.secrets, now: { fixedNow })
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                await coordinator.refreshAll()
            }
            await task.value
            let logins = await h.imap.loginAttempts
            let folders = try h.store.folders(h.account.id)
            #expect(logins == 0)
            #expect(folders.isEmpty)
        }
    }
}
