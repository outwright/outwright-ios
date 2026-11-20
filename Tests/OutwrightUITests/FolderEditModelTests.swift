// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightMIME
import OutwrightModel
import OutwrightStore
import OutwrightSync
import Testing

@testable import OutwrightUI

@MainActor @Suite struct FolderEditModelTests {
    private func folder(_ box: Mailbox, _ account: Account, _ path: String) throws -> Folder {
        try #require(try box.store.folders(account.id).first { $0.path == path })
    }

    @Test func specialFoldersOfferOnlyNewSubfolder() throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org", extraFolders: ["Receipts"], delimiter: "/")
        let edits = FolderEdits(store: box.store, sync: nil)
        #expect(edits.actions(for: try box.folder(anna, .sent)) == [.newSubfolder])
        #expect(edits.actions(for: try box.folder(anna, .archive)) == [.newSubfolder])
        #expect(edits.actions(for: try folder(box, anna, "Receipts")) == [.newSubfolder, .rename, .move, .delete])
    }

    @Test func moveDestinationsLeaveOutTheFolderAndItsSubtree() throws {
        var box = try Mailbox()
        let anna = try box.addAccount(
            "anna@example.org", extraFolders: ["Projects", "Projects/2026", "Clubs"], delimiter: "/")
        let edits = FolderEdits(store: box.store, sync: nil)
        let paths = edits.moveDestinations(for: try folder(box, anna, "Projects")).map(\.folder.path)
        #expect(!paths.contains("Projects"))
        #expect(!paths.contains("Projects/2026"))
        #expect(paths.contains("Clubs"))
        #expect(paths.contains("Archive"))
    }

    @Test func aNameWithTheDelimiterIsRefused() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org", delimiter: "/")
        let edits = FolderEdits(store: box.store, sync: nil)
        let outcome = await edits.create(named: "a/b", in: nil, account: anna.id)
        guard case .problem = outcome else {
            Issue.record("expected a problem, got \(outcome)")
            return
        }
        #expect(try box.store.pendingActions().isEmpty)
    }

    @Test func aDuplicateNameIsRefused() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org", extraFolders: ["Receipts"])
        let edits = FolderEdits(store: box.store, sync: nil)
        let outcome = await edits.create(named: "Receipts", in: nil, account: anna.id)
        guard case .problem = outcome else {
            Issue.record("expected a problem, got \(outcome)")
            return
        }
    }

    @Test func createQueuesAndShowsAtOnce() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org", delimiter: "/")
        let edits = FolderEdits(store: box.store, sync: nil)
        guard case let .done(made) = await edits.create(named: "Kvitton & Öre", in: nil, account: anna.id) else {
            Issue.record("not made")
            return
        }
        let shown = DrawerModel(store: box.store, selected: anna.id).sections.last?.folders
        #expect(shown?.first { $0.id == made }?.name == "Kvitton & Öre")
        #expect(try box.store.folders(anna.id).first { $0.id == made }?.path == "Kvitton &- &ANY-re")
        #expect(try box.store.pendingActions().map(\.action) == [.createFolder(made)])
    }

    @Test func renameKeepsAFolderWhereItIs() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org", extraFolders: ["INBOX.Clubs"], delimiter: ".")
        let edits = FolderEdits(store: box.store, sync: nil)
        let clubs = try folder(box, anna, "INBOX.Clubs")
        #expect(await edits.rename(clubs, to: "Teams") == nil)
        #expect(try box.store.folders(anna.id).first { $0.id == clubs.id }?.path == "INBOX.Teams")
    }

    @Test func deleteWarningIsUnknownWithoutSync() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org", extraFolders: ["Receipts"])
        let edits = FolderEdits(store: box.store, sync: nil)
        #expect(await edits.deleteWarning(for: try folder(box, anna, "Receipts")) == .unknown)
    }

    @Test func aFolderDeleteCommitsAStagedMoveFirst() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org", extraFolders: ["Old"])
        let old = try folder(box, anna, "Old")
        let row = MessageRow(
            id: MessageID(raw: 0), accountID: anna.id, folderID: old.id, uid: 3, threadID: ThreadID(raw: "t3"),
            from: Address(name: nil, email: "bo@example.org"), to: [], cc: [], subject: "keep", preview: "",
            date: Date(timeIntervalSince1970: 1_800_000_000), isRead: false, isFlagged: false, hasAttachment: false,
            isInvitation: false, inboxClass: .focused, hasBody: false, threadCount: 1)
        let message = try #require(try box.store.upsert([row]).first)
        let inbox = try box.folder(anna, .inbox)
        let pending = PendingMail(store: box.store, sleep: { _ in try await Task.sleep(for: .seconds(3_600)) })
        pending.stage([.moveTo(message, inbox.id)], hiding: [message], text: "Moved")
        let edits = FolderEdits(store: box.store, sync: nil, pending: pending)
        edits.delete(old)
        #expect(try box.store.message(message)?.folderID == inbox.id)
        #expect(try box.store.pendingActions().first?.action == .moveTo(message, inbox.id))
    }

    @Test func aNameIsTrimmedBeforeItIsWritten() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let edits = FolderEdits(store: box.store, sync: nil)
        guard case let .done(made) = await edits.create(named: " Receipts ", in: nil, account: anna.id) else {
            Issue.record("not made")
            return
        }
        #expect(try box.store.folders(anna.id).first { $0.id == made }?.path == "Receipts")
    }

    @Test func theInboxAndFoldersWithoutADelimiterTakeNoSubfolders() throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org", extraFolders: ["Projects", "Clubs"], delimiter: "/")
        let bo = try box.addAccount("bo@example.org", extraFolders: ["Flat", "Other"])
        let edits = FolderEdits(store: box.store, sync: nil)
        #expect(edits.actions(for: try box.folder(anna, .inbox)).isEmpty)
        #expect(!edits.actions(for: try folder(box, bo, "Flat")).contains(.newSubfolder))
        let targets = edits.moveDestinations(for: try folder(box, anna, "Projects")).map(\.folder.kind)
        #expect(!targets.contains(.inbox))
        #expect(edits.moveDestinations(for: try folder(box, bo, "Flat")).isEmpty)
    }

    @Test func aFolderHoldingASpecialFolderOffersOnlyNewSubfolder() throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org", extraFolders: ["Stuff"], delimiter: "/")
        var all = try box.store.folders(anna.id)
        var held = try folder(box, anna, "Stuff")
        held.id = FolderID(raw: 0)
        held.path = "Stuff/Spam"
        held.name = "Spam"
        held.kind = .junk
        all.append(held)
        try box.store.replaceFolders(all, for: anna.id)
        let edits = FolderEdits(store: box.store, sync: nil)
        #expect(edits.actions(for: try folder(box, anna, "Stuff")) == [.newSubfolder])
    }

    @Test func deletingTheFolderInViewOpensAllInboxes() throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org", extraFolders: ["Old"])
        let app = AppModel(store: box.store, sync: offlineSync(store: box.store, secrets: InMemorySecretStore()))
        let old = try folder(box, anna, "Old")
        app.open(old.id)
        app.deleteFolder(old)
        #expect(app.scope == .allAccounts)
    }

    @Test func aWaitingFolderChangeHoldsTheNext() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org", extraFolders: ["Clubs"], delimiter: "/")
        let edits = FolderEdits(store: box.store, sync: nil)
        guard case .done = await edits.create(named: "Receipts", in: nil, account: anna.id) else {
            Issue.record("not made")
            return
        }
        #expect(edits.isWaiting(anna.id))
        #expect(edits.actions(for: try folder(box, anna, "Clubs")).isEmpty)
        guard case .problem = await edits.create(named: "Second", in: nil, account: anna.id) else {
            Issue.record("a second change went through")
            return
        }
    }

    @Test func whileAChangeWaitsNoNewFolderIsOfferedAndADeleteSaysWhy() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org", extraFolders: ["Clubs"], delimiter: "/")
        let app = AppModel(store: box.store, sync: offlineSync(store: box.store, secrets: InMemorySecretStore()))
        let targets = DrawerModel.tree(try box.store.folders(anna.id))
        #expect(app.newFolder(in: targets) != nil)
        guard case .done = await app.folderEdits.create(named: "Receipts", in: nil, account: anna.id) else {
            Issue.record("not made")
            return
        }
        #expect(app.newFolder(in: targets) == nil)
        #expect(app.folderEdits.delete(try folder(box, anna, "Clubs")) != nil)
        #expect(DrawerModel(store: box.store, selected: anna.id).isWaiting(anna.id))
    }
}
