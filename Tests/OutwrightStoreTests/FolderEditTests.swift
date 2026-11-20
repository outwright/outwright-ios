// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import GRDB
import OutwrightModel
import Testing

@testable import OutwrightStore

@Suite struct FolderEditTests {
    private func folder(_ f: Fixture, _ path: String) throws -> Folder? {
        try f.store.folders(f.account.id).first { $0.path == path }
    }

    /// `Projects` (a favourite, holding a message) with `Projects/2026` under it, both on the server.
    private func projects(_ f: Fixture) throws -> (parent: Folder, child: Folder, message: MessageID) {
        var all = try f.store.folders(f.account.id)
        all.append(Folder(
            id: FolderID(raw: 0), accountID: f.account.id, path: "Projects", name: "Projects", kind: .other,
            uidValidity: 5, unread: 0, isFavorite: true, delimiter: "/"))
        all.append(Folder(
            id: FolderID(raw: 0), accountID: f.account.id, path: "Projects/2026", name: "2026", kind: .other,
            uidValidity: 6, unread: 0, isFavorite: false, delimiter: "/"))
        try f.store.replaceFolders(all, for: f.account.id)
        let parent = try #require(try folder(f, "Projects"))
        let child = try #require(try folder(f, "Projects/2026"))
        let message = try #require(try f.store.upsert([row(f.account.id, child.id, uid: 4)]).first)
        return (parent, child, message)
    }

    @Test func createAddsAFolderAndQueuesIt() throws {
        let f = try Fixture()
        let id = try f.store.createFolder(named: "Receipts", wire: "Receipts", in: nil, account: f.account.id, prefix: "")
        let made = try #require(try f.store.folders(f.account.id).first { $0.id == id })
        #expect(made.path == "Receipts")
        #expect(made.name == "Receipts")
        #expect(made.kind == .other)
        #expect(made.uidValidity == 0)
        #expect(try f.store.pendingActions().last?.action == .createFolder(id))
    }

    @Test func createGoesUnderItsParentAndThePrefix() throws {
        let f = try Fixture()
        let (parent, _, _) = try projects(f)
        let child = try f.store.createFolder(named: "Q1", wire: "Q1", in: parent.id, account: f.account.id, prefix: "")
        #expect(try f.store.folders(f.account.id).first { $0.id == child }?.path == "Projects/Q1")
        // The server took it: the next folder change may go.
        try f.store.completeAction(try #require(try f.store.pendingActions().last?.id))
        let top = try f.store.createFolder(named: "Top", wire: "Top", in: nil, account: f.account.id, prefix: "INBOX.")
        #expect(try f.store.folders(f.account.id).first { $0.id == top }?.path == "INBOX.Top")
    }

    @Test func createRefusesADuplicateSibling() throws {
        let f = try Fixture()
        _ = try projects(f)
        #expect(throws: StoreError.folderNameTaken) {
            try f.store.createFolder(named: "Projects", wire: "Projects", in: nil, account: f.account.id, prefix: "")
        }
    }

    @Test func createRefusesTheDelimiterAndEmpty() throws {
        let f = try Fixture()
        _ = try projects(f)
        #expect(throws: StoreError.folderNameInvalid) {
            try f.store.createFolder(named: "a/b", wire: "a/b", in: nil, account: f.account.id, prefix: "")
        }
        #expect(throws: StoreError.folderNameInvalid) {
            try f.store.createFolder(named: "  ", wire: "  ", in: nil, account: f.account.id, prefix: "")
        }
        #expect(try f.store.pendingActions().isEmpty)
    }

    @Test func renameCarriesSubfoldersMessagesAndFavourite() throws {
        let f = try Fixture()
        let (parent, child, message) = try projects(f)
        try f.store.renameFolder(parent.id, to: "Work", wire: "Work", under: nil, prefix: "")
        let renamed = try #require(try f.store.folders(f.account.id).first { $0.id == parent.id })
        #expect(renamed.path == "Work")
        #expect(renamed.name == "Work")
        #expect(renamed.isFavorite)
        #expect(try f.store.folders(f.account.id).first { $0.id == child.id }?.path == "Work/2026")
        #expect(try f.store.message(message)?.folderID == child.id)
        #expect(try f.store.pendingActions().last?.action == .renameFolder(parent.id, from: "Projects", to: "Work"))
    }

    @Test func moveIsARenameUnderANewParent() throws {
        let f = try Fixture()
        let (parent, _, _) = try projects(f)
        let archive = try #require(try f.store.folders(f.account.id).first { $0.kind == .archive })
        try f.store.renameFolder(parent.id, to: "Projects", wire: "Projects", under: archive.id, prefix: "")
        #expect(try f.store.folders(f.account.id).first { $0.id == parent.id }?.path == "Archive/Projects")
    }

    @Test func aFolderCannotMoveUnderItself() throws {
        let f = try Fixture()
        let (parent, child, _) = try projects(f)
        #expect(throws: StoreError.folderNameInvalid) {
            try f.store.renameFolder(parent.id, to: "Projects", wire: "Projects", under: child.id, prefix: "")
        }
    }

    @Test func specialFoldersOnlyTakeSubfolders() throws {
        let f = try Fixture()
        #expect(throws: StoreError.folderProtected) {
            try f.store.renameFolder(f.inbox.id, to: "Post", wire: "Post", under: nil, prefix: "")
        }
        #expect(throws: StoreError.folderProtected) { try f.store.deleteFolder(f.sent.id) }
        _ = try f.store.createFolder(named: "Kept", wire: "Kept", in: f.inbox.id, account: f.account.id, prefix: "")
    }

    @Test func deleteRemovesTheSubtreeAndItsMessages() throws {
        let f = try Fixture()
        let (parent, child, message) = try projects(f)
        try f.store.apply(.setFlagged(message, true))
        try f.store.deleteFolder(parent.id)
        let left = try f.store.folders(f.account.id).map(\.id)
        #expect(!left.contains(parent.id))
        #expect(!left.contains(child.id))
        #expect(try f.store.message(message) == nil)
        let queued = try f.store.pendingActions().map(\.action)
        #expect(queued == [.deleteFolder(parent.id, paths: [
            FolderPath(id: parent.id, path: "Projects", isFavorite: true, uidValidity: 5),
            FolderPath(id: child.id, path: "Projects/2026", isFavorite: false, uidValidity: 6)
        ])])
    }

    @Test func aMoveOutOfAFolderOutlivesItsDelete() throws {
        let f = try Fixture()
        let (_, child, message) = try projects(f)
        try f.store.apply(.moveTo(message, f.inbox.id))
        try f.store.deleteFolder(child.id)
        #expect(try f.store.message(message)?.folderID == f.inbox.id)
        #expect(try f.store.pendingActions().first?.action == .moveTo(message, f.inbox.id))
    }

    @Test func undoFolderCreateSendsFiledMailBack() throws {
        let f = try Fixture()
        let message = try #require(try f.store.upsert([row(f.account.id, f.inbox.id, uid: 9)]).first)
        let made = try f.store.createFolder(named: "Receipts", wire: "Receipts", in: nil, account: f.account.id, prefix: "")
        try f.store.apply(.moveTo(message, made))
        try f.store.undoFolderCreate(made)
        let back = try #require(try f.store.message(message))
        #expect(back.folderID == f.inbox.id)
        #expect(back.uid == 9)
        #expect(try f.store.folders(f.account.id).contains { $0.id == made } == false)
        #expect(try f.store.pendingActions().map(\.action) == [.createFolder(made)])
    }

    @Test func undoFolderRenamePutsPathsBack() throws {
        let f = try Fixture()
        let (parent, child, _) = try projects(f)
        try f.store.renameFolder(parent.id, to: "Work", wire: "Work", under: nil, prefix: "")
        try f.store.undoFolderRename(parent.id, from: "Projects", to: "Work", name: "Projects")
        #expect(try f.store.folders(f.account.id).first { $0.id == parent.id }?.path == "Projects")
        #expect(try f.store.folders(f.account.id).first { $0.id == parent.id }?.name == "Projects")
        #expect(try f.store.folders(f.account.id).first { $0.id == child.id }?.path == "Projects/2026")
    }

    @Test func aWireNameWithSpaceAroundItIsRefused() throws {
        let f = try Fixture()
        #expect(throws: StoreError.folderNameInvalid) {
            try f.store.createFolder(named: "Receipts ", wire: "Receipts ", in: nil, account: f.account.id, prefix: "")
        }
    }

    @Test func aSubtreeHoldingAProtectedFolderIsNotDeletedOrMoved() throws {
        let f = try Fixture()
        var all = try f.store.folders(f.account.id)
        all.append(Folder(
            id: FolderID(raw: 0), accountID: f.account.id, path: "Stuff", name: "Stuff", kind: .other,
            uidValidity: 5, unread: 0, isFavorite: false, delimiter: "/"))
        all.append(Folder(
            id: FolderID(raw: 0), accountID: f.account.id, path: "Stuff/Sent", name: "Sent", kind: .junk,
            uidValidity: 6, unread: 0, isFavorite: false, delimiter: "/"))
        try f.store.replaceFolders(all, for: f.account.id)
        let stuff = try #require(try folder(f, "Stuff"))
        #expect(throws: StoreError.folderProtected) { try f.store.deleteFolder(stuff.id) }
        #expect(throws: StoreError.folderProtected) {
            try f.store.renameFolder(stuff.id, to: "Things", wire: "Things", under: nil, prefix: "")
        }
    }

    @Test func undoFolderCreatePointsALaterMoveAtWhereTheMessageReallyIs() throws {
        let f = try Fixture()
        let message = try #require(try f.store.upsert([row(f.account.id, f.inbox.id, uid: 9)]).first)
        let made = try f.store.createFolder(named: "New", wire: "New", in: nil, account: f.account.id, prefix: "")
        try f.store.apply(.moveTo(message, made))
        try f.store.apply(.moveTo(message, f.sent.id))
        try f.store.undoFolderCreate(made)
        let left = try f.store.pendingActions()
        #expect(left.map(\.action) == [.createFolder(made), .moveTo(message, f.sent.id)])
        #expect(left.last?.sourceFolderID == f.inbox.id)
        #expect(left.last?.sourceUID == 9)
    }

    @Test func aServerFolderWithSpaceInItsNameCanMove() throws {
        let f = try Fixture()
        var all = try f.store.folders(f.account.id)
        all.append(Folder(
            id: FolderID(raw: 0), accountID: f.account.id, path: "Foo ", name: "Foo ", kind: .other,
            uidValidity: 5, unread: 0, isFavorite: false, delimiter: "/"))
        try f.store.replaceFolders(all, for: f.account.id)
        let foo = try #require(try folder(f, "Foo "))
        let archive = try #require(try f.store.folders(f.account.id).first { $0.kind == .archive })
        try f.store.renameFolder(foo.id, to: "Foo ", wire: "Foo ", under: archive.id, prefix: "")
        #expect(try f.store.folders(f.account.id).first { $0.id == foo.id }?.path == "Archive/Foo ")
    }

    @Test func undoFolderCreateFollowsAMessageFiledInTwice() throws {
        let f = try Fixture()
        let message = try #require(try f.store.upsert([row(f.account.id, f.inbox.id, uid: 9)]).first)
        let made = try f.store.createFolder(named: "New", wire: "New", in: nil, account: f.account.id, prefix: "")
        try f.store.apply(.moveTo(message, made))
        try f.store.apply(.moveTo(message, f.sent.id))
        try f.store.apply(.moveTo(message, made))
        try f.store.undoFolderCreate(made)
        let left = try f.store.pendingActions().filter { $0.action == .moveTo(message, f.sent.id) }
        #expect(left.first?.sourceFolderID == f.inbox.id)
        #expect(try f.store.message(message)?.folderID == f.sent.id)
    }

    @Test func anAccountRemembersWhereItsTopLevelFoldersGo() throws {
        let f = try Fixture()
        #expect(try f.store.folderPrefix(f.account.id) == nil)
        try f.store.setFolderPrefix("INBOX.", for: f.account.id)
        #expect(try f.store.folderPrefix(f.account.id) == "INBOX.")
    }

    @Test func aDeleteFromARefusedFolderOfMailRescuedFromTrashIsDropped() throws {
        let f = try Fixture()
        let message = try #require(try f.store.upsert([row(f.account.id, f.trash.id, uid: 4)]).first)
        let made = try f.store.createFolder(named: "New", wire: "New", in: nil, account: f.account.id, prefix: "")
        try f.store.apply(.moveTo(message, made))
        try f.store.apply(.delete(message))
        try f.store.undoFolderCreate(made)
        #expect(try f.store.pendingActions().map(\.action) == [.createFolder(made)])
        let back = try #require(try f.store.message(message))
        #expect(back.folderID == f.trash.id)
        #expect(back.uid == 4)
    }

    @Test func aDeleteForGoodAfterARescueFindsTheMessageInTrash() throws {
        let f = try Fixture()
        let message = try #require(try f.store.upsert([row(f.account.id, f.trash.id, uid: 4)]).first)
        let made = try f.store.createFolder(named: "New", wire: "New", in: nil, account: f.account.id, prefix: "")
        try f.store.apply(.moveTo(message, made))
        try f.store.apply(.delete(message))
        try f.store.apply(.delete(message))
        try f.store.undoFolderCreate(made)
        let left = try f.store.pendingActions().filter { $0.action == .delete(message) }
        #expect(left.count == 1)
        #expect(left.first?.sourceFolderID == f.trash.id)
        #expect(left.first?.sourceUID == 4)
    }

    @Test func aNewServerForgetsTheFolderPrefix() throws {
        let f = try Fixture()
        try f.store.setFolderPrefix("INBOX.", for: f.account.id)
        var moved = f.account
        moved.imap.host = "imap.example.net"
        try f.store.save(moved)
        #expect(try f.store.folderPrefix(f.account.id) == nil)
        try f.store.setFolderPrefix("INBOX.", for: f.account.id)
        var renamed = moved
        renamed.displayName = "Anna L"
        try f.store.save(renamed)
        #expect(try f.store.folderPrefix(f.account.id) == "INBOX.")
    }

    @Test func aSecondFolderChangeWaitsForTheFirst() throws {
        let f = try Fixture()
        let (parent, child, _) = try projects(f)
        try f.store.renameFolder(parent.id, to: "Work", wire: "Work", under: nil, prefix: "")
        #expect(throws: StoreError.folderChangeWaiting) {
            try f.store.createFolder(named: "Next", wire: "Next", in: nil, account: f.account.id, prefix: "")
        }
        #expect(throws: StoreError.folderChangeWaiting) { try f.store.deleteFolder(child.id) }
        #expect(throws: StoreError.folderChangeWaiting) {
            try f.store.renameFolder(child.id, to: "Q", wire: "Q", under: nil, prefix: "")
        }
        #expect(try f.store.isFolderChangeWaiting(f.account.id))
        let other = Fixture.makeAccount(name: "Bo", email: "bo@example.org", order: 1)
        try f.store.save(other)
        try f.store.replaceFolders(Fixture.folders(for: other.id), for: other.id)
        _ = try f.store.createFolder(named: "Elsewhere", wire: "Elsewhere", in: nil, account: other.id, prefix: "")
    }

    @Test func anUndoneChangeLeavesTheQueueInTheSameStep() throws {
        let f = try Fixture()
        let made = try f.store.createFolder(named: "New", wire: "New", in: nil, account: f.account.id, prefix: "")
        let create = try #require(try f.store.pendingActions().last?.id)
        try f.store.undoFolderCreate(made, completing: create)
        #expect(try f.store.pendingActions().isEmpty)
        let (parent, _, _) = try projects(f)
        try f.store.renameFolder(parent.id, to: "Work", wire: "Work", under: nil, prefix: "")
        let rename = try #require(try f.store.pendingActions().last?.id)
        try f.store.undoFolderRename(parent.id, from: "Projects", to: "Work", name: "Projects", completing: rename)
        #expect(try f.store.pendingActions().isEmpty)
    }

    @Test func aWaitingFolderChangeIsWatched() async throws {
        let f = try Fixture()
        var changes = f.store.observeFolderChangeWaiting().makeAsyncIterator()
        #expect(try await changes.next() == [])
        _ = try f.store.createFolder(named: "New", wire: "New", in: nil, account: f.account.id, prefix: "")
        #expect(try await changes.next() == [f.account.id])
    }

    @Test func aRefusalIsKeptUntilDismissed() throws {
        let f = try Fixture()
        try f.store.setFolderRefusal(FolderRefusal(name: "Old", gaveUp: true), for: f.account.id)
        #expect(try f.store.folderRefusals()[f.account.id] == FolderRefusal(name: "Old", gaveUp: true))
        try f.store.dismissFolderRefusal(f.account.id, name: "Old")
        #expect(try f.store.folderRefusals().isEmpty)
    }

    @Test func aFolderChangeCountsOneTryPerMinute() throws {
        let f = try Fixture()
        _ = try f.store.createFolder(named: "New", wire: "New", in: nil, account: f.account.id, prefix: "")
        let id = try #require(try f.store.pendingActions().last?.id)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(try f.store.noteFolderTry(id, at: start) == 1)
        #expect(try f.store.noteFolderTry(id, at: start.addingTimeInterval(30)) == 1)
        #expect(try f.store.noteFolderTry(id, at: start.addingTimeInterval(61)) == 2)
    }

    @Test func aGivenUpDeleteRestoresTheFolders() throws {
        let f = try Fixture()
        let (parent, child, _) = try projects(f)
        try f.store.deleteFolder(parent.id)
        let delete = try #require(try f.store.pendingActions().last?.id)
        try f.store.restoreFolders([parent, child], of: f.account.id, completing: delete)
        let back = try f.store.folders(f.account.id)
        #expect(back.first { $0.id == parent.id }?.path == "Projects")
        #expect(back.first { $0.id == child.id }?.path == "Projects/2026")
        #expect(try f.store.pendingActions().isEmpty)
    }

    @Test func anUndoTellsTheOwnerInTheSameStep() throws {
        let f = try Fixture()
        let made = try f.store.createFolder(named: "New", wire: "New", in: nil, account: f.account.id, prefix: "")
        let create = try #require(try f.store.pendingActions().last?.id)
        let told = FolderRefusal(name: "New", gaveUp: false)
        try f.store.undoFolderCreate(made, completing: create, telling: told)
        #expect(try f.store.folderRefusals()[f.account.id] == told)
    }

    @Test func aRestoreWhosePathIsTakenKeepsWhatIsQueuedForIt() throws {
        let f = try Fixture()
        let (parent, child, message) = try projects(f)
        try f.store.apply(.moveTo(message, f.inbox.id))
        try f.store.deleteFolder(parent.id)
        let delete = try #require(try f.store.pendingActions().last?.id)
        var all = try f.store.folders(f.account.id)
        all.append(Folder(
            id: FolderID(raw: 0), accountID: f.account.id, path: "Projects/2026", name: "2026", kind: .other,
            uidValidity: 9, unread: 0, isFavorite: false, delimiter: "/"))
        try f.store.replaceFolders(all, for: f.account.id)
        let taken = try #require(try folder(f, "Projects/2026"))
        try f.store.restoreFolders([parent, child], of: f.account.id, completing: delete)
        #expect(try f.store.pendingActions().first?.sourceFolderID == taken.id)
    }

    @Test func aRestoreWhosePathIsTakenRedirectsMovesIntoIt() throws {
        let f = try Fixture()
        let (parent, child, _) = try projects(f)
        let message = try #require(try f.store.upsert([row(f.account.id, f.inbox.id, uid: 7)]).first)
        try f.store.apply(.moveTo(message, child.id))
        try f.store.apply(.moveTo(message, f.sent.id))
        try f.store.deleteFolder(parent.id)
        let delete = try #require(try f.store.pendingActions().last?.id)
        var all = try f.store.folders(f.account.id)
        all.append(Folder(
            id: FolderID(raw: 0), accountID: f.account.id, path: "Projects/2026", name: "2026", kind: .other,
            uidValidity: 9, unread: 0, isFavorite: false, delimiter: "/"))
        try f.store.replaceFolders(all, for: f.account.id)
        let taken = try #require(try folder(f, "Projects/2026"))
        try f.store.restoreFolders([parent, child], of: f.account.id, completing: delete)
        #expect(try f.store.pendingActions().first?.action == .moveTo(message, taken.id))
    }

    @Test func anEmptyRestoreStillTellsTheOwner() throws {
        let f = try Fixture()
        let (parent, _, _) = try projects(f)
        try f.store.deleteFolder(parent.id)
        let delete = try #require(try f.store.pendingActions().last?.id)
        let told = FolderRefusal(name: "Projects", gaveUp: true)
        try f.store.restoreFolders([], of: f.account.id, completing: delete, telling: told)
        #expect(try f.store.folderRefusals()[f.account.id] == told)
    }

    @Test func dismissingClearsOnlyTheRefusalShown() throws {
        let f = try Fixture()
        try f.store.setFolderRefusal(FolderRefusal(name: "Newer", gaveUp: false), for: f.account.id)
        try f.store.dismissFolderRefusal(f.account.id, name: "Older")
        #expect(try f.store.folderRefusals()[f.account.id]?.name == "Newer")
        try f.store.dismissFolderRefusal(f.account.id, name: "Newer")
        #expect(try f.store.folderRefusals().isEmpty)
    }

    @Test func aStrayCopyAFilingWaitsOnIsKept() throws {
        let f = try Fixture()
        let message = try #require(try f.store.upsert([row(f.account.id, f.inbox.id, uid: 5)]).first)
        try f.store.apply(.moveTo(message, f.sent.id))
        try f.store.write { database in
            try MailStore.queue(
                database, .fileSent(message),
                from: MailStore.Source(account: f.account.id.raw.uuidString, folder: f.sent.id.raw, uid: 0, kind: "sent"))
        }
        try f.store.dropStrayCopy(message, in: nil)
        #expect(try f.store.message(message) != nil)
        try f.store.completeAction(try #require(try f.store.pendingActions().last?.id))
        try f.store.dropStrayCopy(message, in: nil)
        #expect(try f.store.message(message) == nil)
    }

    @Test func folderActionsHaveNoMessageTarget() {
        #expect(MailAction.createFolder(FolderID(raw: 1)).target == nil)
        #expect(MailAction.setRead(MessageID(raw: 3), true).target == MessageID(raw: 3))
    }
}
