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

/// The fake's subjects in `path`.
private func subjects(_ server: FakeIMAPServer, _ path: String) async -> [String] {
    await server.messages(in: path).compactMap { message in
        String(decoding: message.data, as: UTF8.self).split(separator: "\r\n")
            .first { $0.hasPrefix("Subject: ") }.map { String($0.dropFirst(9)) }
    }
}

/// A syncer whose clock moves on a minute and more each time `tick` is called.
private func tickingSyncer(_ h: Harness) -> (AccountSyncer, @Sendable () -> Void) {
    let clock = Mutex(fixedNow)
    let syncer = AccountSyncer(account: h.account, store: h.store, secrets: h.secrets, now: { clock.withLock { $0 } })
    return (syncer, { clock.withLock { $0 = $0.addingTimeInterval(61) } })
}

@Suite struct FolderActionTests {
    private func path(_ h: Harness, _ id: FolderID) throws -> String? {
        try h.store.folders(h.account.id).first { $0.id == id }?.path
    }

    private func folder(_ h: Harness, _ path: String) throws -> Folder {
        try #require(try h.store.folders(h.account.id).first { $0.path == path })
    }

    @Test func aCreatedFolderReachesTheServerSubscribed() async throws {
        try await withHarness { h in
            let syncer = try await synced(h)
            let wire = ModifiedUTF7.encode("Kvitton & Öre")
            _ = try h.store.createFolder(named: "Kvitton & Öre", wire: wire, in: nil, account: h.account.id, prefix: "")
            try await syncer.runActions()
            #expect(await h.imap.folderPaths().contains(wire))
            #expect(await h.imap.subscribedPaths().contains(wire))
            #expect(try h.store.pendingActions().isEmpty)
        }
    }

    @Test func aRenameReachesTheServerWithSubscriptionsMoved() async throws {
        let server = await standardServer()
        await server.addFolder("Projects", specialUse: nil)
        await server.addFolder("Projects/2026", specialUse: nil)
        try await withHarness(server) { h in
            let syncer = try await synced(h)
            let side = try await h.sideClient()
            try await side.subscribe("Projects")
            await side.logout()
            try h.store.renameFolder(try folder(h, "Projects").id, to: "Work", wire: "Work", under: nil, prefix: "")
            try await syncer.runActions()
            let paths = await server.folderPaths()
            #expect(paths.contains("Work") && paths.contains("Work/2026"))
            #expect(!paths.contains("Projects"))
            #expect(await server.subscribedPaths().contains("Work"))
            #expect(await !server.subscribedPaths().contains("Projects"))
            #expect(try h.store.pendingActions().isEmpty)
        }
    }

    @Test func aDeleteRemovesTheWholeServerSubtreeDeepestFirst() async throws {
        let server = await standardServer()
        await server.addFolder("Old", specialUse: nil)
        await server.addFolder("Old/Deep", specialUse: nil)
        await server.addFolder("Older", specialUse: nil)
        try await withHarness(server) { h in
            let syncer = try await synced(h)
            // One the phone never listed, made by another client since.
            await server.addFolder("Old/Deep/Deeper", specialUse: nil)
            try h.store.deleteFolder(try folder(h, "Old").id)
            try await syncer.runActions()
            let paths = await server.folderPaths()
            #expect(!paths.contains { $0 == "Old" || $0.hasPrefix("Old/") })
            #expect(paths.contains("Older"))
            #expect(try h.store.pendingActions().isEmpty)
        }
    }

    @Test func aMoveIntoANewFolderMadeOfflineArrives() async throws {
        let server = await standardServer()
        await server.deliver(mail("receipt"), to: "INBOX")
        try await withHarness(server) { h in
            let syncer = try await synced(h)
            let message = try #require(try h.rows(.inbox).first?.id)
            let made = try h.store.createFolder(named: "Receipts", wire: "Receipts", in: nil, account: h.account.id, prefix: "")
            try h.store.apply(.moveTo(message, made))
            try await syncer.runActions()
            #expect(await subjects(server, "Receipts") == ["receipt"])
            #expect(await server.messages(in: "INBOX").isEmpty)
        }
    }

    @Test func aMoveQueuedBeforeARenameGoesToTheRenamedFolder() async throws {
        let server = await standardServer()
        await server.addFolder("Projects", specialUse: nil)
        await server.deliver(mail("plan"), to: "INBOX")
        try await withHarness(server) { h in
            let syncer = try await synced(h)
            let message = try #require(try h.rows(.inbox).first?.id)
            let projects = try folder(h, "Projects")
            try h.store.apply(.moveTo(message, projects.id))
            try h.store.renameFolder(projects.id, to: "Work", wire: "Work", under: nil, prefix: "")
            try await syncer.runActions()
            #expect(await subjects(server, "Work") == ["plan"])
            #expect(try h.store.pendingActions().isEmpty)
        }
    }

    @Test func aMoveOutQueuedBeforeADeleteRunsFirst() async throws {
        let server = await standardServer()
        await server.addFolder("Old", specialUse: nil)
        await server.deliver(mail("keep me"), to: "Old")
        try await withHarness(server) { h in
            let syncer = try await synced(h)
            let old = try folder(h, "Old")
            try await syncer.sync(old.id)
            let message = try #require(try h.store.folderIndex(old.id).values.first)
            try h.store.apply(.moveTo(message, try h.folder(.inbox).id))
            try h.store.deleteFolder(old.id)
            try await syncer.runActions()
            #expect(await subjects(server, "INBOX") == ["keep me"])
            #expect(await !server.folderPaths().contains("Old"))
            #expect(try h.store.pendingActions().isEmpty)
        }
    }

    @Test func aRefusedCreateSendsFiledMailBack() async throws {
        let server = await standardServer()
        await server.deliver(mail("receipt"), to: "INBOX")
        try await withHarness(server) { h in
            let syncer = try await synced(h)
            let message = try #require(try h.rows(.inbox).first?.id)
            let made = try h.store.createFolder(named: "Receipts", wire: "Receipts", in: nil, account: h.account.id, prefix: "")
            try h.store.apply(.moveTo(message, made))
            await server.refuse("CREATE", path: "Receipts")
            await #expect(throws: SyncError.folderChangeRefused("Receipts")) { try await syncer.runActions() }
            #expect(try h.store.message(message)?.folderID == h.folder(.inbox).id)
            #expect(try path(h, made) == nil)
            #expect(try h.store.pendingActions().isEmpty)
            #expect(await subjects(server, "INBOX") == ["receipt"])
        }
    }

    @Test func aRefusedRenameRestoresTheOldPath() async throws {
        let server = await standardServer()
        await server.addFolder("Projects", specialUse: nil)
        await server.addFolder("Projects/2026", specialUse: nil)
        try await withHarness(server) { h in
            let syncer = try await synced(h)
            let projects = try folder(h, "Projects")
            let child = try folder(h, "Projects/2026")
            try h.store.renameFolder(projects.id, to: "Work", wire: "Work", under: nil, prefix: "")
            await server.refuse("RENAME", path: "Projects")
            await #expect(throws: SyncError.folderChangeRefused("Work")) { try await syncer.runActions() }
            #expect(try path(h, projects.id) == "Projects")
            #expect(try h.store.folders(h.account.id).first { $0.id == projects.id }?.name == "Projects")
            #expect(try path(h, child.id) == "Projects/2026")
            #expect(try h.store.pendingActions().isEmpty)
        }
    }

    @Test func aDeleteOfAFolderAlreadyGoneIsDone() async throws {
        let server = await standardServer()
        await server.addFolder("Old", specialUse: nil)
        try await withHarness(server) { h in
            let syncer = try await synced(h)
            try h.store.deleteFolder(try folder(h, "Old").id)
            let side = try await h.sideClient()
            try await side.delete("Old")
            await side.logout()
            try await syncer.runActions()
            #expect(try h.store.pendingActions().isEmpty)
        }
    }

    @Test func aChangeAfterAMoveAndARenameFindsTheRenamedFolder() async throws {
        let server = await standardServer()
        await server.addFolder("Projects", specialUse: nil)
        await server.deliver(mail("plan"), to: "INBOX")
        try await withHarness(server) { h in
            let syncer = try await synced(h)
            let message = try #require(try h.rows(.inbox).first?.id)
            let projects = try folder(h, "Projects")
            try h.store.apply(.moveTo(message, projects.id))
            try h.store.renameFolder(projects.id, to: "Work", wire: "Work", under: nil, prefix: "")
            try h.store.apply(.setFlagged(message, true))
            try await syncer.runActions()
            #expect(await server.messages(in: "Work").first?.flags.contains("\\Flagged") == true)
            #expect(try h.store.pendingActions().isEmpty)
        }
    }

    @Test func aRenameKeepsTheSubfoldersSubscribed() async throws {
        let server = await standardServer()
        await server.addFolder("Projects", specialUse: nil)
        await server.addFolder("Projects/2026", specialUse: nil)
        try await withHarness(server) { h in
            let syncer = try await synced(h)
            let side = try await h.sideClient()
            try await side.subscribe("Projects")
            try await side.subscribe("Projects/2026")
            await side.logout()
            try h.store.renameFolder(try folder(h, "Projects").id, to: "Work", wire: "Work", under: nil, prefix: "")
            try await syncer.runActions()
            #expect(await server.subscribedPaths() == ["Work", "Work/2026"])
        }
    }

    @Test func aStuckFolderChangeLetsOtherMailThrough() async throws {
        let server = await standardServer()
        await server.addFolder("Projects", specialUse: nil)
        await server.deliver(mail("flag me"), to: "INBOX")
        try await withHarness(server) { h in
            let syncer = try await synced(h)
            let projects = try folder(h, "Projects")
            try h.store.renameFolder(projects.id, to: "Work", wire: "Work", under: nil, prefix: "")
            let message = try #require(try h.rows(.inbox).first?.id)
            try h.store.apply(.setFlagged(message, true))
            await server.refuse("RENAME", path: "Projects", code: "UNAVAILABLE")
            await #expect(throws: SyncError.self) { try await syncer.runActions() }
            #expect(await server.messages(in: "INBOX").first?.flags.contains("\\Flagged") == true)
            #expect(try h.store.pendingActions().count == 1)
        }
    }

    @Test func aFolderMadeAfterTheRunnerReadTheFoldersStillReachesTheServer() async throws {
        try await withHarness { h in
            _ = try await synced(h)
            let before = try h.store.folders(h.account.id)
            _ = try h.store.createFolder(named: "Late", wire: "Late", in: nil, account: h.account.id, prefix: "")
            let client = try await h.sideClient()
            var runner = ActionRunner(
                account: h.account, store: h.store, client: client, secrets: h.secrets, now: fixedNow, folders: before)
            _ = try await runner.run(try h.store.pendingActions())
            await client.logout()
            #expect(await h.imap.folderPaths().contains("Late"))
        }
    }

    @Test func aSubscriptionListThatFailsLeavesTheRenameDone() async throws {
        let server = await standardServer()
        await server.addFolder("Projects", specialUse: nil)
        try await withHarness(server) { h in
            let syncer = try await synced(h)
            let projects = try folder(h, "Projects")
            try h.store.renameFolder(projects.id, to: "Work", wire: "Work", under: nil, prefix: "")
            await server.refuse("LSUB", path: "")
            try await syncer.runActions()
            #expect(await server.folderPaths().contains("Work"))
            #expect(try path(h, projects.id) == "Work")
        }
    }

    @Test func aRenameKeepsOnlyTheSubscribedSubfoldersSubscribed() async throws {
        let server = await standardServer()
        await server.addFolder("Projects", specialUse: nil)
        await server.addFolder("Projects/Shown", specialUse: nil)
        await server.addFolder("Projects/Hidden", specialUse: nil)
        try await withHarness(server) { h in
            let syncer = try await synced(h)
            let side = try await h.sideClient()
            try await side.subscribe("Projects")
            try await side.subscribe("Projects/Shown")
            await side.logout()
            try h.store.renameFolder(try folder(h, "Projects").id, to: "Work", wire: "Work", under: nil, prefix: "")
            try await syncer.runActions()
            #expect(await server.subscribedPaths() == ["Work", "Work/Shown"])
        }
    }

    @Test func changesQueuedInARefusedNewFolderActWhereTheMessageIs() async throws {
        let server = await standardServer()
        await server.deliver(mail("flag me"), to: "INBOX")
        await server.deliver(mail("move me on"), to: "INBOX")
        try await withHarness(server) { h in
            let syncer = try await synced(h)
            let rows = try h.rows(.inbox)
            let (first, second) = (try #require(rows.first?.id), try #require(rows.last?.id))
            let made = try h.store.createFolder(named: "New", wire: "New", in: nil, account: h.account.id, prefix: "")
            try h.store.apply(.moveTo(first, made))
            try h.store.apply(.moveTo(second, made))
            try h.store.apply(.setFlagged(first, true))
            try h.store.apply(.moveTo(second, try h.folder(.trash).id))
            await server.refuse("CREATE", path: "New")
            await #expect(throws: SyncError.self) { try await syncer.runActions() }
            #expect(await server.messages(in: "INBOX").contains { $0.flags.contains("\\Flagged") })
            #expect(await subjects(server, "Trash") == ["move me on"])
            #expect(try h.store.pendingActions().isEmpty)
        }
    }

    @Test func aRenameWhoseAnswerWasLostStillMovesTheSubscriptions() async throws {
        let server = await standardServer()
        await server.addFolder("Projects", specialUse: nil)
        await server.addFolder("Projects/Shown", specialUse: nil)
        try await withHarness(server) { h in
            let syncer = try await synced(h)
            let side = try await h.sideClient()
            try await side.subscribe("Projects")
            try await side.subscribe("Projects/Shown")
            try h.store.renameFolder(try folder(h, "Projects").id, to: "Work", wire: "Work", under: nil, prefix: "")
            // The RENAME went through; its answer never came back.
            try await side.rename(from: "Projects", to: "Work")
            await side.logout()
            try await syncer.runActions()
            #expect(await server.subscribedPaths() == ["Work", "Work/Shown"])
        }
    }

    @Test func aDeleteWaitsForAFailedMoveOutOfIt() async throws {
        let server = await standardServer()
        await server.addFolder("Old", specialUse: nil)
        await server.addFolder("Keep", specialUse: nil)
        await server.deliver(mail("keep me"), to: "Old")
        try await withHarness(server) { h in
            let syncer = try await synced(h)
            let old = try folder(h, "Old")
            try await syncer.sync(old.id)
            let message = try #require(try h.store.folderIndex(old.id).values.first)
            try h.store.apply(.moveTo(message, try folder(h, "Keep").id))
            try h.store.deleteFolder(old.id)
            await server.refuse("MOVE", path: "Keep")
            await #expect(throws: SyncError.self) { try await syncer.runActions() }
            #expect(await subjects(server, "Old") == ["keep me"])
            #expect(try h.store.pendingActions().count == 2)
            try await syncer.runActions()
            #expect(await subjects(server, "Keep") == ["keep me"])
            #expect(await !server.folderPaths().contains("Old"))
        }
    }

    @Test func aFolderChangeThatKeepsFailingIsGivenUpAndUndone() async throws {
        let server = await standardServer()
        await server.addFolder("Projects", specialUse: nil)
        try await withHarness(server) { h in
            let (syncer, tick) = tickingSyncer(h)
            try await syncer.syncFolders()
            let projects = try folder(h, "Projects")
            try h.store.renameFolder(projects.id, to: "Work", wire: "Work", under: nil, prefix: "")
            await server.refuse("RENAME", path: "Projects", code: "SERVERBUG", times: ActionRunner.maxAttempts)
            var last: SyncError?
            for _ in 0..<ActionRunner.maxAttempts {
                tick()
                do { try await syncer.runActions() } catch { last = error as? SyncError }
            }
            #expect(last == .folderChangeRefused("Work"))
            #expect(try path(h, projects.id) == "Projects")
            #expect(try !h.store.isFolderChangeWaiting(h.account.id))
            #expect(try h.store.folderRefusals()[h.account.id] == FolderRefusal(name: "Work", gaveUp: true))
        }
    }

    @Test func runsCloseTogetherCountAsOneTry() async throws {
        let server = await standardServer()
        await server.addFolder("Projects", specialUse: nil)
        try await withHarness(server) { h in
            let syncer = try await synced(h)
            let projects = try folder(h, "Projects")
            try h.store.renameFolder(projects.id, to: "Work", wire: "Work", under: nil, prefix: "")
            await server.refuse("RENAME", path: "Projects", code: "UNAVAILABLE", times: ActionRunner.maxAttempts + 1)
            for _ in 0...ActionRunner.maxAttempts {
                try? await syncer.runActions()
            }
            #expect(try h.store.isFolderChangeWaiting(h.account.id))
        }
    }

    @Test func aGivenUpDeleteBringsTheFolderBackWithItsQueuedMove() async throws {
        let server = await standardServer()
        await server.addFolder("Old", specialUse: nil)
        await server.addFolder("Keep", specialUse: nil)
        await server.deliver(mail("keep me"), to: "Old")
        try await withHarness(server) { h in
            let (syncer, tick) = tickingSyncer(h)
            try await syncer.syncFolders()
            let old = try folder(h, "Old")
            try await syncer.sync(old.id)
            let message = try #require(try h.store.folderIndex(old.id).values.first)
            try h.store.apply(.moveTo(message, try folder(h, "Keep").id))
            try h.store.deleteFolder(old.id)
            await server.refuse("MOVE", path: "Keep", times: 100)
            for _ in 0..<ActionRunner.maxAttempts {
                tick()
                try? await syncer.runActions()
            }
            #expect(try path(h, old.id) == "Old")
            #expect(try h.store.pendingActions().map(\.action) == [.moveTo(message, try folder(h, "Keep").id)])
            #expect(await subjects(server, "Old") == ["keep me"])
            #expect(try h.store.folderRefusals()[h.account.id] == FolderRefusal(name: "Old", gaveUp: true))
        }
    }

    @Test func aFolderRefusalDoesNotHideAMailChangesError() async throws {
        let server = await standardServer()
        await server.addFolder("Keep", specialUse: nil)
        await server.deliver(mail("move me"), to: "INBOX")
        try await withHarness(server) { h in
            let syncer = try await synced(h)
            _ = try h.store.createFolder(named: "Receipts", wire: "Receipts", in: nil, account: h.account.id, prefix: "")
            let message = try #require(try h.rows(.inbox).first?.id)
            try h.store.apply(.moveTo(message, try folder(h, "Keep").id))
            await server.refuse("CREATE", path: "Receipts")
            await server.refuse("MOVE", path: "Keep")
            await #expect {
                try await syncer.runActions()
            } throws: { error in
                (error as? SyncError).map { if case .folderChangeRefused = $0 { false } else { true } } ?? false
            }
            #expect(try h.store.folderRefusals()[h.account.id]?.name == "Receipts")
        }
    }

    @Test func aPartlyDoneDeleteRestoresOnlyWhatIsLeft() async throws {
        let server = await standardServer()
        await server.addFolder("Old", specialUse: nil)
        await server.addFolder("Old/Deep", specialUse: nil)
        try await withHarness(server) { h in
            let syncer = try await synced(h)
            let (old, deep) = (try folder(h, "Old"), try folder(h, "Old/Deep"))
            try h.store.deleteFolder(old.id)
            await server.refuse("DELETE", path: "Old")
            await #expect(throws: SyncError.self) { try await syncer.runActions() }
            #expect(try path(h, old.id) == "Old")
            #expect(try path(h, deep.id) == nil)
        }
    }

    @Test func aGivenUpDeleteKeepsTheFavouriteAndNumber() async throws {
        let server = await standardServer()
        await server.addFolder("Old", specialUse: nil)
        try await withHarness(server) { h in
            let (syncer, tick) = tickingSyncer(h)
            try await syncer.syncFolders()
            let old = try folder(h, "Old")
            try h.store.setFavorite(old.id, true)
            try h.store.deleteFolder(old.id)
            await server.refuse("DELETE", path: "Old", code: "UNAVAILABLE", times: ActionRunner.maxAttempts)
            for _ in 0..<ActionRunner.maxAttempts {
                tick()
                try? await syncer.runActions()
            }
            let back = try #require(try h.store.folders(h.account.id).first { $0.id == old.id })
            #expect(back.isFavorite)
            #expect(back.uidValidity == old.uidValidity)
        }
    }

    @Test func aRenameWithoutUnselectGoesThrough() async throws {
        let server = await standardServer()
        await server.addFolder("Old", specialUse: nil)
        await server.withholdUnselect()
        await server.refuseFoldersInUse()
        try await withHarness(server) { h in
            let syncer = try await synced(h)
            let old = try folder(h, "Old")
            try await syncer.sync(old.id)
            try h.store.renameFolder(old.id, to: "New", wire: "New", under: nil, prefix: "")
            await server.refuse("SELECT", path: "INBOX")
            await #expect(throws: SyncError.self) { try await syncer.runActions() }
            #expect(try h.store.isFolderChangeWaiting(h.account.id))
            try await syncer.runActions()
            #expect(await server.folderPaths().contains("New"))
        }
    }

    @Test func aFolderRefusalDoesNotHideAFollowUpsError() async throws {
        try await withHarness { h in
            let syncer = try await synced(h)
            _ = try h.store.createFolder(named: "Receipts", wire: "Receipts", in: nil, account: h.account.id, prefix: "")
            let draft = try localDraft(h, uid: 0, data: try draftData())
            try h.store.apply(.send(draftID: draft))
            await h.imap.refuse("CREATE", path: "Receipts")
            await h.imap.refuseNextAppend(to: "Sent")
            await #expect {
                try await syncer.runActions()
            } throws: { error in
                (error as? SyncError).map { !$0.isFolderRefusal } ?? false
            }
        }
    }

    @Test func aChangeAfterAFailedInboxFallbackSelectsItsFolderAgain() async throws {
        let server = await standardServer()
        await server.addFolder("Old", specialUse: nil)
        await server.addFolder("A", specialUse: nil)
        await server.deliver(mail("one"), to: "A")
        await server.deliver(mail("two"), to: "A")
        await server.withholdUnselect()
        try await withHarness(server) { h in
            let syncer = try await synced(h)
            let a = try folder(h, "A")
            try await syncer.sync(a.id)
            let held = try h.store.folderIndex(a.id).sorted { $0.key < $1.key }.map(\.value)
            try h.store.apply(.setFlagged(try #require(held.first), true))
            try h.store.renameFolder(try folder(h, "Old").id, to: "New", wire: "New", under: nil, prefix: "")
            try h.store.apply(.setFlagged(try #require(held.last), true))
            await server.refuse("SELECT", path: "INBOX")
            try? await syncer.runActions()
            #expect(await server.messages(in: "A").allSatisfy { $0.flags.contains("\\Flagged") })
        }
    }

    @Test func aDeleteRefusedOnALaterRunRestoresOnlyWhatIsLeft() async throws {
        let server = await standardServer()
        await server.addFolder("Old", specialUse: nil)
        await server.addFolder("Old/Deep", specialUse: nil)
        try await withHarness(server) { h in
            let syncer = try await synced(h)
            let (old, deep) = (try folder(h, "Old"), try folder(h, "Old/Deep"))
            try h.store.deleteFolder(old.id)
            await server.refuse("DELETE", path: "Old", code: "UNAVAILABLE")
            try? await syncer.runActions()
            await server.refuse("DELETE", path: "Old")
            try? await syncer.runActions()
            #expect(try path(h, old.id) == "Old")
            #expect(try path(h, deep.id) == nil)
        }
    }

    @Test func theInboxFallbackLetsARenameOfAFolderInUseThrough() async throws {
        let server = await standardServer()
        await server.addFolder("Old", specialUse: nil)
        await server.withholdUnselect()
        await server.refuseFoldersInUse()
        try await withHarness(server) { h in
            let syncer = try await synced(h)
            let old = try folder(h, "Old")
            try await syncer.sync(old.id)
            try h.store.renameFolder(old.id, to: "New", wire: "New", under: nil, prefix: "")
            try await syncer.runActions()
            #expect(await server.folderPaths().contains("New"))
        }
    }

    @Test func aMoveOutOfARenumberedFolderUnderDeleteFindsItsMessage() async throws {
        let server = await standardServer()
        await server.addFolder("Old", specialUse: nil)
        await server.deliver(mail("gone elsewhere", id: "gone@example.org"), to: "Old")
        await server.deliver(mail("keep me", id: "keep@example.org"), to: "Old")
        try await withHarness(server) { h in
            let syncer = try await synced(h)
            let old = try folder(h, "Old")
            try await syncer.sync(old.id)
            let keep = try #require(try h.store.folderIndex(old.id).sorted { $0.key < $1.key }.last?.value)
            try h.store.apply(.moveTo(keep, try h.folder(.inbox).id))
            try h.store.deleteFolder(old.id)
            // Another client removes the first message and the server numbers the folder anew.
            let side = try await h.sideClient()
            _ = try await side.select("Old")
            try await side.setFlags(["\\Deleted"], on: [1], add: true)
            try await side.expunge([1])
            await side.logout()
            await server.renumber("Old", uidValidity: 99)
            try await syncer.runActions()
            #expect(await subjects(server, "INBOX") == ["keep me"])
        }
    }

    @Test func aMoveOutGivenUpKeepsTheFolderItCameFrom() async throws {
        let server = await standardServer()
        await server.addFolder("Old", specialUse: nil)
        await server.deliver(mail("gone elsewhere"), to: "Old")
        await server.deliver(mail("keep me"), to: "Old")
        try await withHarness(server) { h in
            let (syncer, tick) = tickingSyncer(h)
            try await syncer.syncFolders()
            let old = try folder(h, "Old")
            try await syncer.sync(old.id)
            let keep = try #require(try h.store.folderIndex(old.id).sorted { $0.key < $1.key }.last?.value)
            try h.store.apply(.moveTo(keep, try h.folder(.inbox).id))
            try h.store.deleteFolder(old.id)
            // Without a Message-ID the message can't be found once the folder is numbered anew.
            let side = try await h.sideClient()
            _ = try await side.select("Old")
            try await side.setFlags(["\\Deleted"], on: [1], add: true)
            try await side.expunge([1])
            await side.logout()
            await server.renumber("Old", uidValidity: 99)
            for _ in 0..<ActionRunner.maxAttempts {
                tick()
                try? await syncer.runActions()
            }
            #expect(await subjects(server, "Old") == ["keep me"])
            #expect(try path(h, old.id) == "Old")
            #expect(try h.store.pendingActions().isEmpty)
        }
    }

    @Test func aMoveOutGivenUpKeepsTheFolderEvenWhenTheRunIsCutShort() async throws {
        let server = await standardServer()
        await server.addFolder("Old", specialUse: nil)
        await server.deliver(mail("gone elsewhere"), to: "Old")
        await server.deliver(mail("keep me"), to: "Old")
        await server.deliver(mail("read me"), to: "INBOX")
        try await withHarness(server) { h in
            let (syncer, tick) = tickingSyncer(h)
            try await syncer.syncFolders()
            try await syncer.sync(try h.folder(.inbox).id)
            let old = try folder(h, "Old")
            try await syncer.sync(old.id)
            let keep = try #require(try h.store.folderIndex(old.id).sorted { $0.key < $1.key }.last?.value)
            try h.store.apply(.moveTo(keep, try h.folder(.inbox).id))
            try h.store.apply(.setRead(try #require(try h.rows(.inbox).first?.id), true))
            try h.store.deleteFolder(old.id)
            let side = try await h.sideClient()
            _ = try await side.select("Old")
            try await side.setFlags(["\\Deleted"], on: [1], add: true)
            try await side.expunge([1])
            await side.logout()
            await server.renumber("Old", uidValidity: 99)
            await server.refuseStores()
            for run in 1...ActionRunner.maxAttempts + 1 {
                tick()
                if run == ActionRunner.maxAttempts {
                    // The run that gives the move up is cut short before it reaches the delete.
                    await syncer.disconnect()
                    await server.dropNextConnection(afterCommands: 3)
                }
                try? await syncer.runActions()
            }
            #expect(await subjects(server, "Old") == ["keep me"])
        }
    }

    @Test func aMessageMovedInAndOutWithoutUIDPlusIsNotDeletedWithTheFolder() async throws {
        let server = await standardServer(offersUIDPlus: false)
        await server.addFolder("Old", specialUse: nil)
        await server.deliver(mail("bounce me"), to: "INBOX")
        try await withHarness(server) { h in
            let (syncer, tick) = tickingSyncer(h)
            try await syncer.syncFolders()
            try await syncer.sync(try h.folder(.inbox).id)
            let message = try #require(try h.rows(.inbox).first?.id)
            let old = try folder(h, "Old")
            try h.store.apply(.moveTo(message, old.id))
            try h.store.apply(.moveTo(message, try h.folder(.inbox).id))
            try h.store.deleteFolder(old.id)
            for _ in 0...ActionRunner.maxAttempts {
                tick()
                try? await syncer.runActions()
            }
            let kept = await subjects(server, "INBOX") + subjects(server, "Old")
            #expect(kept == ["bounce me"])
        }
    }

    @Test func aMoveThenDeleteCutShortKeepsTheNewNumber() async throws {
        let server = await standardServer()
        await server.addFolder("Old", specialUse: nil)
        await server.deliver(mail("trash me"), to: "INBOX")
        try await withHarness(server) { h in
            let syncer = try await synced(h)
            let message = try #require(try h.rows(.inbox).first?.id)
            try h.store.apply(.moveTo(message, try folder(h, "Old").id))
            try h.store.apply(.delete(message))
            // The run is cut short after the move went through, before the delete; the message has
            // no Message-ID, so only the number the move gave it finds it again.
            await syncer.disconnect()
            await server.dropNextConnection(afterCommands: 7)
            try? await syncer.runActions()
            try? await syncer.runActions()
            #expect(await subjects(server, "Trash") == ["trash me"])
        }
    }

    @Test func aDraftDeletedWhileItsSendWaitsKeepsTheSentCopy() async throws {
        try await withHarness { h in
            let syncer = try await synced(h)
            let draft = try localDraft(h, uid: 0, data: try draftData())
            try h.store.apply(.saveDraft(draft))
            try h.store.apply(.send(draftID: draft))
            try h.store.apply(.delete(draft))
            try await syncer.runActions()
            try? await syncer.runActions()
            #expect(await h.smtp.received.count == 1)
            #expect(await h.imap.messages(in: "Sent").count == 1)
        }
    }

    @Test func aDeletedDraftNeverSavedStaysInTrash() async throws {
        try await withHarness { h in
            let syncer = try await synced(h)
            let draft = try localDraft(h, uid: 0, data: try draftData())
            try h.store.apply(.saveDraft(draft))
            try h.store.apply(.delete(draft))
            try? await syncer.runActions()
            #expect(try h.store.message(draft)?.folderID == h.folder(.trash).id)
        }
    }

    @Test func aMessageBackInAFolderIsDeletedFromWhereItIsNow() async throws {
        let server = await standardServer()
        await server.addFolder("Old", specialUse: nil)
        await server.addFolder("Keep", specialUse: nil)
        await server.deliver(mail("round trip", id: "trip@example.org"), to: "INBOX")
        try await withHarness(server) { h in
            let syncer = try await synced(h)
            let message = try #require(try h.rows(.inbox).first?.id)
            let (old, keep) = (try folder(h, "Old"), try folder(h, "Keep"))
            try h.store.apply(.moveTo(message, old.id))
            try h.store.apply(.moveTo(message, keep.id))
            try h.store.apply(.moveTo(message, old.id))
            try h.store.apply(.delete(message))
            await server.refuse("MOVE", path: "Keep", code: "UNAVAILABLE")
            try? await syncer.runActions()
            await server.refuse("MOVE", path: "Trash", code: "UNAVAILABLE")
            try? await syncer.runActions()
            try? await syncer.runActions()
            #expect(await subjects(server, "Trash") == ["round trip"])
        }
    }

    @Test func aMessageMovedBackIntoAFolderIsDeletedFromItsNewPlace() async throws {
        let server = await standardServer()
        await server.addFolder("Old", specialUse: nil)
        await server.addFolder("Keep", specialUse: nil)
        await server.deliver(mail("there and back", id: "back@example.org"), to: "INBOX")
        try await withHarness(server) { h in
            let syncer = try await synced(h)
            let message = try #require(try h.rows(.inbox).first?.id)
            let (old, keep) = (try folder(h, "Old"), try folder(h, "Keep"))
            try h.store.apply(.moveTo(message, old.id))
            try h.store.apply(.moveTo(message, keep.id))
            try h.store.apply(.moveTo(message, old.id))
            try await syncer.runActions()
            try h.store.apply(.delete(message))
            try await syncer.runActions()
            #expect(await subjects(server, "Trash") == ["there and back"])
            #expect(await server.messages(in: "Old").isEmpty)
        }
    }

    @Test func aRenameOfAFolderLeftSelectedByASyncGoesThrough() async throws {
        let server = await standardServer()
        await server.addFolder("Old", specialUse: nil)
        await server.deliver(mail("in it"), to: "Old")
        await server.refuseFoldersInUse()
        try await withHarness(server) { h in
            let syncer = try await synced(h)
            let old = try folder(h, "Old")
            try await syncer.sync(old.id)
            try h.store.renameFolder(old.id, to: "New", wire: "New", under: nil, prefix: "")
            try await syncer.runActions()
            #expect(await server.folderPaths().contains("New"))
        }
    }

    @Test func aRenameOfTheSelectedFolderLeavesItFirst() async throws {
        let server = await standardServer()
        await server.addFolder("Old", specialUse: nil)
        await server.deliver(mail("flag me"), to: "Old")
        await server.refuseFoldersInUse()
        try await withHarness(server) { h in
            let syncer = try await synced(h)
            let old = try folder(h, "Old")
            try await syncer.sync(old.id)
            let message = try #require(try h.store.folderIndex(old.id).values.first)
            try h.store.apply(.setFlagged(message, true))
            try h.store.renameFolder(old.id, to: "New", wire: "New", under: nil, prefix: "")
            try await syncer.runActions()
            #expect(await server.folderPaths().contains("New"))
            #expect(await server.messages(in: "New").first?.flags.contains("\\Flagged") == true)
        }
    }

    @Test func anUnavailableServerLeavesTheRestQueued() async throws {
        let server = await standardServer()
        await server.addFolder("Projects", specialUse: nil)
        await server.deliver(mail("later"), to: "INBOX")
        try await withHarness(server) { h in
            let syncer = try await synced(h)
            let projects = try folder(h, "Projects")
            try h.store.renameFolder(projects.id, to: "Work", wire: "Work", under: nil, prefix: "")
            let message = try #require(try h.rows(.inbox).first?.id)
            try h.store.apply(.moveTo(message, projects.id))
            await server.refuse("RENAME", path: "Projects", code: "UNAVAILABLE")
            await #expect(throws: SyncError.self) { try await syncer.runActions() }
            #expect(try h.store.pendingActions().count == 2)
            #expect(try path(h, projects.id) == "Work")

            try await syncer.runActions()
            #expect(await subjects(server, "Work") == ["later"])
            #expect(try h.store.pendingActions().isEmpty)
        }
    }
}

@Suite struct FolderCountTests {
    @Test func serverMessageCountSumsTheSubtree() async throws {
        let server = await standardServer()
        await server.addFolder("Old", specialUse: nil)
        await server.addFolder("Old/Deep", specialUse: nil)
        for subject in ["a", "b"] { await server.deliver(mail(subject), to: "Old") }
        for subject in ["c", "d", "e"] { await server.deliver(mail(subject), to: "Old/Deep") }
        await server.deliver(mail("not counted"), to: "INBOX")
        try await withHarness(server) { h in
            let coordinator = offlineCoordinator(store: h.store, secrets: h.secrets)
            await coordinator.refreshAll()
            let old = try #require(try h.store.folders(h.account.id).first { $0.path == "Old" })
            #expect(await coordinator.serverMessageCount(inTreeOf: old.id) == 5)
        }
    }

    @Test func serverMessageCountIsNilOffline() async throws {
        let server = await standardServer()
        await server.addFolder("Old", specialUse: nil)
        try await withHarness(server) { h in
            let coordinator = offlineCoordinator(store: h.store, secrets: h.secrets)
            await coordinator.refreshAll()
            let old = try #require(try h.store.folders(h.account.id).first { $0.path == "Old" })
            await server.stop()
            #expect(await coordinator.serverMessageCount(inTreeOf: old.id) == nil)
        }
    }

    @Test func serverMessageCountIsNilWhenTheServerHasNoSuchFolder() async throws {
        let server = await standardServer()
        await server.addFolder("Projects", specialUse: nil)
        try await withHarness(server) { h in
            let coordinator = offlineCoordinator(store: h.store, secrets: h.secrets)
            await coordinator.refreshAll()
            let projects = try #require(try h.store.folders(h.account.id).first { $0.path == "Projects" })
            try h.store.renameFolder(projects.id, to: "Work", wire: "Work", under: nil, prefix: "")
            #expect(await coordinator.serverMessageCount(inTreeOf: projects.id) == nil)
        }
    }

    @Test func folderPrefixBeforeAnySyncComesFromTheStoredFolders() async throws {
        let server = FakeIMAPServer()
        await server.keepFoldersUnderInbox()
        await server.addFolder("INBOX.Sent", specialUse: "\\Sent")
        try await withHarness(server) { h in
            let first = offlineCoordinator(store: h.store, secrets: h.secrets)
            await first.refreshAll()
            await server.stop()
            let later = offlineCoordinator(store: h.store, secrets: h.secrets)
            #expect(await later.folderPrefix(for: h.account.id) == "INBOX.")
        }
    }

    @Test func aRefusedFolderChangeStaysToldUntilDismissed() async throws {
        let server = await standardServer()
        await server.refuse("CREATE", path: "Receipts")
        try await withHarness(server) { h in
            let coordinator = offlineCoordinator(store: h.store, secrets: h.secrets, actionDelay: .milliseconds(50))
            await coordinator.refreshAll()
            _ = try h.store.createFolder(named: "Receipts", wire: "Receipts", in: nil, account: h.account.id, prefix: "")
            let told = FolderRefusal(name: "Receipts", gaveUp: false)
            #expect(try await eventually { try h.store.folderRefusals()[h.account.id] == told })
            await coordinator.refreshAll()
            #expect(try h.store.folderRefusals()[h.account.id] == told)
            #expect(await coordinator.lastErrors[h.account.id] == nil)
            try h.store.dismissFolderRefusal(h.account.id, name: "Receipts")
            #expect(try h.store.folderRefusals()[h.account.id] == nil)
        }
    }

    @Test func folderPrefixIsRememberedAcrossLaunches() async throws {
        let server = FakeIMAPServer()
        await server.keepFoldersUnderInbox()
        try await withHarness(server) { h in
            let first = offlineCoordinator(store: h.store, secrets: h.secrets)
            await first.refreshAll()
            await server.stop()
            let later = offlineCoordinator(store: h.store, secrets: h.secrets)
            #expect(await later.folderPrefix(for: h.account.id) == "INBOX.")
        }
    }

    @Test func folderPrefixIsINBOXDotOnAnUnderInboxServer() async throws {
        let server = FakeIMAPServer()
        await server.keepFoldersUnderInbox()
        try await withHarness(server) { h in
            let coordinator = offlineCoordinator(store: h.store, secrets: h.secrets)
            #expect(await coordinator.folderPrefix(for: h.account.id) == "")
            await coordinator.refreshAll()
            #expect(await coordinator.folderPrefix(for: h.account.id) == "INBOX.")
        }
    }
}
