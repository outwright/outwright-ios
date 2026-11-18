// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightModel
import OutwrightSync
import Testing

private func many(_ count: Int) -> String { "\(count) new messages" }

/// A push's notification, worded from the rows its Inbox update brought.
@Suite struct NewMailNoticeFromRowsTests {
    let account = AccountID(raw: UUID())

    @Test func oneMessage() {
        let notice = NewMailNotice([inboxRow(account, uid: 3)], accountName: "Anna", many: many)
        #expect(notice == NewMailNotice(title: "Bo", body: "Subject 3"))
    }

    @Test func severalNameTheNewest() {
        let rows = [inboxRow(account, uid: 9, name: "Cy"), inboxRow(account, uid: 4), inboxRow(account, uid: 2)]
        let notice = NewMailNotice(rows, accountName: "Anna", many: many)
        #expect(notice == NewMailNotice(title: "3 new messages", body: "Cy: Subject 9"))
    }

    @Test func anEncryptedMessageShowsNoSubject() {
        var secret = inboxRow(account, uid: 5)
        secret.subject = "Secret plans"
        secret.isProtected = true
        for rows in [[secret], [inboxRow(account, uid: 1), secret]] {
            let notice = NewMailNotice(rows, accountName: "Anna", protectedBody: "Encrypted message", many: many)
            #expect(notice?.body.contains("Secret plans") == false)
            #expect(notice?.title.contains("Secret plans") == false)
            #expect(notice?.body.hasSuffix("Encrypted message") == true)
        }
    }

    @Test func noNameFallsBackToTheAddressThenTheAccount() {
        #expect(NewMailNotice([inboxRow(account, uid: 1, name: nil)], accountName: "Anna", many: many)?.title
            == "bo@example.org")
        #expect(NewMailNotice([inboxRow(account, uid: 1, name: " ", email: "")], accountName: "Anna", many: many)?
            .title == "Anna")
    }

    @Test func noRowsNoNotice() {
        #expect(NewMailNotice([MessageRow](), accountName: "Anna", many: many) == nil)
    }
}
