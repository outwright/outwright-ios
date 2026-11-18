// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightModel
import OutwrightStore
import OutwrightSync
import Testing

/// A push's Inbox update: the Inbox's new mail, and nothing the owner queued.
@Suite struct FetchInboxTests {
    @Test func fetchesNewInboxMail() async throws {
        let server = await standardServer()
        try await withHarness(server) { h in
            let syncer = try await synced(h)
            await server.deliver(mail("fresh"), to: "INBOX")
            try await syncer.fetchInbox()
            #expect(try h.rows(.inbox).map(\.subject) == ["fresh"])
        }
    }

    @Test func leavesQueuedChangesAlone() async throws {
        let server = await standardServer()
        await server.deliver(mail("bin me"), to: "INBOX")
        try await withHarness(server) { h in
            let syncer = try await synced(h)
            let id = try #require(try h.rows(.inbox).first?.id)
            try h.store.apply(.delete(id))
            await server.deliver(mail("fresh"), to: "INBOX")
            try await syncer.fetchInbox()
            #expect(try h.store.pendingActions().count == 1)
            #expect(await server.messages(in: "INBOX").count == 2)
            #expect(await server.messages(in: "Trash").isEmpty)
        }
    }

    @Test func fetchesNoOtherFolder() async throws {
        let server = await standardServer()
        try await withHarness(server) { h in
            let syncer = try await synced(h)
            await server.deliver(mail("sent elsewhere"), to: "Sent")
            await server.deliver(mail("fresh"), to: "INBOX")
            try await syncer.fetchInbox()
            #expect(try h.rows(.sent).isEmpty)
            #expect(try h.rows(.inbox).count == 1)
        }
    }

    @Test func findsTheInboxWhenTheStoreHasNoFolders() async throws {
        let server = await standardServer()
        await server.deliver(mail("first"), to: "INBOX")
        try await withHarness(server) { h in
            try await h.syncer().fetchInbox()
            #expect(try h.rows(.inbox).map(\.subject) == ["first"])
        }
    }

    /// A read the app has queued and not yet sent stays read: the server's flags do not undo it.
    @Test func aQueuedReadIsNotUndone() async throws {
        let server = await standardServer()
        // Every message's flags come back on each sync, as from a server without CONDSTORE.
        await server.offerNoCondstore()
        await server.deliver(mail("read it"), to: "INBOX")
        try await withHarness(server) { h in
            let syncer = try await synced(h)
            let id = try #require(try h.rows(.inbox).first?.id)
            try h.store.apply(.setRead(id, true))
            await server.deliver(mail("fresh"), to: "INBOX")
            try await syncer.fetchInbox()
            #expect(try h.store.message(id)?.isRead == true)
        }
    }
}
