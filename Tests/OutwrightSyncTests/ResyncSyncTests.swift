// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightFakes
import OutwrightIMAP
import OutwrightModel
import OutwrightStore
import OutwrightSync
import Testing

/// What a fake offers of RFC 7162.
enum ResyncOffer: CaseIterable, Sendable {
    case qresync, condstoreOnly, none
}

/// The usual fake, offering `offer`.
func standardServer(_ offer: ResyncOffer) async -> FakeIMAPServer {
    let server = await standardServer()
    switch offer {
    case .qresync: break
    case .condstoreOnly: await server.offerCondstoreOnly()
    case .none: await server.offerNoCondstore()
    }
    return server
}

/// Folder syncs by mod-sequence (CONDSTORE, QRESYNC) and their fallbacks.
@Suite struct ResyncSyncTests {
    @Test(arguments: [ResyncOffer.qresync, .condstoreOnly])
    func anUnchangedFolderMakesNoFlagFetch(offer: ResyncOffer) async throws {
        let server = await standardServer(offer)
        await server.deliver(mail("a"), to: "INBOX")
        await server.deliver(mail("b"), to: "INBOX")
        try await withHarness(server) { h in
            let syncer = h.syncer()
            try await syncer.syncFolders()
            let inbox = try h.folder(.inbox)
            try await syncer.sync(inbox.id)
            await server.forgetServedCommands()
            try await syncer.sync(inbox.id)
            let served = await server.servedCommands
            #expect(!served.isEmpty)
            #expect(!served.contains { $0.contains("FLAGS") })
            #expect(try h.rows(.inbox).count == 2)
        }
    }

    @Test func aRenumberedFolderStillStartsOver() async throws {
        let server = await standardServer()
        await server.deliver(mail("a"), to: "INBOX")
        try await withHarness(server) { h in
            let syncer = h.syncer()
            try await syncer.syncFolders()
            let inbox = try h.folder(.inbox)
            try await syncer.sync(inbox.id)
            await server.renumber("INBOX", uidValidity: 4242)
            await server.deliver(mail("b"), to: "INBOX")
            try await syncer.sync(inbox.id)
            #expect(Set(try h.rows(.inbox).map(\.subject)) == ["a", "b"])
            #expect(try h.folder(.inbox).uidValidity == 4242)
            #expect(try h.store.highestModSeq(inbox.id) == (await server.highestModSeq("INBOX")))
        }
    }

    @Test func aFailedReconcileForgetsTheModSeq() async throws {
        let server = await standardServer(.condstoreOnly)
        let uid = await server.deliver(mail("a"), to: "INBOX")
        try await withHarness(server) { h in
            let syncer = h.syncer()
            try await syncer.syncFolders()
            let inbox = try h.folder(.inbox)
            try await syncer.sync(inbox.id)
            #expect(try h.store.highestModSeq(inbox.id) != nil)

            let side = try await h.sideClient()
            _ = try await side.select("INBOX")
            try await side.setFlags(["\\Seen"], on: [uid], add: true)
            await side.logout()

            // LOGIN, ENABLE and SELECT are answered; the reconcile's first command finds the
            // connection gone.
            await syncer.disconnect()
            await server.dropNextConnection(afterCommands: 3)
            await #expect(throws: SyncError.self) { try await syncer.sync(inbox.id) }
            #expect(try h.store.highestModSeq(inbox.id) == nil)

            try await syncer.sync(inbox.id)
            #expect(try h.rows(.inbox).first?.isRead == true)
        }
    }

    @Test func aModSeqThatWentBackRunsTheFullReconcile() async throws {
        let server = await standardServer()
        let uid = await server.deliver(mail("a"), to: "INBOX")
        for subject in ["b", "c", "d"] {
            await server.deliver(mail(subject), to: "INBOX")
        }
        try await withHarness(server) { h in
            let syncer = h.syncer()
            try await syncer.syncFolders()
            let inbox = try h.folder(.inbox)
            try await syncer.sync(inbox.id)

            let side = try await h.sideClient()
            _ = try await side.select("INBOX")
            try await side.setFlags(["\\Seen"], on: [uid], add: true)
            await side.logout()
            await server.rewindModSeq("INBOX")

            try await syncer.sync(inbox.id)
            #expect(try h.rows(.inbox).first?.isRead == true)
        }
    }

    @Test func aFolderWithoutModSeqKeepsTheFullReconcile() async throws {
        let server = await standardServer()
        await server.withholdModSeq("INBOX")
        let uid = await server.deliver(mail("a"), to: "INBOX")
        try await withHarness(server) { h in
            let syncer = h.syncer()
            try await syncer.syncFolders()
            let inbox = try h.folder(.inbox)
            try await syncer.sync(inbox.id)
            #expect(try h.store.highestModSeq(inbox.id) == nil)

            let side = try await h.sideClient()
            _ = try await side.select("INBOX")
            try await side.setFlags(["\\Flagged"], on: [uid], add: true)
            await side.logout()

            try await syncer.sync(inbox.id)
            #expect(try h.rows(.inbox).first?.isFlagged == true)
            #expect(try h.store.highestModSeq(inbox.id) == nil)
        }
    }

    @Test func anEmptyFolderStillRemembersItsModSeq() async throws {
        let server = await standardServer()
        try await withHarness(server) { h in
            let syncer = h.syncer()
            try await syncer.syncFolders()
            let trash = try h.folder(.trash)
            try await syncer.sync(trash.id)
            #expect(try h.store.highestModSeq(trash.id) != nil)

            await server.deliver(mail("thrown away"), to: "Trash")
            try await syncer.sync(trash.id)
            #expect(try h.rows(.trash).map(\.subject) == ["thrown away"])
        }
    }

    @Test func idleInboxSeesARemovalUnderQResync() async throws {
        let server = await standardServer()
        let uid = await server.deliver(mail("a"), to: "INBOX")
        try await withHarness(server) { h in
            let syncer = h.syncer()
            try await syncer.syncFolders()
            try await syncer.sync(try h.folder(.inbox).id)
            let removal = Task {
                await server.waitUntilIdling()
                let side = try await h.sideClient()
                _ = try await side.select("INBOX")
                try await side.setFlags(["\\Deleted"], on: [uid], add: true)
                try await side.expunge([uid])
                await side.logout()
            }
            #expect(try await syncer.idleInbox() == true)
            try await removal.value
        }
    }

    @Test func aRefusedFlagChangeGoesBackToTheServersState() async throws {
        let server = await standardServer()
        await server.deliver(mail("a"), to: "INBOX")
        try await withHarness(server) { h in
            let syncer = h.syncer()
            try await syncer.syncFolders()
            let inbox = try h.folder(.inbox)
            try await syncer.sync(inbox.id)
            let id = try #require(try h.rows(.inbox).first?.id)

            await server.refuseStores()
            try h.store.apply(.setRead(id, true))
            #expect(try h.rows(.inbox).first?.isRead == true)
            await #expect(throws: SyncError.self) { try await syncer.sync(inbox.id) }
            #expect(try h.rows(.inbox).first?.isRead == false)
        }
    }

    @Test func aRefusedQResyncSelectForgetsTheModSeq() async throws {
        let server = await standardServer()
        let uid = await server.deliver(mail("a"), to: "INBOX")
        try await withHarness(server) { h in
            let syncer = h.syncer()
            try await syncer.syncFolders()
            let inbox = try h.folder(.inbox)
            try await syncer.sync(inbox.id)

            let side = try await h.sideClient()
            _ = try await side.select("INBOX")
            try await side.setFlags(["\\Seen"], on: [uid], add: true)
            await side.logout()

            await server.refuseNextQResyncSelect()
            await #expect(throws: SyncError.self) { try await syncer.sync(inbox.id) }
            #expect(try h.store.highestModSeq(inbox.id) == nil)
            try await syncer.sync(inbox.id)
            #expect(try h.rows(.inbox).first?.isRead == true)
        }
    }

    @Test func anEmptyFolderIsSelectedWithoutAQResyncPoint() async throws {
        let server = await standardServer()
        try await withHarness(server) { h in
            let syncer = h.syncer()
            try await syncer.syncFolders()
            let trash = try h.folder(.trash)
            try await syncer.sync(trash.id)
            await server.forgetServedCommands()
            try await syncer.sync(trash.id)
            let selects = await server.servedCommands.filter { $0.contains("SELECT") }
            #expect(!selects.isEmpty)
            #expect(!selects.contains { $0.contains("QRESYNC") })
        }
    }

    @Test func theQResyncSelectAsksOnlyAboutTheHeldSpan() async throws {
        let server = await standardServer()
        await server.deliver(mail("too old to hold", date: daysAgo(200)), to: "INBOX")
        await server.deliver(mail("a"), to: "INBOX")
        await server.deliver(mail("b"), to: "INBOX")
        try await withHarness(server) { h in
            let syncer = h.syncer()
            try await syncer.syncFolders()
            let inbox = try h.folder(.inbox)
            try await syncer.sync(inbox.id)
            #expect(Set(try h.store.folderIndex(inbox.id).keys) == [2, 3])
            await server.forgetServedCommands()
            try await syncer.sync(inbox.id)
            let select = await server.servedCommands.first { $0.contains("QRESYNC") }
            #expect(select?.hasSuffix(" 2:3))") == true)
        }
    }

    @Test func theCondstoreFetchAsksOnlyAboutTheHeldSpan() async throws {
        let server = await standardServer(.condstoreOnly)
        await server.deliver(mail("too old to hold", date: daysAgo(200)), to: "INBOX")
        await server.deliver(mail("a"), to: "INBOX")
        await server.deliver(mail("b"), to: "INBOX")
        try await withHarness(server) { h in
            let syncer = h.syncer()
            try await syncer.syncFolders()
            let inbox = try h.folder(.inbox)
            try await syncer.sync(inbox.id)
            let side = try await h.sideClient()
            _ = try await side.select("INBOX")
            try await side.setFlags(["\\Seen"], on: [3], add: true)
            await side.logout()
            await server.forgetServedCommands()
            try await syncer.sync(inbox.id)
            let fetch = await server.servedCommands.first { $0.contains("CHANGEDSINCE") }
            #expect(fetch?.contains("UID FETCH 2:3 ") == true)
            #expect(try h.rows(.inbox).last?.isRead == true)
        }
    }

    // Mail taken out of an ordinary folder by another client, many at once and spread over old
    // and new: the next sync of that folder (a pull on its list) leaves only what the server has.
    @Test(arguments: ResyncOffer.allCases)
    func manyRemovedElsewhereLeaveAnOrdinaryFolder(offer: ResyncOffer) async throws {
        let server = await standardServer(offer)
        await server.addFolder("Support", specialUse: nil)
        var uids: [UInt32] = []
        for day in 0..<30 {
            uids.append(await server.deliver(mail("case \(day)", date: daysAgo(Double(day * 10 + 1))), to: "Support"))
        }
        try await withHarness(server) { h in
            let syncer = h.syncer()
            try await syncer.syncFolders()
            let support = try #require(try h.store.folders(h.account.id).first { $0.path == "Support" })
            try await syncer.sync(support.id)
            while try await syncer.fetchOlder(support.id, atLeast: 50) {}
            #expect(try h.store.folderIndex(support.id).count == 30)

            let gone = uids.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
            let side = try await h.sideClient()
            _ = try await side.select("Support")
            _ = try await side.move(Array(gone.prefix(8)), to: "Trash")
            try await side.setFlags(["\\Deleted"], on: Array(gone.dropFirst(8)), add: true)
            try await side.expunge(Array(gone.dropFirst(8)))
            await side.logout()

            try await syncer.sync(support.id)
            #expect(Set(try h.store.folderIndex(support.id).keys) == Set(uids).subtracting(gone))
        }
    }

    /// Against a server that says what changed before `[CLOSED]` (Stalwart v0.16), a message
    /// moved away elsewhere leaves the folder and one read elsewhere is read here, with
    /// UNSELECT offered or not.
    @Test(arguments: [true, false])
    func changesSaidBeforeClosedReachTheFolder(unselect: Bool) async throws {
        let server = await standardServer()
        await server.answerResyncBeforeClosed()
        if !unselect {
            await server.withholdUnselect()
        }
        await server.addFolder("Support", specialUse: nil)
        var uids: [UInt32] = []
        for number in 0..<4 {
            uids.append(await server.deliver(mail("case \(number)"), to: "Support"))
        }
        try await withHarness(server) { h in
            let syncer = h.syncer()
            try await syncer.syncFolders()
            let support = try #require(try h.store.folders(h.account.id).first { $0.path == "Support" })
            try await syncer.sync(support.id)

            let side = try await h.sideClient()
            _ = try await side.select("Support")
            _ = try await side.move([uids[0]], to: "Trash")
            try await side.setFlags(["\\Seen"], on: [uids[1]], add: true)
            await side.logout()

            try await syncer.sync(support.id)
            let held = try h.store.folderIndex(support.id)
            #expect(Set(held.keys) == Set(uids.dropFirst()))
            let read = try #require(try held[uids[1]].flatMap { try h.store.message($0) })
            #expect(read.isRead)
        }
    }
}

