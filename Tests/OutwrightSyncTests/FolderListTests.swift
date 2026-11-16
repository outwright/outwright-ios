// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightFakes
import OutwrightIMAP
import OutwrightMIME
import OutwrightModel
import OutwrightStore
import Testing

@testable import OutwrightSync

@Suite struct FolderListTests {
    @Test func draftsMissingFromListKeepsAQueuedSendAndSendsIt() async throws {
        let server = FakeIMAPServer()
        await server.addFolder("Sent", specialUse: "\\Sent")
        await server.addFolder("Brouillons", specialUse: "\\Drafts")
        await server.addFolder("Trash", specialUse: "\\Trash")
        try await withHarness(server) { h in
            let syncer = try await synced(h)
            let id = try localDraft(h, uid: 0, data: try draftData())
            try h.store.apply(.send(draftID: id))
            // The server leaves Drafts out of LIST once; the queued send and its draft stay.
            await server.leaveOutOfList("Brouillons")
            try await syncer.syncFolders()
            #expect(try h.store.message(id) != nil)
            #expect(try h.store.pendingActions().count == 1)

            try await syncer.runActions()
            #expect(await h.smtp.received.count == 1)
            #expect(await server.messages(in: "Sent").count == 1)
            #expect(try h.store.pendingActions().isEmpty)
        }
    }

    @Test func listWithoutInboxKeepsEverything() async throws {
        let server = await standardServer()
        await server.deliver(mail("keep me"), to: "INBOX")
        try await withHarness(server) { h in
            let syncer = try await synced(h)
            let before = try h.store.folders(h.account.id).map(\.path)
            await server.leaveOutOfList("INBOX")
            await #expect(throws: SyncError.self) { try await syncer.syncFolders() }
            #expect(try h.store.folders(h.account.id).map(\.path) == before)
            #expect(try h.rows(.inbox).count == 1)
        }
    }

    @Test func aListedFolderKeepsTheServersDelimiter() async throws {
        let server = await standardServer()
        await server.addFolder("Projects", specialUse: nil)
        await server.addFolder("Projects/Old", specialUse: nil)
        try await withHarness(server) { h in
            _ = try await synced(h)
            let old = try #require(try h.store.folders(h.account.id).first { $0.path == "Projects/Old" })
            #expect(old.name == "Old")
            #expect(old.delimiter == "/")
        }
    }
}
