// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightModel
import OutwrightStore
import Testing

@testable import OutwrightUI

@MainActor @Suite struct InboxModelTests {
    private func ids(_ model: InboxModel) -> Set<MessageID> {
        Set(model.sections.flatMap(\.rows).map(\.id))
    }

    @Test func focusedInboxOffShowsEverything() throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let focused = try box.add(anna, uid: 1, cls: .focused)
        let other = try box.add(anna, uid: 2, cls: .other)
        let defaults = try #require(UserDefaults(suiteName: "inbox-\(UUID().uuidString)"))
        defaults.set(false, forKey: SettingsKeys.focusedInbox)
        let model = InboxModel(store: box.store, scope: .allAccounts, defaults: defaults)
        #expect(!model.showsFocusedOther)
        #expect(ids(model) == [focused, other])
        model.isFocusedInboxOn = true
        #expect(model.showsFocusedOther)
        #expect(ids(model) == [focused])
    }

    @Test func switchingToOtherShowsOnlyOther() throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let focused = try box.add(anna, uid: 1, cls: .focused)
        let other = try box.add(anna, uid: 2, cls: .other)
        let model = InboxModel(store: box.store, scope: .allAccounts)
        #expect(ids(model) == [focused])
        model.inboxClass = .other
        #expect(ids(model) == [other])
    }

    @Test func swipeLeftDeletesAndQueues() throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let id = try box.add(anna, uid: 1)
        let model = InboxModel(store: box.store, scope: .allAccounts)
        model.swipeLeft(id)
        #expect(ids(model).isEmpty)
        #expect(try box.store.message(id)?.folderID == box.folder(anna, .trash).id)
        #expect(try box.store.pendingActions().map(\.action) == [.delete(id)])
    }

    @Test func swipeLeftOnAThreadDeletesTheConversation() throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let older = try box.add(anna, uid: 1, thread: "t", date: Date(timeIntervalSince1970: 1_800_000_000))
        let newer = try box.add(anna, uid: 2, thread: "t", date: Date(timeIntervalSince1970: 1_800_000_060))
        let sent = try box.add(anna, .sent, uid: 3, thread: "t")
        let model = InboxModel(store: box.store, scope: .allAccounts)
        #expect(ids(model) == [newer])
        model.swipeLeft(newer)
        #expect(ids(model).isEmpty)
        let trash = try box.folder(anna, .trash).id
        #expect(try box.store.message(older)?.folderID == trash)
        #expect(try box.store.message(newer)?.folderID == trash)
        #expect(try box.store.message(sent)?.folderID == box.folder(anna, .sent).id)
    }

    @Test func swipeRightTogglesFlag() throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let id = try box.add(anna, uid: 1)
        let model = InboxModel(store: box.store, scope: .allAccounts)
        model.swipeRight(id)
        #expect(model.sections.flatMap(\.rows).first?.isFlagged == true)
        model.swipeRight(id)
        #expect(model.sections.flatMap(\.rows).first?.isFlagged == false)
        #expect(try box.store.pendingActions().map(\.action) == [.setFlagged(id, true), .setFlagged(id, false)])
    }

    @Test func allAccountsShowsEveryInbox() throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let bo = try box.addAccount("bo@example.org")
        let first = try box.add(anna, uid: 1)
        let second = try box.add(bo, uid: 1)
        try box.add(bo, .sent, uid: 2)
        let model = InboxModel(store: box.store, scope: .allAccounts)
        #expect(ids(model) == [first, second])
        let annaInbox = try box.folder(anna, .inbox)
        model.scope = .folder(annaInbox.id)
        #expect(ids(model) == [first])
    }

    @Test func otherFoldersIgnoreFocusedAndOther() throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let sent = try box.add(anna, .sent, uid: 1, cls: .other)
        let model = InboxModel(store: box.store, scope: .folder(try box.folder(anna, .sent).id))
        #expect(!model.showsFocusedOther)
        #expect(ids(model) == [sent])
    }

    @Test func refreshRunsTheRefresherAndReloads() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let store = box.store
        let inbox = try box.folder(anna, .inbox)
        let model = InboxModel(store: store, scope: .allAccounts, refresher: {
            let row = MessageRow(
                id: MessageID(raw: 0), accountID: anna.id, folderID: inbox.id, uid: 9, threadID: ThreadID(raw: "n"),
                from: .init(name: nil, email: "c@example.org"), to: [], cc: [], subject: "New", preview: "",
                date: Date(), isRead: false, isFlagged: false, hasAttachment: false, isInvitation: false,
                inboxClass: .focused, hasBody: false, threadCount: 1)
            _ = try? store.upsert([row])
        })
        #expect(ids(model).isEmpty)
        await model.refresh()
        #expect(ids(model).count == 1)
    }
}
