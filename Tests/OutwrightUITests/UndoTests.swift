// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightModel
import OutwrightStore
import OutwrightSync
import Testing

@testable import OutwrightUI

/// A move or delete waits out the undo window before it reaches the store; meanwhile its rows are hidden.
@MainActor @Suite struct UndoTests {
    private func ids(_ model: InboxModel) -> Set<MessageID> {
        Set(model.sections.flatMap(\.rows).map(\.id))
    }

    private func defaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "undo-\(UUID().uuidString)"))
    }

    @Test func stagedDeleteHidesRowsAndUndoBringsThemBack() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let id = try box.add(anna, uid: 1)
        let pending = PendingMail(store: box.store)
        let model = InboxModel(store: box.store, scope: .allAccounts, defaults: try defaults(), pending: pending)
        model.swipe(.trailing, on: id)
        #expect(ids(model).isEmpty)
        #expect(pending.current != nil)
        #expect(try box.store.message(id)?.folderID == box.folder(anna, .inbox).id)
        pending.undo()
        #expect(ids(model) == [id])
        #expect(pending.current == nil)
        #expect(try box.store.pendingActions().isEmpty)
    }

    @Test func stagedActionsReachTheStoreAfterTheWindow() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let id = try box.add(anna, uid: 1)
        let pending = PendingMail(store: box.store, sleep: { _ in })
        let model = InboxModel(store: box.store, scope: .allAccounts, defaults: try defaults(), pending: pending)
        model.swipe(.trailing, on: id)
        await pending.timer?.value
        #expect(pending.current == nil)
        #expect(try box.store.message(id)?.folderID == box.folder(anna, .trash).id)
        #expect(try box.store.pendingActions().map(\.action) == [.delete(id)])
        #expect(ids(model).isEmpty)
    }

    @Test func stagingASecondBatchCommitsTheFirst() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let first = try box.add(anna, uid: 1)
        let second = try box.add(anna, uid: 2)
        let pending = PendingMail(store: box.store)
        pending.stage([.delete(first)], hiding: [first], text: "Deleted")
        pending.stage([.move(second, to: .archive)], hiding: [second], text: "Archived")
        #expect(try box.store.message(first)?.folderID == box.folder(anna, .trash).id)
        #expect(try box.store.message(second)?.folderID == box.folder(anna, .inbox).id)
        #expect(pending.current?.hidden == [second])
    }

    @Test func flagIsMadeAtOnceWhileAnArchiveWaits() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let archived = try box.add(anna, uid: 1, date: Date(timeIntervalSince1970: 1_800_000_000))
        let flagged = try box.add(anna, uid: 2, date: Date(timeIntervalSince1970: 1_800_000_060))
        let pending = PendingMail(store: box.store)
        let model = InboxModel(store: box.store, scope: .allAccounts, defaults: try defaults(), pending: pending)
        model.archive([archived])
        model.beginSelecting(flagged)
        model.flagSelected()
        #expect(try box.store.message(flagged)?.isFlagged == true)
        #expect(try box.store.message(archived)?.folderID == box.folder(anna, .inbox).id)
        #expect(pending.current?.hidden == [archived])
        await pending.commit()
        #expect(try box.store.message(archived)?.folderID == box.folder(anna, .archive).id)
        #expect(try box.store.message(flagged)?.isFlagged == true)
    }

    @Test func aMessageGoneDuringTheWindowIsNoFailure() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let gone = try box.add(anna, uid: 1)
        let kept = try box.add(anna, uid: 2)
        let pending = PendingMail(store: box.store)
        pending.stage([.delete(gone), .delete(kept)], hiding: [gone, kept], text: "Deleted")
        try box.store.removeMessage(gone)
        await pending.commit()
        #expect(!pending.failed)
        #expect(try box.store.message(kept)?.folderID == box.folder(anna, .trash).id)
    }

    /// A batch whose commit the store refused stays a failure when the next batch is staged after it.
    @Test func aFailedCommitSurvivesTheNextStage() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let first = try box.add(anna, uid: 1)
        let second = try box.add(anna, uid: 2)
        let pending = PendingMail(store: box.store)
        pending.stage([.moveTo(first, FolderID(raw: 999_999))], hiding: [first], text: "Moved")
        pending.stage([.delete(second)], hiding: [second], text: "Deleted")
        #expect(pending.failed)
        pending.undo()
        #expect(!pending.failed)
    }

    /// A change made at once to a staged message (Mark all read here) commits its batch first; a
    /// refusal there is kept as one.
    @Test func aFailedCommitBeforeAChangeAtOnceIsKept() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let id = try box.add(anna, uid: 1)
        let pending = PendingMail(store: box.store)
        let model = InboxModel(store: box.store, scope: .allAccounts, defaults: try defaults(), pending: pending)
        pending.stage([.moveTo(id, FolderID(raw: 999_999))], hiding: [id], text: "Moved")
        model.markAllRead()
        #expect(pending.current == nil)
        #expect(pending.failed)
    }

    @Test func theDrawerLeavesOutStagedUnreadMessages() throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let unread = try box.add(anna, uid: 1)
        try box.add(anna, uid: 2)
        let inbox = try box.folder(anna, .inbox).id
        let pending = PendingMail(store: box.store)
        let drawer = DrawerModel(store: box.store, selected: anna.id, pending: pending)
        func inboxUnread() -> Int? {
            drawer.sections.last?.folders.first { $0.id == inbox }?.unread
        }
        #expect(inboxUnread() == 2)
        pending.stage([.move(unread, to: .archive)], hiding: [unread], text: "Archived")
        #expect(inboxUnread() == 1)
        pending.undo()
        #expect(inboxUnread() == 2)
    }

    @Test func goingToTheBackgroundCommits() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let id = try box.add(anna, uid: 1)
        let app = AppModel(store: box.store, sync: offlineSync(store: box.store, secrets: InMemorySecretStore()))
        app.pendingMail.stage([.move(id, to: .archive)], hiding: [id], text: "Archived")
        app.sceneChanged(toActive: false)
        #expect(app.pendingMail.current == nil)
        #expect(try box.store.message(id)?.folderID == box.folder(anna, .archive).id)
    }

    @Test func theReadingViewLeavesOutHiddenMessages() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let id = try box.add(anna, uid: 1, read: true)
        let pending = PendingMail(store: box.store)
        let thread = ThreadModel(store: box.store, message: id, pending: pending, fetchBody: { _ in })
        await thread.open()
        #expect(thread.items.map(\.id) == [id])
        pending.stage([.delete(id)], hiding: [id], text: "Deleted")
        #expect(thread.items.isEmpty)
        #expect(thread.isGone)
    }
}
