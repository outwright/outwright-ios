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

    private func defaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "inbox-\(UUID().uuidString)"))
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

    @Test func swipeSettingDrivesTheRowAction() throws {
        let box = try Mailbox()
        let defaults = try #require(UserDefaults(suiteName: "inbox-\(UUID().uuidString)"))
        let model = InboxModel(store: box.store, scope: .allAccounts, defaults: defaults)
        #expect(model.swipeAction(.leading) == .flag)
        #expect(model.swipeAction(.trailing) == .delete)
        defaults.set(SwipeAction.archive.rawValue, forKey: SettingsKeys.swipeLeading)
        defaults.set(SwipeAction.none.rawValue, forKey: SettingsKeys.swipeTrailing)
        #expect(model.swipeAction(.leading) == .archive)
        #expect(model.swipeAction(.trailing) == SwipeAction.none)
        defaults.set("nonsense", forKey: SettingsKeys.swipeLeading)
        #expect(model.swipeAction(.leading) == .flag)
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

    @Test func swipeLeftDeletesAndQueues() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let id = try box.add(anna, uid: 1)
        let model = InboxModel(store: box.store, scope: .allAccounts, defaults: try defaults())
        model.swipe(.trailing, on: id)
        #expect(ids(model).isEmpty)
        await model.pending.commit()
        #expect(try box.store.message(id)?.folderID == box.folder(anna, .trash).id)
        #expect(try box.store.pendingActions().map(\.action) == [.delete(id)])
    }

    @Test func swipeLeftOnAThreadDeletesTheConversation() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let older = try box.add(anna, uid: 1, thread: "t", date: Date(timeIntervalSince1970: 1_800_000_000))
        let newer = try box.add(anna, uid: 2, thread: "t", date: Date(timeIntervalSince1970: 1_800_000_060))
        let sent = try box.add(anna, .sent, uid: 3, thread: "t")
        let model = InboxModel(store: box.store, scope: .allAccounts, defaults: try defaults())
        #expect(ids(model) == [newer])
        model.swipe(.trailing, on: newer)
        #expect(ids(model).isEmpty)
        await model.pending.commit()
        let trash = try box.folder(anna, .trash).id
        #expect(try box.store.message(older)?.folderID == trash)
        #expect(try box.store.message(newer)?.folderID == trash)
        #expect(try box.store.message(sent)?.folderID == box.folder(anna, .sent).id)
    }

    @Test func swipeRightTogglesFlag() throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let id = try box.add(anna, uid: 1)
        let model = InboxModel(store: box.store, scope: .allAccounts, defaults: try defaults())
        model.swipe(.leading, on: id)
        #expect(model.sections.flatMap(\.rows).first?.isFlagged == true)
        model.swipe(.leading, on: id)
        #expect(model.sections.flatMap(\.rows).first?.isFlagged == false)
        #expect(try box.store.pendingActions().map(\.action) == [.setFlagged(id, true), .setFlagged(id, false)])
    }

    @Test func deleteInTrashIsNotStaged() throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let id = try box.add(anna, .trash, uid: 1)
        let inbox = InboxModel(store: box.store, scope: .folder(try box.folder(anna, .inbox).id))
        #expect(!inbox.needsConfirmation(for: .delete))
        let model = InboxModel(store: box.store, scope: .folder(try box.folder(anna, .trash).id))
        #expect(model.needsConfirmation(for: .delete))
        #expect(!model.needsConfirmation(for: .archive))
        model.deleteForGood([id])
        #expect(model.pending.current == nil)
        #expect(try box.store.message(id) == nil)
        #expect(ids(model).isEmpty)
    }

    @Test func markAllReadMarksTheFolder() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let older = try box.add(anna, uid: 1, thread: "t", date: Date(timeIntervalSince1970: 1_800_000_000))
        let newer = try box.add(anna, uid: 2, thread: "t", date: Date(timeIntervalSince1970: 1_800_000_060))
        let other = try box.add(anna, uid: 3, cls: .other)
        let archived = try box.add(anna, .archive, uid: 4)
        let inbox = try box.folder(anna, .inbox).id
        let model = InboxModel(store: box.store, scope: .folder(inbox), defaults: try defaults())
        model.markAllRead()
        for id in [older, newer, other] {
            #expect(try box.store.message(id)?.isRead == true)
        }
        #expect(try box.store.message(archived)?.isRead == false)
        #expect(model.sections.flatMap(\.rows).allSatisfy { $0.isRead })
    }

    @Test func allAccountsShowsEveryInbox() throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let bert = try box.addAccount("bo@example.org")
        let first = try box.add(anna, uid: 1)
        let second = try box.add(bert, uid: 1)
        try box.add(bert, .sent, uid: 2)
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
