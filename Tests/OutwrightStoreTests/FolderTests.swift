// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import GRDB
import OutwrightMIME
import OutwrightModel
import Testing

@testable import OutwrightStore

@Suite struct FolderTests {
    @Test func aFolderRemembersItsModSeq() throws {
        let f = try Fixture()
        #expect(try f.store.highestModSeq(f.inbox.id) == nil)
        try f.store.setHighestModSeq(f.inbox.id, UInt64.max - 1)
        #expect(try f.store.highestModSeq(f.inbox.id) == UInt64.max - 1)
        try f.store.setHighestModSeq(f.inbox.id, nil)
        #expect(try f.store.highestModSeq(f.inbox.id) == nil)
    }

    @Test func aRenumberedFolderForgetsItsModSeq() throws {
        let f = try Fixture()
        try f.store.setHighestModSeq(f.inbox.id, 42)
        try f.store.resetFolder(f.inbox.id, uidValidity: 9)
        #expect(try f.store.highestModSeq(f.inbox.id) == nil)
    }

    @Test func aFolderListRefreshKeepsTheModSeq() throws {
        let f = try Fixture()
        try f.store.setHighestModSeq(f.inbox.id, 42)
        try f.store.replaceFolders(try f.store.folders(f.account.id), for: f.account.id)
        #expect(try f.store.highestModSeq(f.inbox.id) == 42)
    }

    @Test func aMessageForgetsItsFoldersModSeq() throws {
        let f = try Fixture()
        let held = try #require(try f.store.upsert([row(f.account.id, f.inbox.id, uid: 3)]).first)
        try f.store.setHighestModSeq(f.inbox.id, 42)
        try f.store.setHighestModSeq(f.sent.id, 7)
        try f.store.forgetHighestModSeq(holding: held)
        #expect(try f.store.highestModSeq(f.inbox.id) == nil)
        #expect(try f.store.highestModSeq(f.sent.id) == 7)
    }

    @Test func anEmptyFolderListRemovesTheFoldersThatHoldNothingUnsent() throws {
        let f = try Fixture()
        _ = try f.store.upsert([row(f.account.id, f.inbox.id, uid: 1)])
        try f.store.replaceFolders([], for: f.account.id)
        #expect(try f.store.folders(f.account.id).isEmpty)
        #expect(try f.store.messages(allInbox, limit: 5).isEmpty)
    }

    @Test func aFolderMissingFromTheListKeepsWhatTheServerHasNotGot() throws {
        let f = try Fixture()
        let draft = try #require(
            try f.store.upsert([row(f.account.id, f.sent.id, uid: 0, header: "d@example.org")]).first)
        let flagged = try #require(try f.store.upsert([row(f.account.id, f.trash.id, uid: 4)]).first)
        try f.store.apply(.setFlagged(flagged, true))
        _ = try f.store.upsert([row(f.account.id, f.inbox.id, uid: 1)])
        // Only Archive is listed: Inbox goes, Sent (an unsaved row) and Trash (a queued change) stay.
        let archive = Fixture.folders(for: f.account.id).filter { $0.kind == .archive }
        try f.store.replaceFolders(archive, for: f.account.id)
        let kept = Set(try f.store.folders(f.account.id).map(\.kind))
        #expect(kept == [.archive, .sent, .trash])
        #expect(try f.store.message(draft) != nil)
        #expect(try f.store.message(flagged) != nil)
        #expect(try f.store.pendingActions().count == 1)
    }

    @Test func aRefreshKeepsTheFavouriteMarkMadeMeanwhile() throws {
        let f = try Fixture()
        try f.store.setFavorite(f.sent.id, true)
        // A refresh read the folders before the mark was set and writes them back.
        var stale = Fixture.folders(for: f.account.id)
        for index in stale.indices { stale[index].isFavorite = false }
        try f.store.replaceFolders(stale, for: f.account.id)
        #expect(try f.store.folders(f.account.id).first { $0.id == f.sent.id }?.isFavorite == true)
    }

    @Test func aNewFolderTakesTheFavouriteMarkGiven() throws {
        let f = try Fixture()
        var folders = Fixture.folders(for: f.account.id)
        folders.append(
            Folder(
                id: FolderID(raw: 0), accountID: f.account.id, path: "Projects", name: "Projects", kind: .other,
                uidValidity: 1, unread: 0, isFavorite: true))
        try f.store.replaceFolders(folders, for: f.account.id)
        #expect(try f.store.folders(f.account.id).first { $0.path == "Projects" }?.isFavorite == true)
    }

    @Test func aFolderKeepsItsHierarchyDelimiter() throws {
        let f = try Fixture()
        var folders = Fixture.folders(for: f.account.id)
        var child = Folder(
            id: FolderID(raw: 0), accountID: f.account.id, path: "Projects/Old", name: "Old", kind: .other,
            uidValidity: 1, unread: 0, isFavorite: false)
        child.delimiter = "/"
        folders.append(child)
        try f.store.replaceFolders(folders, for: f.account.id)
        #expect(try f.store.folders(f.account.id).first { $0.path == "Projects/Old" }?.delimiter == "/")

        folders[folders.count - 1].delimiter = "."
        try f.store.replaceFolders(folders, for: f.account.id)
        #expect(try f.store.folders(f.account.id).first { $0.path == "Projects/Old" }?.delimiter == ".")
    }

    /// A folder giving way to another takes its messages and every change waiting on it along,
    /// a move queued to it included.
    @Test func aFolderGivingWayTakesItsMessagesAndChangesAlong() throws {
        let f = try Fixture()
        var folders = Fixture.folders(for: f.account.id)
        folders.append(
            Folder(
                id: FolderID(raw: 0), accountID: f.account.id, path: "Kept", name: "Kept", kind: .other,
                uidValidity: 0, unread: 0, isFavorite: false))
        try f.store.replaceFolders(folders, for: f.account.id)
        let made = try #require(try f.store.folders(f.account.id).first { $0.path == "Kept" })
        let message = try #require(try f.store.upsert([row(f.account.id, f.inbox.id, uid: 1)]).first)
        try f.store.apply(.moveTo(message, made.id))

        let archive = try #require(try f.store.folders(f.account.id).first { $0.kind == .archive })
        try f.store.adoptFolder(made.id, as: archive.path)

        #expect(try f.store.folders(f.account.id).contains { $0.id == made.id } == false)
        #expect(try f.store.message(message)?.folderID == archive.id)
        #expect(try f.store.pendingActions().map(\.action) == [.moveTo(message, archive.id)])
    }

    /// Mod-sequences remembered before the sync took a QRESYNC answer said before `[CLOSED]`
    /// may stand past changes it never saw: an upgraded store forgets them, so each folder is
    /// reconciled in full once.
    @Test func anUpgradedStoreForgetsTheModSeqs() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("v12-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let id = UUID().uuidString
        do {
            let old = try DatabaseQueue(path: url.path)
            try Schema.migrator().migrate(old, upTo: "v12")
            try old.write { database in
                try database.execute(
                    sql: """
                        INSERT INTO account (id, displayName, email, colorIndex, imapHost, imapPort,
                            imapSecurity, smtpHost, smtpPort, smtpSecurity, user, signature, sortOrder)
                        VALUES (?, 'Anna', 'anna@example.org', 0, 'm.example.org', 993, 'tls',
                            'm.example.org', 465, 'tls', 'anna', '', 0)
                        """, arguments: [id])
                try database.execute(
                    sql: """
                        INSERT INTO folder (id, accountId, path, name, kind, uidValidity, isFavorite, highestModSeq)
                        VALUES (1, ?, 'Support', 'Support', 'other', 7, 0, 405)
                        """, arguments: [id])
            }
        }
        let store = try MailStore(path: url)
        #expect(try store.highestModSeq(FolderID(raw: 1)) == nil)
    }
}

@Suite struct FolderObservationTests {
    /// The iPad's sidebar stays on screen: its unread counts and folders follow the store.
    @Test func observingFoldersSeesNewMailAndNewFolders() async throws {
        let f = try Fixture()
        let changes = f.store.observeFolders()
        let store = f.store
        let account = f.account
        let inbox = f.inbox
        let seen = try await withThrowingTaskGroup(of: Int?.self) { group in
            group.addTask {
                var changed = changes.makeAsyncIterator()
                _ = try await changed.next()
                _ = try store.upsert([row(account.id, inbox.id, uid: 1)])
                var count = try await changed.next() != nil ? 1 : 0
                var folders = try store.folders(account.id)
                folders.append(Folder(
                    id: FolderID(raw: 0), accountID: account.id, path: "Projects", name: "Projects", kind: .other,
                    uidValidity: 1, unread: 0, isFavorite: false))
                try store.replaceFolders(folders, for: account.id)
                count += try await changed.next() != nil ? 1 : 0
                return count
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                return nil
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }
        #expect(seen == 2)
    }
}
