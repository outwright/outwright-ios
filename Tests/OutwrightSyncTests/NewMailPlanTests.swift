// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightMIME
import OutwrightModel
import Testing

@testable import OutwrightSync

func inboxRow(
    _ account: AccountID, uid: UInt32, name: String? = "Bo", email: String = "bo@example.org",
    inboxClass: InboxClass = .focused
) -> MessageRow {
    MessageRow(
        id: MessageID(raw: Int64(uid)), accountID: account, folderID: FolderID(raw: 1), uid: uid,
        threadID: ThreadID(raw: "t\(uid)"), from: Address(name: name, email: email), to: [], cc: [],
        subject: "Subject \(uid)", preview: "", date: Date(timeIntervalSince1970: 1_700_000_000), isRead: false,
        isFlagged: false, hasAttachment: false, isInvitation: false, inboxClass: inboxClass, hasBody: false,
        threadCount: 1)
}

@Suite struct NewMailPlanTests {
    let account = AccountID(raw: UUID())

    @Test func aProtectedMessageNeverShowsItsSubject() {
        var row = inboxRow(account, uid: 4)
        row.isProtected = true
        let notices = NewMailPlan.plan([row], accountName: "Home", protectedBody: "Krypterat") { "\($0) more" }
        #expect(notices.map(\.body) == ["Krypterat"])
    }

    @Test func oneMessageIsOneNotice() {
        let notices = NewMailPlan.plan([inboxRow(account, uid: 4)], accountName: "Home") { "\($0) more" }
        #expect(
            notices == [
                LocalMailNotice(
                    identifier: "outwright.mail.\(account.raw.uuidString).4", title: "Bo", body: "Subject 4",
                    account: account, message: MessageID(raw: 4))
            ])
    }

    @Test func aSenderWithoutANameShowsTheAddress() {
        let notices = NewMailPlan.plan([inboxRow(account, uid: 1, name: nil)], accountName: "Home") { "\($0)" }
        #expect(notices.map(\.title) == ["bo@example.org"])
    }

    @Test func aSenderWithNothingShowsTheAccount() {
        let notices = NewMailPlan.plan([inboxRow(account, uid: 1, name: " ", email: "")], accountName: "Home") { "\($0)" }
        #expect(notices.map(\.title) == ["Home"])
    }

    /// iOS stacks the last posted on top: the summary goes first, then the newest ten oldest first.
    @Test func moreThanTenGiveTheSummaryThenTheNewestTenOldestFirst() {
        let rows = (1...12).map { inboxRow(account, uid: UInt32($0)) }
        let notices = NewMailPlan.plan(rows, accountName: "Home") { "\($0) more" }
        #expect(notices.count == 11)
        let summary = notices.first
        #expect(summary?.title == "2 more")
        #expect(summary?.message == nil)
        #expect(summary?.identifier == "outwright.mail.\(account.raw.uuidString).more.12")
        #expect(notices.dropFirst().compactMap(\.message).map(\.raw) == Array(3...12).map(Int64.init))
    }

    @Test func nothingNewIsNoNotice() {
        #expect(NewMailPlan.plan([], accountName: "Home") { "\($0)" }.isEmpty)
    }
}
