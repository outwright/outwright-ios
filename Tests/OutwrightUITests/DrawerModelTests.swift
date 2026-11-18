// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightModel
import OutwrightStore
import Testing

@testable import OutwrightUI

@MainActor @Suite struct DrawerModelTests {
    /// On an iPad the folders stay on screen: new mail's unread count shows without reopening anything.
    @Test func watchingTheStoreKeepsUnreadCountsCurrent() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let inbox = try box.folder(anna, .inbox)
        let model = DrawerModel(store: box.store, selected: anna.id)
        let watching = Task { await model.observe() }
        defer { watching.cancel() }
        try box.add(anna, uid: 1)
        func unread() -> Int? { model.sections.last?.folders.first { $0.id == inbox.id }?.unread }
        for _ in 0..<100 where unread() != 1 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(unread() == 1)
    }

    @Test func favoritesFirstThenFolders() throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org", extraFolders: ["Receipts", "Clubs"])
        let inbox = try box.folder(anna, .inbox)
        let sent = try box.folder(anna, .sent)
        try box.add(anna, uid: 1)
        try box.add(anna, uid: 2, read: true)
        let model = DrawerModel(store: box.store, selected: anna.id)
        model.setFavorites([sent.id, inbox.id])

        #expect(model.sections.map(\.kind) == [.favorites, .account(anna.id)])
        #expect(model.sections.first?.folders.map(\.id) == [inbox.id, sent.id])
        let names = model.sections.last?.folders.map(\.name)
        #expect(names == ["INBOX", "Drafts", "Sent", "Archive", "Trash", "Junk", "Clubs", "Receipts"])
        #expect(model.sections.first?.folders.first?.unread == 1)
    }

    @Test func allAccountsShowsEveryAccountsFolders() throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let bo = try box.addAccount("bo@example.org")
        let model = DrawerModel(store: box.store, selected: nil)
        #expect(model.sections.map(\.kind) == [.favorites, .account(anna.id), .account(bo.id)])
    }

    @Test func editingFavoritesPersists() throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let drafts = try box.folder(anna, .drafts)
        let model = DrawerModel(store: box.store, selected: anna.id)
        model.setFavorites([drafts.id])
        let again = DrawerModel(store: box.store, selected: anna.id)
        #expect(again.sections.first?.folders.map(\.id) == [drafts.id])
        again.setFavorites([])
        #expect(DrawerModel(store: box.store, selected: anna.id).sections.first?.folders.isEmpty == true)
        #expect(try box.store.folders(anna.id).count == 6)
    }

    @Test func subfoldersFollowTheirParentOneStepIn() throws {
        var box = try Mailbox()
        let anna = try box.addAccount(
            "anna@example.org", extraFolders: ["Ekonomi", "BDD/Inbox", "BDD", "Adwise", "BDD/Sent", "Ekonomi/BDD"],
            delimiter: "/")
        let model = DrawerModel(store: box.store, selected: anna.id)
        let rows = model.editableFolders.last?.folders.filter { $0.kind == .other }.map { ($0.path, model.depth($0)) }
        #expect(rows?.map(\.0) == ["Adwise", "BDD", "BDD/Inbox", "BDD/Sent", "Ekonomi", "Ekonomi/BDD"])
        #expect(rows?.map(\.1) == [0, 0, 1, 1, 0, 1])
    }

    @Test func aFolderStartsFoldedAndUnfoldsOneLevel() throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org", extraFolders: ["BDD", "BDD/Inbox", "BDD/Inbox/Old"], delimiter: "/")
        let model = DrawerModel(store: box.store, selected: anna.id)
        let bdd = try #require(model.sections.last?.folders.first { $0.path == "BDD" })
        #expect(model.hasSubfolders(bdd))
        #expect(model.isCollapsed(bdd))
        #expect(model.sections.last?.folders.contains { $0.path.hasPrefix("BDD/") } == false)
        model.toggle(bdd)
        #expect(!model.isCollapsed(bdd))
        #expect(model.sections.last?.folders.filter { $0.path.hasPrefix("BDD/") }.map(\.path) == ["BDD/Inbox"])
        model.toggle(bdd)
        #expect(model.sections.last?.folders.contains { $0.path.hasPrefix("BDD/") } == false)
    }

    @Test func revealingAFolderUnfoldsWhatItLiesUnder() throws {
        var box = try Mailbox()
        let anna = try box.addAccount(
            "anna@example.org", extraFolders: ["BDD", "BDD/Inbox", "BDD/Inbox/Old", "BDD/Sent", "Ekonomi", "Ekonomi/2025"],
            delimiter: "/")
        let model = DrawerModel(store: box.store, selected: anna.id)
        let old = try #require(model.editableFolders.last?.folders.first { $0.path == "BDD/Inbox/Old" })
        model.reveal(old.id)
        let shown = model.sections.last?.folders.filter { $0.kind == .other }.map(\.path)
        #expect(shown == ["BDD", "BDD/Inbox", "BDD/Inbox/Old", "BDD/Sent", "Ekonomi"])
    }

    @Test func aFolderUnderTheInboxStaysAtTheTop() throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org", extraFolders: ["INBOX/Clubs"], delimiter: "/")
        let model = DrawerModel(store: box.store, selected: anna.id)
        let clubs = try #require(model.sections.last?.folders.first { $0.path == "INBOX/Clubs" })
        #expect(model.depth(clubs) == 0)
    }

    @Test func aFolderFoldsAwayItsSubfoldersAtAnyDepth() throws {
        var box = try Mailbox()
        let chain = (1...20).map { level in (0..<level).map { "L\($0)" }.joined(separator: "/") }
        let anna = try box.addAccount("anna@example.org", extraFolders: chain, delimiter: "/")
        let model = DrawerModel(store: box.store, selected: anna.id)
        let deep = try #require(model.editableFolders.last?.folders.first { $0.path == chain[18] })
        model.reveal(deep.id)
        #expect(model.sections.last?.folders.contains { $0.path == chain[18] } == true)
        #expect(model.sections.last?.folders.contains { $0.path == chain[19] } == false)
    }

    @Test func favoritesWithTheSameNameNameTheirAccount() throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let bo = try box.addAccount("bo@example.org")
        let model = DrawerModel(store: box.store, selected: nil)
        let annaInbox = try box.folder(anna, .inbox)
        let boInbox = try box.folder(bo, .inbox)
        let sent = try box.folder(anna, .sent)
        model.setFavorites([annaInbox.id, boInbox.id, sent.id])
        #expect(model.accountNameBelow(annaInbox) == "anna@example.org")
        #expect(model.accountNameBelow(boInbox) == "bo@example.org")
        #expect(model.accountNameBelow(sent) == nil)
    }
}
