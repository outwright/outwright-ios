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

@Suite struct QueueTests {
    @Test func aQueuedChangeReachesTheServerWithoutARefresh() async throws {
        let server = await standardServer()
        await server.deliver(mail("flag me"), to: "INBOX")
        try await withHarness(server) { h in
            let coordinator = offlineCoordinator(
                store: h.store, secrets: h.secrets, now: { fixedNow }, actionDelay: .milliseconds(100))
            await coordinator.refreshAll()
            let id = try #require(try h.rows(.inbox).first?.id)
            try h.store.apply(.setFlagged(id, true))
            #expect(await eventually { await server.messages(in: "INBOX").first?.flags.contains("\\Flagged") == true })
            // The server applies the change before the queue lets go of it: wait for both.
            #expect(try await eventually { try h.store.pendingActions().isEmpty })
        }
    }

    @Test func anIdleThatTimesOutSendsTheQueue() async throws {
        let server = await standardServer()
        await server.deliver(mail("flag me while idle"), to: "INBOX")
        try await withHarness(server) { h in
            // No kick comes in time: only the end of the IDLE sends the change.
            let coordinator = offlineCoordinator(
                store: h.store, secrets: h.secrets, now: { fixedNow }, actionDelay: .seconds(3_600),
                idleTimeout: .milliseconds(300))
            await coordinator.startForeground()
            await server.waitUntilIdling()
            let id = try #require(try h.rows(.inbox).first?.id)
            try h.store.apply(.setFlagged(id, true))
            #expect(await eventually { await server.messages(in: "INBOX").first?.flags.contains("\\Flagged") == true })
            await coordinator.stopForeground()
        }
    }

    /// An action whose message can't be found on a renumbered server.
    private func lostAction(_ h: Harness, _ server: FakeIMAPServer) async throws -> (AccountSyncer, MessageID) {
        let syncer = try await synced(h)
        let id = try #require(try h.rows(.inbox).first?.id)
        try h.store.apply(.setFlagged(id, true))
        let side = try await h.sideClient()
        _ = try await side.select("INBOX")
        try await side.setFlags(["\\Deleted"], on: [1], add: true)
        try await side.expunge([1])
        await side.logout()
        await server.deliver(mail("bystander", id: "c@example.org"), to: "INBOX")
        await server.renumber("INBOX", uidValidity: 9_999)
        return (syncer, id)
    }

    @Test func anActionThatIsNeverFoundIsGivenUpAndSaidSo() async throws {
        let server = await standardServer()
        await server.deliver(mail("deleted elsewhere", id: "a@example.org"), to: "INBOX")
        try await withHarness(server) { h in
            let (syncer, _) = try await lostAction(h, server)
            for _ in 1..<ActionRunner.maxAttempts {
                try await syncer.runActions()
                #expect(try h.store.pendingActions().count == 1)
            }
            await #expect(throws: SyncError.actionAbandoned) { try await syncer.runActions() }
            #expect(try h.store.pendingActions().isEmpty)
            #expect(await server.messages(in: "INBOX").first?.flags.isEmpty == true)
        }
    }

    /// A flag change given up leaves the row as the owner set it: the folder forgets its modseq so
    /// its next sync reconciles in full.
    @Test func aGivenUpFlagChangeForgetsTheFoldersModSeq() async throws {
        let server = await standardServer()
        await server.deliver(mail("deleted elsewhere", id: "a@example.org"), to: "INBOX")
        try await withHarness(server) { h in
            let (syncer, _) = try await lostAction(h, server)
            let inbox = try h.folder(.inbox).id
            #expect(try h.store.highestModSeq(inbox) != nil)
            for _ in 1..<ActionRunner.maxAttempts {
                try await syncer.runActions()
            }
            #expect(try h.store.highestModSeq(inbox) != nil)
            await #expect(throws: SyncError.actionAbandoned) { try await syncer.runActions() }
            #expect(try h.store.highestModSeq(inbox) == nil)
        }
    }

    @Test func anActionWhoseMessageIsGoneHereIsDone() async throws {
        let server = await standardServer()
        await server.deliver(mail("deleted elsewhere", id: "a@example.org"), to: "INBOX")
        try await withHarness(server) { h in
            let (syncer, id) = try await lostAction(h, server)
            try h.store.removeMessage(id)
            try await syncer.runActions()
            #expect(try h.store.pendingActions().isEmpty)
        }
    }

    /// A draft moved to another account in the composer: the old one was never on the server.
    @Test func deletingADraftTheServerNeverHadIsDoneAtOnce() async throws {
        try await withHarness { h in
            let syncer = try await synced(h)
            let id = try localDraft(h, uid: 0, data: try draftData())
            try h.store.apply(.delete(id))
            try await syncer.runActions()
            #expect(try h.store.pendingActions().isEmpty)
        }
    }

    @Test func aDraftDeletedBeforeItsSaveRanNeverReachesTheServer() async throws {
        try await withHarness { h in
            let syncer = try await synced(h)
            let id = try localDraft(h, uid: 0, data: try draftData())
            try h.store.apply(.saveDraft(id))
            try h.store.apply(.delete(id))
            try await syncer.runActions()
            #expect(try h.store.pendingActions().isEmpty)
            #expect(await h.imap.messages(in: "Drafts").isEmpty)
            #expect(await h.imap.messages(in: "Trash").isEmpty)
        }
    }
}
