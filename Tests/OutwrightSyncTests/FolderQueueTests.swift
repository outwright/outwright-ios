// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightFakes
import OutwrightModel
import OutwrightStore
import Testing

@testable import OutwrightSync

private let account = AccountID()

private func folder(_ id: Int64, _ path: String, name: String? = nil, validity: UInt32 = 1) -> Folder {
    Folder(
        id: FolderID(raw: id), accountID: account, path: path, name: name ?? path, kind: .other,
        uidValidity: validity, unread: 0, isFavorite: false, delimiter: "/")
}

@Suite struct FolderQueueTests {
    @Test func aQueuedRenameKeepsTheNewPaths() {
        let listed = [folder(0, "INBOX"), folder(0, "Projects"), folder(0, "Projects/2026"), folder(0, "ProjectsOld")]
        let known = [folder(7, "Work", validity: 5), folder(8, "Work/2026", name: "2026", validity: 6)]
        let projected = FolderQueue.project(
            listed, known: known, queued: [.renameFolder(FolderID(raw: 7), from: "Projects", to: "Work")])
        #expect(projected.map(\.path) == ["INBOX", "Work", "Work/2026", "ProjectsOld"])
        #expect(projected.first { $0.path == "Work" }?.uidValidity == 5)
        #expect(projected.first { $0.path == "Work/2026" }?.uidValidity == 6)
        #expect(projected.first { $0.path == "Work" }?.name == "Work")
    }

    @Test func aQueuedDeleteHidesTheSubtree() {
        let listed = [folder(0, "INBOX"), folder(0, "Old"), folder(0, "Old/Deep"), folder(0, "Older")]
        let projected = FolderQueue.project(
            listed, known: [],
            queued: [.deleteFolder(FolderID(raw: 3), paths: [FolderPath(id: FolderID(raw: 3), path: "Old")])])
        #expect(projected.map(\.path) == ["INBOX", "Older"])
    }

    @Test func aQueuedCreateIsKeptWhenUnlisted() {
        let made = folder(9, "Receipts", validity: 0)
        let projected = FolderQueue.project([folder(0, "INBOX")], known: [made], queued: [.createFolder(made.id)])
        #expect(projected.map(\.path) == ["INBOX", "Receipts"])
        let listed = FolderQueue.project(
            [folder(0, "INBOX"), folder(0, "Receipts")], known: [made], queued: [.createFolder(made.id)])
        #expect(listed.map(\.path) == ["INBOX", "Receipts"])
    }

    @Test func aFolderWaitsWhileItsCreateOrARenameAboveItIsQueued() {
        let queued: [MailAction] = [
            .createFolder(FolderID(raw: 9)), .renameFolder(FolderID(raw: 7), from: "Projects", to: "Work")
        ]
        #expect(FolderQueue.waits(folder(9, "Receipts", validity: 0), queued: queued))
        #expect(FolderQueue.waits(folder(8, "Work/2026"), queued: queued))
        #expect(!FolderQueue.waits(folder(4, "Workshop"), queued: queued))
    }

    @Test func aQueuedRenameOfAParentSurvivesAFolderSync() async throws {
        let server = await standardServer()
        await server.addFolder("Projects", specialUse: nil)
        await server.addFolder("Projects/2026", specialUse: nil)
        await server.deliver(mail("plans"), to: "Projects/2026")
        try await withHarness(server) { h in
            let syncer = try await synced(h)
            let all = try h.store.folders(h.account.id)
            let parent = try #require(all.first { $0.path == "Projects" })
            let child = try #require(all.first { $0.path == "Projects/2026" })
            try await syncer.sync(child.id)
            let held = try h.store.folderIndex(child.id).count
            #expect(held == 1)

            try h.store.renameFolder(parent.id, to: "Work", wire: "Work", under: nil, prefix: "")
            try await syncer.syncFolders()
            try await syncer.sync(child.id)

            let after = try h.store.folders(h.account.id)
            #expect(after.first { $0.id == parent.id }?.path == "Work")
            #expect(after.first { $0.id == child.id }?.path == "Work/2026")
            #expect(!after.contains { $0.path == "Projects" || $0.path == "Projects/2026" })
            #expect(try h.store.folderIndex(child.id).count == 1)
        }
    }
}
