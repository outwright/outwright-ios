// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightMIME
import OutwrightModel
import OutwrightStore
import Testing

@testable import OutwrightUI

@MainActor @Suite struct InboxPagingTests {
    private func count(_ model: InboxModel) -> Int {
        model.sections.reduce(0) { $0 + $1.rows.count }
    }

    @Test func theEndOfTheListShowsMoreOfWhatIsHeldBeforeAskingTheServer() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        for uid in 1...(InboxModel.page + 50) {
            _ = try box.add(anna, uid: UInt32(uid), date: Date(timeIntervalSince1970: 1_800_000_000 - Double(uid) * 60))
        }
        var asked = 0
        let model = InboxModel(store: box.store, scope: .allAccounts, olderFetcher: { _ in asked += 1; return true })
        #expect(count(model) == InboxModel.page)
        await model.loadMore()
        #expect(count(model) == InboxModel.page + 50)
        #expect(asked == 0, "what the phone holds comes first")
    }

    @Test func pastWhatIsHeldOlderMailIsFetchedUntilTheServerHasNoMore() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        _ = try box.add(anna, uid: 10, date: Date(timeIntervalSince1970: 1_800_000_000))
        var asked: [InboxScope] = []
        var older: UInt32 = 9
        let store = box.store
        let inbox = try box.folder(anna, .inbox)
        let model = InboxModel(store: store, scope: .allAccounts, olderFetcher: { scope in
            asked.append(scope)
            let row = MessageRow(
                id: MessageID(raw: 0), accountID: anna.id, folderID: inbox.id, uid: older,
                threadID: ThreadID(raw: "old\(older)"), from: Address(name: "Bo", email: "bo@example.org"),
                to: [], cc: [], subject: "Old", preview: "", date: Date(timeIntervalSince1970: 1_700_000_000),
                isRead: true, isFlagged: false, hasAttachment: false, isInvitation: false, inboxClass: .focused,
                hasBody: false, threadCount: 1)
            _ = try? store.upsert([row])
            older -= 1
            return older > 7
        })
        await model.loadMore()
        #expect(count(model) == 2)
        #expect(asked == [.allAccounts])
        await model.loadMore()
        #expect(count(model) == 3)
        await model.loadMore()
        #expect(asked.count == 2, "the server said nothing older is left")
        #expect(!model.isLoadingOlder)
    }

    @Test func anotherListStartsOverAtOnePage() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        var asked = 0
        let model = InboxModel(store: box.store, scope: .allAccounts, olderFetcher: { _ in asked += 1; return false })
        await model.loadMore()
        await model.loadMore()
        #expect(asked == 1)
        model.scope = .folder(try box.folder(anna, .sent).id)
        await model.loadMore()
        #expect(asked == 2, "a new list may have older mail again")
    }
}
