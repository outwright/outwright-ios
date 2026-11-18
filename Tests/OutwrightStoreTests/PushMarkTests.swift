// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import GRDB
import OutwrightModel
import Testing

@testable import OutwrightStore

/// How far each pushed account's Inbox has been announced: a push marks the Inbox when it has no
/// mark, fetches, then claims what came above the mark.
@Suite struct PushMarkTests {
    /// The fixture's messages are dated from here on (`row`'s `minutes`).
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func add(_ f: Fixture, _ uid: UInt32, read: Bool = false, minutes: Double = 0) throws {
        _ = try f.store.upsert([row(f.account.id, f.inbox.id, uid: uid, minutes: minutes, read: read)])
    }

    private func claimed(_ f: Fixture) throws -> [UInt32] {
        try f.store.claimPushedInboxMail(f.account.id, now: now).map(\.uid)
    }

    @Test func theFirstMarkHidesWhatIsThere() throws {
        let f = try Fixture()
        for uid in 1...3 { try add(f, UInt32(uid)) }
        try f.store.markPushedInboxIfNew(f.account.id, now: now)
        #expect(try claimed(f).isEmpty)
    }

    @Test func claimsOnlyNewUnreadAboveTheMark() throws {
        let f = try Fixture()
        try add(f, 1)
        try f.store.markPushedInboxIfNew(f.account.id, now: now)
        try add(f, 2)
        try add(f, 3, read: true)
        try add(f, 4)
        #expect(try claimed(f) == [2, 4])
    }

    @Test func aSecondClaimIsEmpty() throws {
        let f = try Fixture()
        try f.store.markPushedInboxIfNew(f.account.id, now: now)
        try add(f, 1)
        #expect(try claimed(f) == [1])
        #expect(try claimed(f).isEmpty)
    }

    @Test func markingAgainDoesNotMoveTheMark() throws {
        let f = try Fixture()
        try f.store.markPushedInboxIfNew(f.account.id, now: now)
        try add(f, 1)
        try f.store.markPushedInboxIfNew(f.account.id, now: now)
        #expect(try claimed(f) == [1])
    }

    @Test func movingMarksCoversPushedAccounts() throws {
        let f = try Fixture()
        try f.store.markPushedInboxIfNew(f.account.id, now: now)
        try add(f, 1)
        try f.store.moveNewMailMarks(now: now)
        #expect(try claimed(f).isEmpty)
        try add(f, 2)
        #expect(try claimed(f) == [2])
    }

    @Test func aPushMarkIsNotLocalNotices() throws {
        let f = try Fixture()
        try f.store.markPushedInboxIfNew(f.account.id, now: now)
        #expect(try !f.store.notifiesNewMail(f.account.id))
        #expect(try f.store.newMailNoticeAccounts().isEmpty)
        #expect(try f.store.claimNewInboxMail(f.account.id, now: now).isEmpty)
    }

    @Test func oldMailBroughtInLateIsNotClaimed() throws {
        let f = try Fixture()
        try f.store.markPushedInboxIfNew(f.account.id, now: now)
        try add(f, 1, minutes: -120)
        try add(f, 2, minutes: -5)
        #expect(try claimed(f) == [2])
    }

    @Test func deletingTheAccountRemovesItsMark() throws {
        let f = try Fixture()
        try f.store.markPushedInboxIfNew(f.account.id, now: now)
        try f.store.removeAccount(f.account.id)
        #expect(try f.store.queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM push_mail_mark") } == 0)
    }
}
