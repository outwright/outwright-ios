// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightModel
import OutwrightStore
import Testing

@testable import OutwrightUI

/// The message shown beside the list on a wide phone, as the list changes under it.
@MainActor @Suite struct InboxSelectionTests {
    /// Three messages, newest first in the list: `first`, `middle`, `last`.
    private struct Three {
        var box: Mailbox
        let account: Account
        let first: MessageID
        let middle: MessageID
        let last: MessageID

        init() throws {
            var box = try Mailbox()
            account = try box.addAccount("anna@example.org")
            last = try box.add(account, uid: 1, date: Date(timeIntervalSince1970: 1_800_000_000), read: true)
            middle = try box.add(account, uid: 2, date: Date(timeIntervalSince1970: 1_800_000_060))
            first = try box.add(account, uid: 3, date: Date(timeIntervalSince1970: 1_800_000_120), read: true)
            self.box = box
        }
    }

    @Test func deletingTheSelectedMessageSelectsTheNext() throws {
        let three = try Three()
        let model = InboxModel(store: three.box.store, scope: .allAccounts)
        model.selected = three.middle
        model.swipeLeft(three.middle)
        #expect(model.selected == three.last)
    }

    @Test func deletingTheLastSelectsThePrevious() throws {
        let three = try Three()
        let model = InboxModel(store: three.box.store, scope: .allAccounts)
        model.selected = three.last
        model.swipeLeft(three.last)
        #expect(model.selected == three.middle)
    }

    @Test func aFilterThatHidesTheSelectionMovesIt() throws {
        let three = try Three()
        let model = InboxModel(store: three.box.store, scope: .allAccounts)
        model.selected = three.first
        model.filter = .unread
        #expect(model.selected == three.middle)
    }

    @Test func changingScopeClearsTheSelection() throws {
        let three = try Three()
        let model = InboxModel(store: three.box.store, scope: .allAccounts)
        model.selected = three.first
        model.scope = .folder(try three.box.folder(three.account, .inbox).id)
        #expect(model.selected == nil)
    }

    @Test func readingUnderTheUnreadFilterKeepsTheMessageShown() throws {
        let three = try Three()
        _ = try three.box.store.apply(.setRead(three.first, false))
        _ = try three.box.store.apply(.setRead(three.last, false))
        let model = InboxModel(store: three.box.store, scope: .allAccounts)
        model.filter = .unread
        model.selected = three.first
        // Opening it marks it read: it stays in the list and selected, and nothing else is opened.
        _ = try three.box.store.apply(.setRead(three.first, true))
        model.reload()
        #expect(model.selected == three.first)
        #expect(model.shows(three.first))
    }

    @Test func aReplyInTheOpenConversationKeepsIt() throws {
        var box = try Mailbox()
        let account = try box.addAccount("anna@example.org")
        let other = try box.add(account, uid: 1, thread: "b", date: Date(timeIntervalSince1970: 1_800_000_000))
        let open = try box.add(account, uid: 2, thread: "a", date: Date(timeIntervalSince1970: 1_800_000_060))
        let model = InboxModel(store: box.store, scope: .allAccounts)
        model.selected = open
        let reply = try box.add(account, uid: 3, thread: "a", date: Date(timeIntervalSince1970: 1_800_000_120))
        model.reload()
        #expect(model.selected == reply)
        _ = other
    }

    @Test func aNewMessageKeepsTheSelection() throws {
        let three = try Three()
        let model = InboxModel(store: three.box.store, scope: .allAccounts)
        model.selected = three.middle
        _ = try three.box.add(three.account, uid: 4, date: Date(timeIntervalSince1970: 1_800_000_180))
        model.reload()
        #expect(model.selected == three.middle)
    }
}

/// A message kept in a filtered list while it is read goes when the owner changes where it belongs,
/// and when another message is opened.
@MainActor @Suite struct KeptMessageTests {
    /// Two unread Inbox messages, under the Unread filter with Focused shown, `open` read and kept.
    @MainActor private struct Kept {
        var box: Mailbox
        let account: Account
        let open: MessageID
        let next: MessageID
        let model: InboxModel

        init() throws {
            var box = try Mailbox()
            account = try box.addAccount("anna@example.org")
            next = try box.add(account, uid: 1, from: "cia@example.org", date: Date(timeIntervalSince1970: 1_800_000_000))
            open = try box.add(account, uid: 2, date: Date(timeIntervalSince1970: 1_800_000_060))
            let defaults = try #require(UserDefaults(suiteName: "kept-\(UUID().uuidString)"))
            model = InboxModel(store: box.store, scope: .allAccounts, defaults: defaults)
            model.filter = .unread
            model.selected = open
            _ = try box.store.apply(.setRead(open, true))
            model.reload()
            self.box = box
        }
    }

    @Test func theKeptMessageStaysAcrossReloads() throws {
        let kept = try Kept()
        kept.model.reload()
        #expect(kept.model.shows(kept.open))
        #expect(kept.model.selected == kept.open)
    }

    @Test func movingTheKeptMessageToAnotherFolderDropsIt() throws {
        let kept = try Kept()
        _ = try kept.box.store.apply(.move(kept.open, to: .archive))
        kept.model.reload()
        #expect(!kept.model.shows(kept.open))
        #expect(kept.model.selected == kept.next)
    }

    @Test func movingTheKeptMessageToOtherDropsIt() throws {
        let kept = try Kept()
        try kept.box.store.setOverride("bo@example.org", .other)
        kept.model.reload()
        #expect(!kept.model.shows(kept.open))
        #expect(kept.model.selected == kept.next)
    }

    @Test func openingAnotherMessageDropsTheKeptOne() throws {
        let kept = try Kept()
        kept.model.selected = kept.next
        kept.model.reload()
        #expect(!kept.model.shows(kept.open))
    }
}
