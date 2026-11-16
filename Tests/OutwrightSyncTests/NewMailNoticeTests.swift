// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightSync
import Testing

private func many(_ count: Int) -> String { "\(count) new messages" }

@Suite struct NewMailNoticeTests {
    @Test func oneMessageShowsSenderAndSubject() {
        let notice = NewMailNotice(
            .mail([NewMail(sender: "Bo", subject: "Lunch?")], count: 1), accountName: "Anna", many: many)
        #expect(notice == NewMailNotice(title: "Bo", body: "Lunch?"))
    }

    @Test func severalMessagesShowTheCountAndTheNewest() {
        let mail = [NewMail(sender: "Bo", subject: "Second"), NewMail(sender: "Cy", subject: "First")]
        let notice = NewMailNotice(.mail(mail, count: 7), accountName: "Anna", many: many)
        #expect(notice == NewMailNotice(title: "7 new messages", body: "Bo: Second"))
    }

    @Test func noSenderFallsBackToTheAccount() {
        let notice = NewMailNotice(
            .mail([NewMail(sender: "", subject: "Hej")], count: 1), accountName: "Anna", many: many)
        #expect(notice?.title == "Anna")
    }

    @Test func nothingOrFailureKeepsTheGenericText() {
        #expect(NewMailNotice(.nothing, accountName: "Anna", many: many) == nil)
        #expect(NewMailNotice(.failed, accountName: "Anna", many: many) == nil)
        #expect(NewMailNotice(.mail([], count: 0), accountName: "Anna", many: many) == nil)
    }
}
