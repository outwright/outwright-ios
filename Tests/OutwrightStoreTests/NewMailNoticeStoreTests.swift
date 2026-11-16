// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import GRDB
import OutwrightModel
import Testing

@testable import OutwrightStore

@Suite struct NewMailNoticeStoreTests {
    /// The fixture's messages are dated from here on (`row`'s `minutes`).
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func add(
        _ f: Fixture, _ uid: UInt32, read: Bool = false, folder: FolderID? = nil, minutes: Double = 0
    ) throws {
        _ = try f.store.upsert([row(f.account.id, folder ?? f.inbox.id, uid: uid, minutes: minutes, read: read)])
    }

    private func claimed(_ f: Fixture) throws -> [UInt32] {
        try f.store.claimNewInboxMail(f.account.id, now: now).map(\.uid)
    }

    @Test func switchingOnAnnouncesNothingAlreadyThere() throws {
        let f = try Fixture()
        for uid in 1...3 { try add(f, UInt32(uid)) }
        try f.store.setNotifiesNewMail(true, for: f.account.id, now: now)
        #expect(try f.store.notifiesNewMail(f.account.id))
        #expect(try claimed(f).isEmpty)
    }

    @Test func newUnreadMailIsClaimedOnce() throws {
        let f = try Fixture()
        for uid in 1...3 { try add(f, UInt32(uid)) }
        try f.store.setNotifiesNewMail(true, for: f.account.id, now: now)
        try add(f, 4)
        try add(f, 5, read: true)
        try add(f, 6)
        #expect(try claimed(f) == [4, 6])
        #expect(try claimed(f).isEmpty)
    }

    @Test func readMailMovesTheMarkToo() throws {
        let f = try Fixture()
        try f.store.setNotifiesNewMail(true, for: f.account.id, now: now)
        try add(f, 4, read: true)
        #expect(try claimed(f).isEmpty)
        try add(f, 5)
        #expect(try claimed(f) == [5])
    }

    @Test func changedUIDValidityAnnouncesNothing() throws {
        let f = try Fixture()
        try add(f, 7)
        try f.store.setNotifiesNewMail(true, for: f.account.id, now: now)
        try f.store.resetFolder(f.inbox.id, uidValidity: 99)
        try add(f, 1)
        #expect(try claimed(f).isEmpty)
        try add(f, 2)
        #expect(try claimed(f) == [2])
    }

    @Test func emptyInboxThenFirstMailIsAnnounced() throws {
        let f = try Fixture()
        try f.store.setNotifiesNewMail(true, for: f.account.id, now: now)
        try add(f, 1)
        #expect(try claimed(f) == [1])
    }

    @Test func offForgetsTheMark() throws {
        let f = try Fixture()
        try f.store.setNotifiesNewMail(true, for: f.account.id, now: now)
        try f.store.setNotifiesNewMail(false, for: f.account.id)
        try add(f, 1)
        #expect(try !f.store.notifiesNewMail(f.account.id))
        #expect(try claimed(f).isEmpty)
    }

    @Test func movingMarksSkipsWhatIsThere() throws {
        let f = try Fixture()
        try f.store.setNotifiesNewMail(true, for: f.account.id, now: now)
        try add(f, 4)
        try f.store.moveNewMailMarks(now: now)
        #expect(try claimed(f).isEmpty)
        try add(f, 5)
        #expect(try claimed(f) == [5])
    }

    @Test func deletingTheAccountRemovesItsMark() throws {
        let f = try Fixture()
        try f.store.setNotifiesNewMail(true, for: f.account.id, now: now)
        try f.store.removeAccount(f.account.id)
        let rows = try f.store.queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM new_mail_notice") }
        #expect(rows == 0)
    }

    @Test func otherFoldersAreIgnored() throws {
        let f = try Fixture()
        try f.store.setNotifiesNewMail(true, for: f.account.id, now: now)
        let archive = try #require(try f.store.folders(f.account.id).first { $0.kind == .archive })
        try add(f, 9, folder: archive.id)
        #expect(try claimed(f).isEmpty)
    }

    /// A first sync cut short holds only part of the Inbox; what the next one brings in has higher
    /// uids but is old mail, and is never announced.
    @Test func oldMailFetchedAfterTheMarkIsNotAnnounced() throws {
        let f = try Fixture()
        try add(f, 100, minutes: -10_000)
        try f.store.setNotifiesNewMail(true, for: f.account.id, now: now)
        try add(f, 101, minutes: -9_000)
        try add(f, 102, minutes: -61)
        try add(f, 103, minutes: -30)
        #expect(try claimed(f) == [103])
    }

    @Test func accountsWithNoticesOnAreListed() throws {
        let f = try Fixture()
        #expect(try f.store.newMailNoticeAccounts().isEmpty)
        try f.store.setNotifiesNewMail(true, for: f.account.id, now: now)
        #expect(try f.store.newMailNoticeAccounts() == [f.account.id])
    }
}
