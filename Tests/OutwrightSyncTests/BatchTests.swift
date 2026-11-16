// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightFakes
import OutwrightModel
import OutwrightStore
import Testing

@testable import OutwrightSync

@Suite struct BatchTests {
    @Test func aBodyIsFetchedBetweenTheBatchesOfALargeFolder() async throws {
        let server = await standardServer()
        let total = AccountSyncer.batch * 2 + 1
        for index in 0..<total {
            await server.deliver(mail("Number \(index)", id: "n\(index)@example.org"), to: "INBOX")
        }
        try await withHarness(server) { h in
            let syncer = h.syncer()
            try await syncer.syncFolders()
            await server.delayFetches(.milliseconds(300))
            let inbox = try h.folder(.inbox).id
            let folderSync = Task { try await syncer.sync(inbox) }
            #expect(try await eventually { try h.rows(.inbox).count >= AccountSyncer.batch })
            let opened = try #require(try h.rows(.inbox).first)
            try await syncer.fetchBody(opened.id)
            // The body came while the folder was still being read.
            #expect(try h.store.message(opened.id)?.hasBody == true)
            #expect(try h.rows(.inbox).count < total)
            try await folderSync.value
            #expect(try h.rows(.inbox).count == total)
        }
    }

    /// A cancelled sync (background time that ran out) fetches no further batch; the next one
    /// brings in the rest.
    @Test func aCancelledSyncStopsBetweenBatches() async throws {
        let server = await standardServer()
        let total = AccountSyncer.batch * 3
        for index in 0..<total {
            await server.deliver(mail("Number \(index)", id: "n\(index)@example.org"), to: "INBOX")
        }
        try await withHarness(server) { h in
            let syncer = h.syncer()
            try await syncer.syncFolders()
            await server.delayFetches(.milliseconds(300))
            let inbox = try h.folder(.inbox).id
            let folderSync = Task { try await syncer.sync(inbox) }
            #expect(try await eventually { try h.rows(.inbox).count >= AccountSyncer.batch })
            folderSync.cancel()
            _ = await folderSync.result
            #expect(try h.rows(.inbox).count < total)
            await server.delayFetches(.zero)
            try await syncer.sync(inbox)
            #expect(try h.rows(.inbox).count == total)
        }
    }

    @Test func aMessageThatIsOneFileIsMarkedAsHavingAnAttachment() async throws {
        let server = await standardServer()
        let pdf = """
            From: bo@example.org\r\nTo: jk@example.org\r\nSubject: The report\r\n\
            Date: Thu, 05 Nov 2026 10:00:00 +0000\r\nContent-Type: application/pdf; name="r.pdf"\r\n\
            Content-Transfer-Encoding: base64\r\n\r\nJVBERi0xLjQK\r\n
            """
        await server.deliver(Data(pdf.utf8), to: "INBOX")
        try await withHarness(server) { h in
            _ = try await synced(h)
            #expect(try h.rows(.inbox).first?.hasAttachment == true)
        }
    }
}

@Suite struct MovedDuringSyncTests {
    /// A move the owner made after this run's queue went to the server (its action still pending)
    /// does not bring the message back into the folder it left.
    @Test func aMessageMovedAwayIsNotFetchedBackIntoItsOldFolder() async throws {
        let server = await standardServer()
        await server.deliver(mail("Keep me", id: "keep@example.org"), to: "INBOX")
        try await withHarness(server) { h in
            let syncer = h.syncer()
            try await syncer.syncFolders()
            let inbox = try h.folder(.inbox).id
            try await syncer.sync(inbox)
            let row = try #require(try h.rows(.inbox).first)
            try h.store.apply(.move(row.id, to: .archive))
            _ = try await syncer.withMain { client async throws(SyncError) in
                try await syncer.syncMessages(inbox, client)
            }
            #expect(try h.rows(.inbox).isEmpty)
            #expect(try h.store.message(row.id)?.folderID == h.folder(.archive).id)
        }
    }
}
