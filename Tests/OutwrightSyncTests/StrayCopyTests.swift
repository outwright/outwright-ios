// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightFakes
import OutwrightIMAP
import OutwrightModel
import OutwrightStore
import Synchronization
import Testing

@testable import OutwrightSync

/// A move the queue gives up leaves no second copy of a message the server had (#69), and never
/// drops one only the phone has.
@Suite struct StrayCopyTests {
    private func ticking(_ h: Harness) -> (AccountSyncer, @Sendable () -> Void) {
        let clock = Mutex(fixedNow)
        let syncer = AccountSyncer(account: h.account, store: h.store, secrets: h.secrets, now: { clock.withLock { $0 } })
        return (syncer, { clock.withLock { $0 = $0.addingTimeInterval(61) } })
    }

    private func folder(_ h: Harness, _ path: String) throws -> Folder {
        try #require(try h.store.folders(h.account.id).first { $0.path == path })
    }

    /// Rows with `subject` on the phone, in every folder, once each folder has synced.
    private func copies(_ subject: String, _ h: Harness, _ syncer: AccountSyncer) async throws -> Int {
        var count = 0
        for each in try h.store.folders(h.account.id) {
            try? await syncer.sync(each.id)
            let rows = try h.store.messages(InboxQuery(scope: .folder(each.id), inboxClass: nil, filter: .all), limit: 50)
            count += rows.filter { $0.subject == subject }.count
        }
        return count
    }

    private func runs(_ count: Int, _ syncer: AccountSyncer, _ tick: () -> Void) async {
        for _ in 0..<count {
            tick()
            try? await syncer.runActions()
        }
    }

    @Test func aGivenUpRoundTripLeavesOneCopy() async throws {
        let server = await standardServer(offersUIDPlus: false)
        await server.addFolder("Old", specialUse: nil)
        await server.deliver(mail("bounce me"), to: "INBOX")
        try await withHarness(server) { h in
            let (syncer, tick) = ticking(h)
            try await syncer.syncFolders()
            let inbox = try h.folder(.inbox)
            try await syncer.sync(inbox.id)
            let message = try #require(try h.rows(.inbox).first?.id)
            try h.store.apply(.moveTo(message, try folder(h, "Old").id))
            try h.store.apply(.moveTo(message, inbox.id))
            await runs(ActionRunner.maxAttempts + 1, syncer, tick)
            #expect(try await copies("bounce me", h, syncer) == 1)
        }
    }

    @Test func aMessageRemovedElsewhereMidwayLeavesNoCopy() async throws {
        let server = await standardServer()
        await server.addFolder("Old", specialUse: nil)
        await server.addFolder("Keep", specialUse: nil)
        await server.deliver(mail("there and back", id: "back@example.org"), to: "INBOX")
        try await withHarness(server) { h in
            let (syncer, tick) = ticking(h)
            try await syncer.syncFolders()
            try await syncer.sync(try h.folder(.inbox).id)
            let message = try #require(try h.rows(.inbox).first?.id)
            let (old, keep) = (try folder(h, "Old"), try folder(h, "Keep"))
            try h.store.apply(.moveTo(message, old.id))
            try h.store.apply(.moveTo(message, keep.id))
            try h.store.apply(.moveTo(message, old.id))
            await server.refuse("MOVE", path: "Keep")
            await runs(1, syncer, tick)
            let side = try await h.sideClient()
            _ = try await side.select("Old")
            try await side.setFlags(["\\Deleted"], on: [1], add: true)
            try await side.expunge([1])
            await side.logout()
            await runs(ActionRunner.maxAttempts + 1, syncer, tick)
            #expect(try await copies("there and back", h, syncer) == 0)
        }
    }

    @Test func manyMovesWithoutUIDPlusOrMessageIDLeaveOneCopy() async throws {
        let server = await standardServer(offersUIDPlus: false)
        await server.addFolder("Old", specialUse: nil)
        await server.addFolder("Keep", specialUse: nil)
        await server.deliver(mail("no id"), to: "INBOX")
        try await withHarness(server) { h in
            let (syncer, tick) = ticking(h)
            try await syncer.syncFolders()
            try await syncer.sync(try h.folder(.inbox).id)
            let message = try #require(try h.rows(.inbox).first?.id)
            let (old, keep) = (try folder(h, "Old"), try folder(h, "Keep"))
            try h.store.apply(.moveTo(message, old.id))
            try h.store.apply(.moveTo(message, keep.id))
            try h.store.apply(.moveTo(message, old.id))
            await runs(2 * ActionRunner.maxAttempts + 2, syncer, tick)
            #expect(try await copies("no id", h, syncer) == 1)
        }
    }

    @Test func aSentCopyIsKeptWhenDraftsWasRenumbered() async throws {
        try await withHarness { h in
            let (syncer, tick) = ticking(h)
            try await syncer.syncFolders()
            try await syncer.sync(try h.folder(.drafts).id)
            let draft = try localDraft(h, uid: 0, data: try draftData())
            try h.store.apply(.saveDraft(draft))
            try h.store.apply(.send(draftID: draft))
            try h.store.apply(.delete(draft))
            await h.imap.renumber("Drafts", uidValidity: 777)
            await runs(ActionRunner.maxAttempts + 2, syncer, tick)
            #expect(await h.smtp.received.count == 1)
            #expect(await h.imap.messages(in: "Sent").count == 1)
        }
    }

    @Test func aNeverSavedDraftDeletedStaysInTrashWhenDraftsWasRenumbered() async throws {
        try await withHarness { h in
            let (syncer, tick) = ticking(h)
            try await syncer.syncFolders()
            try await syncer.sync(try h.folder(.drafts).id)
            let draft = try localDraft(h, uid: 0, data: try draftData())
            try h.store.apply(.saveDraft(draft))
            try h.store.apply(.delete(draft))
            await h.imap.renumber("Drafts", uidValidity: 777)
            await runs(ActionRunner.maxAttempts + 1, syncer, tick)
            #expect(try h.store.message(draft)?.folderID == h.folder(.trash).id)
        }
    }

    /// Removes every message from the server's Drafts behind the phone's back.
    private func emptyDrafts(_ h: Harness) async throws {
        let side = try await h.sideClient()
        _ = try await side.select("Drafts")
        let uids = await h.imap.messages(in: "Drafts").map(\.uid)
        try await side.setFlags(["\\Deleted"], on: uids, add: true)
        try await side.expunge(uids)
        await side.logout()
    }

    @Test func aSentCopyOfASavedDraftIsKept() async throws {
        try await withHarness { h in
            let (syncer, tick) = ticking(h)
            try await syncer.syncFolders()
            try await syncer.sync(try h.folder(.drafts).id)
            let draft = try localDraft(h, uid: 0, data: try draftData())
            try h.store.apply(.saveDraft(draft))
            await runs(1, syncer, tick)
            try h.store.apply(.send(draftID: draft))
            try h.store.apply(.delete(draft))
            try await emptyDrafts(h)
            await h.imap.renumber("Drafts", uidValidity: 777)
            await runs(ActionRunner.maxAttempts + 2, syncer, tick)
            #expect(await h.smtp.received.count == 1)
            #expect(await h.imap.messages(in: "Sent").count == 1)
        }
    }

    @Test func aSavedDraftEditedHereAndDeletedKeepsItsEdits() async throws {
        try await withHarness { h in
            let (syncer, tick) = ticking(h)
            try await syncer.syncFolders()
            try await syncer.sync(try h.folder(.drafts).id)
            let draft = try localDraft(h, uid: 0, data: try draftData())
            try h.store.apply(.saveDraft(draft))
            await runs(1, syncer, tick)
            try h.store.setBody(mail("Plans", id: "draft1@example.org", body: "Edited on the phone"), for: draft)
            try h.store.apply(.saveDraft(draft))
            try h.store.apply(.delete(draft))
            try await emptyDrafts(h)
            await h.imap.renumber("Drafts", uidValidity: 777)
            await runs(ActionRunner.maxAttempts + 1, syncer, tick)
            #expect(try h.store.message(draft)?.folderID == h.folder(.trash).id)
        }
    }

    @Test func anOldMessageGivenUpStillShowsOnThePhone() async throws {
        let server = await standardServer(offersUIDPlus: false)
        await server.addFolder("Old", specialUse: nil)
        await server.deliver(mail("ancient", date: daysAgo(200)), to: "INBOX")
        try await withHarness(server) { h in
            let (syncer, tick) = ticking(h)
            try await syncer.syncFolders()
            let inbox = try h.folder(.inbox)
            try await syncer.sync(inbox.id)
            _ = try await syncer.fetchOlder(inbox.id, atLeast: 50)
            let old = try folder(h, "Old")
            try await syncer.sync(old.id)
            try h.store.setHeldSince(old.id, .distantPast)
            let rows = try h.store.messages(InboxQuery(scope: .folder(inbox.id), inboxClass: nil, filter: .all), limit: 50)
            let message = try #require(rows.first { $0.subject == "ancient" }?.id)
            try h.store.apply(.moveTo(message, old.id))
            try h.store.apply(.moveTo(message, inbox.id))
            await runs(ActionRunner.maxAttempts + 1, syncer, tick)
            #expect(try await copies("ancient", h, syncer) == 1)
        }
    }

    @Test func aMoveTheServerAlreadyDidKeepsItsRow() async throws {
        let server = await standardServer()
        await server.addFolder("Old", specialUse: nil)
        await server.addFolder("Keep", specialUse: nil)
        await server.deliver(mail("done already", id: "done@example.org"), to: "INBOX")
        try await withHarness(server) { h in
            let (syncer, tick) = ticking(h)
            try await syncer.syncFolders()
            try await syncer.sync(try h.folder(.inbox).id)
            let message = try #require(try h.rows(.inbox).first?.id)
            let (old, keep) = (try folder(h, "Old"), try folder(h, "Keep"))
            try h.store.apply(.moveTo(message, old.id))
            try h.store.apply(.moveTo(message, keep.id))
            // Both moves reached the server; their answers never came back.
            let side = try await h.sideClient()
            _ = try await side.select("INBOX")
            _ = try await side.move([1], to: "Keep")
            await side.logout()
            await runs(2, syncer, tick)
            let row = try #require(try h.store.message(message))
            #expect(row.folderID == keep.id)
            #expect(row.uid > 0)
        }
    }

    @Test func aGoneMoveIntoAFolderTheServerLacksIsNotStuck() async throws {
        let server = await standardServer()
        await server.addFolder("Old", specialUse: nil)
        await server.deliver(mail("archive me", id: "arch@example.org"), to: "INBOX")
        try await withHarness(server) { h in
            let (syncer, tick) = ticking(h)
            try await syncer.syncFolders()
            try await syncer.sync(try h.folder(.inbox).id)
            let message = try #require(try h.rows(.inbox).first?.id)
            try h.store.apply(.moveTo(message, try folder(h, "Old").id))
            try h.store.apply(.move(message, to: .archive))
            let side = try await h.sideClient()
            _ = try await side.select("INBOX")
            try await side.setFlags(["\\Deleted"], on: [1], add: true)
            try await side.expunge([1])
            await side.logout()
            await runs(ActionRunner.maxAttempts + 2, syncer, tick)
            #expect(try h.store.pendingActions().isEmpty)
        }
    }

    @Test func aFullyScrolledFolderSyncsWithoutAnAncientDate() async throws {
        let server = await standardServer()
        await server.deliver(mail("old one", date: daysAgo(200)), to: "INBOX")
        try await withHarness(server) { h in
            let syncer = h.syncer()
            try await syncer.syncFolders()
            let inbox = try h.folder(.inbox)
            try await syncer.sync(inbox.id)
            _ = try await syncer.fetchOlder(inbox.id, atLeast: 50)
            try h.store.setHeldSince(inbox.id, .distantPast)
            await server.forgetServedCommands()
            try await syncer.sync(inbox.id)
            let searches = await server.servedCommands.filter { $0.contains("SEARCH") }
            #expect(!searches.contains { $0.contains("0001") })
            #expect(!searches.contains { $0.contains("SINCE") && !$0.contains("UNDELETED") })
        }
    }

    @Test func messagesMarkedDeletedAreNotFetchedAgain() async throws {
        let server = await standardServer()
        await server.deliver(mail("marked"), to: "INBOX", flags: ["\\Deleted"])
        try await withHarness(server) { h in
            let syncer = h.syncer()
            try await syncer.syncFolders()
            let inbox = try h.folder(.inbox)
            try await syncer.sync(inbox.id)
            await server.forgetServedCommands()
            try await syncer.sync(inbox.id)
            #expect(!(await server.servedCommands.contains { $0.contains("BODY.PEEK[HEADER]") }))
        }
    }

    @Test func anEditedDraftDeletedWhileTheServerLostItKeepsItsEdits() async throws {
        try await withHarness { h in
            let (syncer, tick) = ticking(h)
            try await syncer.syncFolders()
            try await syncer.sync(try h.folder(.drafts).id)
            let draft = try localDraft(h, uid: 0, data: try draftData())
            try h.store.apply(.saveDraft(draft))
            await runs(1, syncer, tick)
            try h.store.setBody(mail("Plans", id: "draft1@example.org", body: "Edited on the phone"), for: draft)
            try h.store.apply(.saveDraft(draft))
            try h.store.apply(.delete(draft))
            try await emptyDrafts(h)
            await runs(ActionRunner.maxAttempts + 1, syncer, tick)
            #expect(try h.store.message(draft)?.folderID == h.folder(.trash).id)
        }
    }
}

