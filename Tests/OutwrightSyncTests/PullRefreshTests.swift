// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightFakes
import OutwrightModel
import OutwrightNet
import OutwrightStore
import OutwrightSync
import Testing

/// A pull on the list brings what the list shows, and only that, so it ends quickly.
@Suite struct PullRefreshTests {
    @Test func aPullOnAllInboxesBringsTheInboxAndNoOtherFolder() async throws {
        let server = await standardServer()
        try await withHarness(server) { h in
            let coordinator = offlineCoordinator(store: h.store, secrets: h.secrets, now: { fixedNow })
            await coordinator.refreshAll()
            await server.deliver(mail("new in the Inbox"), to: "INBOX")
            await server.deliver(mail("new in Sent", from: "jk@example.org"), to: "Sent")
            await coordinator.refreshShown(.allAccounts)
            let inbox = try h.rows(.inbox).map(\.subject)
            let sentRows = try h.rows(.sent)
            #expect(inbox == ["new in the Inbox"])
            #expect(sentRows.isEmpty)
            let error = await coordinator.lastErrors[h.account.id]
            #expect(error == nil)
        }
    }

    @Test func aPullOnAFolderBringsThatFolder() async throws {
        let server = await standardServer()
        try await withHarness(server) { h in
            let coordinator = offlineCoordinator(store: h.store, secrets: h.secrets, now: { fixedNow })
            await coordinator.refreshAll()
            await server.deliver(mail("new in the Inbox"), to: "INBOX")
            await server.deliver(mail("new in Sent", from: "jk@example.org"), to: "Sent")
            let sent = try h.folder(.sent).id
            await coordinator.refreshShown(.folder(sent))
            let sentRows = try h.rows(.sent).map(\.subject)
            let inbox = try h.rows(.inbox)
            #expect(sentRows == ["new in Sent"])
            #expect(inbox.isEmpty)
        }
    }

    /// An account whose server can't be reached has that recorded, for the banner.
    @Test func aPullRecordsAnAccountThatFails() async throws {
        let server = await standardServer()
        try await withHarness(server) { h in
            let coordinator = offlineCoordinator(store: h.store, secrets: h.secrets, now: { fixedNow })
            await coordinator.refreshAll()
            try h.secrets.setPassword(Secret("wrong"), for: h.account.id)
            let changed = offlineCoordinator(store: h.store, secrets: h.secrets, now: { fixedNow })
            await changed.refreshShown(.allAccounts)
            let error = await changed.lastErrors[h.account.id]
            #expect(error == .imap(.authenticationFailed))
        }
    }
}
