// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightModel
import Testing

@testable import OutwrightUI

/// A tapped new-mail notice names its message in `userInfo`, as `SystemNewMailNotices` writes it.
@Suite struct MessageRequestTests {
    @Test func aNumberNamesTheMessage() {
        #expect(MessageRequest(userInfo: ["message": Int64(7)])?.message == MessageID(raw: 7))
    }

    @Test func anIntNamesTheMessageToo() {
        #expect(MessageRequest(userInfo: ["message": 7])?.message == MessageID(raw: 7))
    }

    @Test func nothingNamesNoMessage() {
        #expect(MessageRequest(userInfo: [:]) == nil)
    }

    /// The summary of many names only its account: its Inbox opens.
    @Test func anAccountAloneNamesItsInbox() {
        let id = UUID()
        let request = MessageRequest(userInfo: ["account": id.uuidString])
        #expect(request?.message == nil)
        #expect(request?.account == AccountID(raw: id))
    }

    @Test func textIsNoMessage() {
        #expect(MessageRequest(userInfo: ["message": "x"]) == nil)
    }
}
