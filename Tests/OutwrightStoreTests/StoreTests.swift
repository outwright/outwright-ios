// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightMIME
import OutwrightModel
import Testing

@testable import OutwrightStore

struct Fixture {
    let store: MailStore
    let account: Account
    let inbox: Folder
    let sent: Folder
    let trash: Folder

    init() throws {
        store = try MailStore(path: nil)
        account = Self.makeAccount(name: "Anna", email: "anna@example.org", order: 0)
        try store.save(account)
        try store.replaceFolders(Self.folders(for: account.id), for: account.id)
        let all = try store.folders(account.id)
        inbox = try #require(all.first { $0.kind == .inbox })
        sent = try #require(all.first { $0.kind == .sent })
        trash = try #require(all.first { $0.kind == .trash })
    }

    static func makeAccount(name: String, email: String, order: Int) -> Account {
        let endpoint = MailEndpoint(host: "mail.example.org", port: 993, security: "tls")
        return Account(
            id: AccountID(raw: UUID()), displayName: name, email: email, colorIndex: order,
            imap: endpoint, smtp: endpoint, user: email, signature: "", sortOrder: order)
    }

    static func folders(for id: AccountID) -> [Folder] {
        let kinds: [(String, FolderKind)] = [
            ("INBOX", .inbox), ("Sent", .sent), ("Trash", .trash), ("Archive", .archive),
        ]
        return kinds.map {
            Folder(
                id: FolderID(raw: 0), accountID: id, path: $0.0, name: $0.0, kind: $0.1,
                uidValidity: 1, unread: 0, isFavorite: false)
        }
    }
}

func row(
    _ account: AccountID, _ folder: FolderID, uid: UInt32, thread: String? = nil,
    subject: String = "Hej", from: String = "bo@example.org", to: [String] = ["anna@example.org"],
    minutes: Double = 0, read: Bool = false, flagged: Bool = false, cls: InboxClass = .focused,
    header: String? = nil
) -> MessageRow {
    MessageRow(
        id: MessageID(raw: 0), accountID: account, folderID: folder, uid: uid,
        threadID: ThreadID(raw: thread ?? "t\(uid)"),
        from: Address(name: "Bo", email: from), to: to.map { Address(name: nil, email: $0) }, cc: [],
        subject: subject, preview: "preview \(uid)",
        date: Date(timeIntervalSince1970: 1_700_000_000 + minutes * 60),
        isRead: read, isFlagged: flagged, hasAttachment: false, isInvitation: false,
        inboxClass: cls, hasBody: false, threadCount: 1, messageIDHeader: header)
}

func mime(_ body: String) -> Data {
    let head = "From: bo@example.org\r\nSubject: Hej\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n"
    return Data((head + body + "\r\n").utf8)
}

let allInbox = InboxQuery(scope: .allAccounts, inboxClass: nil, filter: .all)

@Suite struct StoreTests {
    @Test func allAccountsMergesInboxesNewestFirst() throws {
        let f = try Fixture()
        let other = Fixture.makeAccount(name: "Work", email: "anna@work.example", order: 1)
        try f.store.save(other)
        try f.store.replaceFolders(Fixture.folders(for: other.id), for: other.id)
        let otherInbox = try #require(try f.store.folders(other.id).first { $0.kind == .inbox })
        _ = try f.store.upsert([
            row(f.account.id, f.inbox.id, uid: 1, minutes: 1),
            row(other.id, otherInbox.id, uid: 1, minutes: 3),
            row(f.account.id, f.inbox.id, uid: 2, minutes: 2),
            row(f.account.id, f.sent.id, uid: 1, minutes: 9)
        ])
        let rows = try f.store.messages(allInbox, limit: 50)
        let expected: [Double] = [3, 2, 1].map { 1_700_000_000 + Double($0) * 60 }
        #expect(rows.map(\.date.timeIntervalSince1970) == expected)
        #expect(Set(rows.map(\.accountID)) == [f.account.id, other.id])
    }

    @Test func threadCollapsesToNewestWithCount() throws {
        let f = try Fixture()
        _ = try f.store.upsert([
            row(f.account.id, f.inbox.id, uid: 1, thread: "T", subject: "old", minutes: 1),
            row(f.account.id, f.inbox.id, uid: 2, thread: "T", subject: "new", minutes: 5),
            row(f.account.id, f.inbox.id, uid: 3, thread: "T", subject: "mid", minutes: 3),
            row(f.account.id, f.inbox.id, uid: 4, thread: "U", minutes: 2)
        ])
        let rows = try f.store.messages(allInbox, limit: 50)
        #expect(rows.count == 2)
        #expect(rows.first?.subject == "new")
        #expect(rows.first?.threadCount == 3)
        let thread = try f.store.thread(ThreadID(raw: "T"), account: f.account.id)
        #expect(thread.map(\.subject) == ["old", "mid", "new"])
    }

    @Test func filterUnreadAndFlagged() throws {
        let f = try Fixture()
        _ = try f.store.upsert([
            row(f.account.id, f.inbox.id, uid: 1, read: true, flagged: true),
            row(f.account.id, f.inbox.id, uid: 2, read: false),
            row(f.account.id, f.inbox.id, uid: 3, read: true, cls: .other)
        ])
        func uids(_ filter: InboxFilter, _ cls: InboxClass? = nil) throws -> Set<UInt32> {
            let q = InboxQuery(scope: .folder(f.inbox.id), inboxClass: cls, filter: filter)
            return Set(try f.store.messages(q, limit: 50).map(\.uid))
        }
        #expect(try uids(.unread) == [2])
        #expect(try uids(.flagged) == [1])
        #expect(try uids(.all, .other) == [3])
        #expect(try uids(.all, .focused) == [1, 2])
        #expect(try f.store.folders(f.account.id).first { $0.kind == .inbox }?.unread == 1)
    }

    @Test func applyMoveUpdatesListAndQueues() throws {
        let f = try Fixture()
        let id = try #require(try f.store.upsert([row(f.account.id, f.inbox.id, uid: 1)]).first)
        try f.store.apply(.move(id, to: .archive))
        #expect(try f.store.messages(allInbox, limit: 5).isEmpty)
        try f.store.apply(.setRead(id, true))
        try f.store.apply(.delete(id))
        let pending = try f.store.pendingActions()
        #expect(pending.map(\.action) == [.move(id, to: .archive), .setRead(id, true), .delete(id)])
        let trashQuery = InboxQuery(scope: .folder(f.trash.id), inboxClass: nil, filter: .all)
        #expect(try f.store.messages(trashQuery, limit: 5).first?.isRead == true)
        try f.store.completeAction(try #require(pending.first).id)
        #expect(try f.store.pendingActions().count == 2)
    }

    @Test func queuedMoveCarriesSourceFolderAndUID() throws {
        let f = try Fixture()
        let id = try #require(try f.store.upsert([row(f.account.id, f.inbox.id, uid: 42)]).first)
        try f.store.apply(.move(id, to: .archive))
        let queued = try #require(try f.store.pendingActions().first)
        #expect(queued.action == .move(id, to: .archive))
        #expect(queued.sourceFolderID == f.inbox.id)
        #expect(queued.sourceUID == 42)
        #expect(queued.accountID == f.account.id)
        #expect(try f.store.message(id)?.uid == 0)
        // The same folder again: nothing happens, nothing is queued, the uid stays.
        let other = try #require(try f.store.upsert([row(f.account.id, f.inbox.id, uid: 43)]).first)
        try f.store.apply(.move(other, to: .inbox))
        #expect(try f.store.pendingActions().count == 1)
        #expect(try f.store.message(other)?.uid == 43)
    }

    @Test func permanentDeleteKeepsTombstone() throws {
        let f = try Fixture()
        let id = try #require(try f.store.upsert([row(f.account.id, f.trash.id, uid: 9)]).first)
        try f.store.apply(.delete(id))
        #expect(try f.store.message(id) == nil)
        let queued = try #require(try f.store.pendingActions().first)
        #expect(queued.action == .delete(id))
        #expect(queued.sourceFolderID == f.trash.id)
        #expect(queued.sourceUID == 9)
    }

    @Test func settleMoveSetsUIDOrDropsPlaceholder() throws {
        let f = try Fixture()
        let ids = try f.store.upsert([
            row(f.account.id, f.inbox.id, uid: 1), row(f.account.id, f.inbox.id, uid: 2)
        ])
        for id in ids { try f.store.apply(.move(id, to: .archive)) }
        try f.store.settleMove(ids[0], newUID: 77)
        try f.store.settleMove(ids[1], newUID: nil)
        #expect(try f.store.message(ids[0])?.uid == 77)
        #expect(try f.store.message(ids[1]) == nil)
        #expect(try f.store.search("preview", limit: 10).map(\.id) == [ids[0]])
    }

    @Test func upsertMatchesPlaceholderByMessageID() throws {
        let f = try Fixture()
        let id = try #require(try f.store.upsert([row(f.account.id, f.inbox.id, uid: 1, header: "<m@example.org>")]).first)
        try f.store.apply(.move(id, to: .archive))
        let archive = try #require(try f.store.folders(f.account.id).first { $0.kind == .archive })
        let back = try f.store.upsert([row(f.account.id, archive.id, uid: 5, header: "<m@example.org>")])
        #expect(back == [id])
        #expect(try f.store.message(id)?.uid == 5)
        #expect(try f.store.folderIndex(archive.id) == [5: id])
    }

    @Test func threadLookupByMessageIDAcrossBatches() throws {
        let f = try Fixture()
        _ = try f.store.upsert([row(f.account.id, f.inbox.id, uid: 1, thread: "T1", header: "<a@example.org>")])
        _ = try f.store.upsert([row(f.account.id, f.inbox.id, uid: 2, thread: "T2", header: "<b@example.org>")])
        #expect(try f.store.threadID(forMessageID: "<a@example.org>", account: f.account.id) == ThreadID(raw: "T1"))
        #expect(try f.store.threadID(forMessageID: "<b@example.org>", account: f.account.id) == ThreadID(raw: "T2"))
        #expect(try f.store.threadID(forMessageID: "<zz@example.org>", account: f.account.id) == nil)
    }

    @Test func resetFolderDropsRows() throws {
        let f = try Fixture()
        _ = try f.store.upsert([row(f.account.id, f.inbox.id, uid: 1), row(f.account.id, f.sent.id, uid: 1)])
        try f.store.resetFolder(f.inbox.id, uidValidity: 77)
        #expect(try f.store.messages(allInbox, limit: 5).isEmpty)
        #expect(try f.store.search("preview", limit: 10).map(\.folderID) == [f.sent.id])
        #expect(try f.store.folders(f.account.id).first { $0.id == f.inbox.id }?.uidValidity == 77)
    }

    @Test func aFolderRemembersHowFarBackItIsHeld() throws {
        let f = try Fixture()
        #expect(try f.store.heldSince(f.inbox.id) == nil)
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        try f.store.setHeldSince(f.inbox.id, day)
        #expect(try f.store.heldSince(f.inbox.id) == day)
        #expect(try f.store.heldSince(f.sent.id) == nil)
        try f.store.replaceFolders(try f.store.folders(f.account.id), for: f.account.id)
        #expect(try f.store.heldSince(f.inbox.id) == day, "a folder list from the server keeps it")
        try f.store.resetFolder(f.inbox.id, uidValidity: 77)
        #expect(try f.store.heldSince(f.inbox.id) == nil, "a renumbered folder starts over")
    }

    @Test func resetFolderKeepsUnnumberedRows() throws {
        let f = try Fixture()
        let ids = try f.store.upsert([
            row(f.account.id, f.inbox.id, uid: 1),
            row(f.account.id, f.inbox.id, uid: 0, header: "draft@example.org"),
        ])
        try f.store.resetFolder(f.inbox.id, uidValidity: 77)
        #expect(try f.store.message(ids[0]) == nil)
        #expect(try f.store.message(ids[1]) != nil)
    }

    @Test func resetFolderForgetsTheUIDsActionsWereQueuedWith() throws {
        let f = try Fixture()
        let ids = try f.store.upsert([row(f.account.id, f.inbox.id, uid: 7), row(f.account.id, f.sent.id, uid: 8)])
        try f.store.apply(.setFlagged(ids[0], true))
        try f.store.apply(.setFlagged(ids[1], true))
        try f.store.resetFolder(f.inbox.id, uidValidity: 77)
        let queued = try f.store.pendingActions()
        #expect(queued.first { $0.sourceFolderID == f.inbox.id }?.sourceUID == 0)
        #expect(queued.first { $0.sourceFolderID == f.sent.id }?.sourceUID == 8)
    }

    @Test func forgettingAQueuedUIDLeavesTheActionToBeFound() throws {
        let f = try Fixture()
        let id = try #require(try f.store.upsert([row(f.account.id, f.inbox.id, uid: 42)]).first)
        try f.store.apply(.setFlagged(id, true))
        let queued = try #require(try f.store.pendingActions().first)
        try f.store.forgetSourceUID(of: queued.id)
        let after = try #require(try f.store.pendingActions().first)
        #expect(after.sourceUID == 0)
        #expect(after.sourceFolderID == f.inbox.id)
        #expect(after.action == .setFlagged(id, true))
    }

    @Test func setBodyReindexes() throws {
        let f = try Fixture()
        let id = try #require(try f.store.upsert([row(f.account.id, f.inbox.id, uid: 1)]).first)
        #expect(try f.store.message(id)?.hasBody == false)
        let raw = mime("Här kommer din räkning för oktober.")
        try f.store.setBody(raw, for: id)
        let hits = try f.store.search("räkning", limit: 10)
        #expect(hits.map(\.id) == [id])
        #expect(hits.first?.hasBody == true)
        #expect(try f.store.body(id) == raw)
        #expect(try f.store.search("saknas", limit: 10).isEmpty)
        #expect(try f.store.search("\"; DROP", limit: 10).isEmpty)
        // An upsert of the same message keeps the body and its index.
        _ = try f.store.upsert([row(f.account.id, f.inbox.id, uid: 1)])
        #expect(try f.store.search("räkning", limit: 10).count == 1)
        // A permanent delete removes the index entry.
        try f.store.apply(.move(id, to: .trash))
        try f.store.apply(.delete(id))
        #expect(try f.store.search("räkning", limit: 10).isEmpty)
    }

    @Test func removeMessagesDropsRowsAndIndex() throws {
        let f = try Fixture()
        let ids = try f.store.upsert([row(f.account.id, f.inbox.id, uid: 1), row(f.account.id, f.inbox.id, uid: 2)])
        try f.store.setBody(mime("räkning"), for: ids[0])
        try f.store.removeMessages(folder: f.inbox.id, uids: [1, 99])
        #expect(try f.store.folderIndex(f.inbox.id) == [2: ids[1]])
        #expect(try f.store.search("räkning", limit: 10).isEmpty)
        #expect(try f.store.search("preview", limit: 10).map(\.id) == [ids[1]])
    }

    @Test func removeMessageDropsOneUnnumberedRow() throws {
        let f = try Fixture()
        let ids = try f.store.upsert([
            row(f.account.id, f.inbox.id, uid: 0, header: "a@example.org"),
            row(f.account.id, f.inbox.id, uid: 0, header: "b@example.org"),
        ])
        try f.store.setBody(mime("räkning"), for: ids[0])
        try f.store.removeMessage(ids[0])
        #expect(try f.store.message(ids[0]) == nil)
        #expect(try f.store.message(ids[1]) != nil)
        #expect(try f.store.search("räkning", limit: 10).isEmpty)
    }

    @Test func setUIDRenumbersOneRow() throws {
        let f = try Fixture()
        let ids = try f.store.upsert([row(f.account.id, f.inbox.id, uid: 5), row(f.account.id, f.inbox.id, uid: 6)])
        try f.store.setUID(9, for: ids[0])
        #expect(try f.store.folderIndex(f.inbox.id) == [9: ids[0], 6: ids[1]])
    }

    @Test func updateFlagsDoesNotEnqueue() throws {
        let f = try Fixture()
        let id = try #require(try f.store.upsert([row(f.account.id, f.inbox.id, uid: 1)]).first)
        try f.store.updateFlags(id, isRead: true, isFlagged: true)
        let message = try #require(try f.store.message(id))
        #expect(message.isRead && message.isFlagged)
        #expect(try f.store.pendingActions().isEmpty)
    }

    @Test func correspondentsAreWhoTheOwnerWroteTo() throws {
        let f = try Fixture()
        _ = try f.store.upsert([
            row(f.account.id, f.sent.id, uid: 1, from: "anna@example.org", to: ["Cy@Example.org"])
        ])
        #expect(try f.store.correspondents(f.account.id) == ["cy@example.org"])
    }

    @Test func overrideResortsHeldMail() throws {
        let f = try Fixture()
        let id = try #require(try f.store.upsert([row(f.account.id, f.inbox.id, uid: 5, from: "Åsa@Example.org", cls: .focused)]).first)
        try f.store.setOverride("ÅSA@example.org", .other)
        #expect(try f.store.overrides() == ["åsa@example.org": .other])
        #expect(try f.store.message(id)?.inboxClass == .other)
    }

    @Test func setFavoriteChangesOneFolderOnly() throws {
        let f = try Fixture()
        try f.store.setFavorite(f.sent.id, true)
        #expect(try f.store.folders(f.account.id).filter(\.isFavorite).map(\.id) == [f.sent.id])
        try f.store.setFavorite(f.sent.id, false)
        #expect(try f.store.folders(f.account.id).allSatisfy { !$0.isFavorite })
        #expect(throws: StoreError.noSuchFolder) { try f.store.setFavorite(FolderID(raw: 999), true) }
    }

    @Test func upsertReturnsIdsInInputOrder() throws {
        let f = try Fixture()
        let first = try f.store.upsert([row(f.account.id, f.inbox.id, uid: 1), row(f.account.id, f.inbox.id, uid: 2)])
        let again = try f.store.upsert([row(f.account.id, f.inbox.id, uid: 2), row(f.account.id, f.inbox.id, uid: 1)])
        #expect(again == first.reversed())
    }

    @Test func observeEmitsAfterUpsert() async throws {
        let f = try Fixture()
        let query = allInbox
        let store = f.store
        // The upsert waits for the first (empty) value, so it can't land before the observer starts.
        let (started, starting) = AsyncStream.makeStream(of: Void.self)
        let seen = try await withThrowingTaskGroup(of: Int?.self) { group in
            group.addTask {
                var iterator = store.observe(query).makeAsyncIterator()
                _ = await iterator.next()
                starting.yield()
                return await iterator.next()?.count
            }
            group.addTask {
                for await _ in started {
                    break
                }
                _ = try store.upsert([row(f.account.id, f.inbox.id, uid: 1)])
                try await Task.sleep(for: .seconds(10))
                return nil
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }
        #expect(seen == 1)
    }

    /// #19: a sender's address keeps its case; sorting by sender still ignores it.
    @Test func aSendersAddressKeepsItsCase() throws {
        let f = try Fixture()
        let id = try #require(try f.store.upsert([row(f.account.id, f.inbox.id, uid: 1, from: "Anna.Lind@Example.org")]).first)
        #expect(try f.store.message(id)?.from.email == "Anna.Lind@Example.org")
        try f.store.setOverride("anna.lind@example.org", .other)
        #expect(try f.store.message(id)?.inboxClass == .other)
    }
}
