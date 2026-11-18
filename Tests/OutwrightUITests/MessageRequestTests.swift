// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightModel
import OutwrightSync
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

/// A push's notification names its mail as a local notice does, so a tap opens it.
@Suite struct PushTapTests {
    let account = AccountID(raw: UUID())

    @Test func userInfoNamesAccountAndMessage() {
        let request = MessageRequest(userInfo: NewMailPlan.userInfo(account: account, message: MessageID(raw: 42)))
        #expect(request == MessageRequest(message: MessageID(raw: 42), account: account))
    }

    @Test func userInfoWithoutAMessageNamesTheAccount() {
        let request = MessageRequest(userInfo: NewMailPlan.userInfo(account: account, message: nil))
        #expect(request == MessageRequest(message: nil, account: account))
    }

    @Test func aPushIsNewMail() {
        var info: [AnyHashable: Any] = NewMailPlan.userInfo(account: account, message: MessageID(raw: 42))
        info["s"] = "sub-1"
        info["aps"] = ["alert": ["loc-key": "push.newMail"]]
        #expect(NewMailPlan.isNewMail(identifier: "1F2E3D4C-APNS", userInfo: info))
        #expect(MessageRequest(userInfo: info)?.message == MessageID(raw: 42))
    }

    @Test func aLocalNoticeIsNewMailAndAReminderIsNot() {
        #expect(NewMailPlan.isNewMail(identifier: NewMailPlan.identifierPrefix + "x.4", userInfo: [:]))
        #expect(!NewMailPlan.isNewMail(identifier: "outwright.reminder.1", userInfo: ["event": "e"]))
    }
}
