// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightFakes
import OutwrightModel
import OutwrightStore
import Testing

@testable import OutwrightSync

@Suite struct ThreadingSyncTests {
    @Test func aReplySyncedBeforeItsParentJoinsItsConversation() async throws {
        let server = await standardServer()
        await server.deliver(
            mail("Re: Plans", from: "jk@example.org", to: "bo@example.org", date: daysAgo(1), id: "reply@example.org",
                 inReplyTo: "parent@example.org"), to: "Sent")
        await server.deliver(mail("Plans", date: daysAgo(2), id: "parent@example.org"), to: "INBOX")
        try await withHarness(server) { h in
            let syncer = h.syncer()
            try await syncer.syncFolders()
            // Sent first, as a refresh does: the reply comes before the message it answers.
            try await syncer.sync(try h.folder(.sent).id)
            try await syncer.sync(try h.folder(.inbox).id)
            let reply = try #require(try h.rows(.sent).first)
            let parent = try #require(try h.rows(.inbox).first)
            #expect(reply.threadID == parent.threadID)
            #expect(try h.store.thread(parent.threadID, account: h.account.id).count == 2)
        }
    }

    @Test func aLaterBatchBringsItsAnswersIntoTheParentsThread() async throws {
        let server = await standardServer()
        // Over one batch of replies in Inbox, their parent last (the highest uid).
        for index in 0..<(AccountSyncer.batch + 5) {
            await server.deliver(
                mail("Re: Big", date: daysAgo(1), id: "r\(index)@example.org", inReplyTo: "root@example.org"),
                to: "INBOX")
        }
        await server.deliver(mail("Big", date: daysAgo(3), id: "root@example.org"), to: "INBOX")
        try await withHarness(server) { h in
            _ = try await synced(h)
            let rows = try h.rows(.inbox)
            #expect(rows.count == AccountSyncer.batch + 6)
            #expect(Set(rows.map(\.threadID)).count == 1)
        }
    }
}
