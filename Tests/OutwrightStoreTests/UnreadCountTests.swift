// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightModel
import Testing

@testable import OutwrightStore

/// The app icon's badge: the unread mail in every account's Inbox, only Focused when Focused
/// Inbox is on.
@Suite struct UnreadCountTests {
    @Test func countsUnreadInboxMailOfEveryAccount() throws {
        let f = try Fixture()
        let other = Fixture.makeAccount(name: "Bo", email: "bo@example.org", order: 1)
        try f.store.save(other)
        try f.store.replaceFolders(Fixture.folders(for: other.id), for: other.id)
        let otherInbox = try #require(try f.store.folders(other.id).first { $0.kind == .inbox })
        _ = try f.store.upsert([
            row(f.account.id, f.inbox.id, uid: 1),
            row(f.account.id, f.inbox.id, uid: 2, read: true),
            row(f.account.id, f.sent.id, uid: 3),
            row(other.id, otherInbox.id, uid: 1, cls: .other),
        ])
        #expect(try f.store.unreadInboxCount(focusedOnly: false) == 2)
        #expect(try f.store.unreadInboxCount(focusedOnly: true) == 1)
    }

    @Test func nothingUnreadIsZero() throws {
        #expect(try Fixture().store.unreadInboxCount(focusedOnly: false) == 0)
    }
}
