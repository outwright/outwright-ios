// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightModel
import OutwrightStore
import Synchronization
import Testing

@testable import OutwrightSync

/// Collects what would be posted.
final class RecordingNotices: NewMailNotices, Sendable {
    private struct Badges {
        var shown: [Int] = []
        /// Who waits for the badge to show a number, resumed when it does.
        var waiting: [(count: Int, resume: CheckedContinuation<Void, Never>)] = []
    }

    private let posted = Mutex<[LocalMailNotice]>([])
    private let badges = Mutex(Badges())
    var all: [LocalMailNotice] { posted.withLock { $0 } }
    var badge: Int? { badges.withLock { $0.shown.last } }
    func post(_ notices: [LocalMailNotice]) async { posted.withLock { $0 += notices } }

    func setBadge(_ count: Int) async {
        let ready = badges.withLock { badges in
            badges.shown.append(count)
            let ready = badges.waiting.filter { $0.count == count }
            badges.waiting.removeAll { $0.count == count }
            return ready
        }
        for waiter in ready { waiter.resume.resume() }
    }

    /// Returns once the badge shows `count`: at once when it does, otherwise when it is set to it.
    func badgeShows(_ count: Int) async {
        await withCheckedContinuation { continuation in
            let now = badges.withLock { badges in
                guard badges.shown.last != count else { return true }
                badges.waiting.append((count, continuation))
                return false
            }
            if now { continuation.resume() }
        }
    }
}

@Suite struct AnnounceNewMailTests {
    /// `inboxRow`'s messages are dated here.
    static let now = Date(timeIntervalSince1970: 1_700_000_000)

    private struct Setup {
        let store: MailStore
        let account: Account
        let inbox: FolderID
        let notices = RecordingNotices()
        let coordinator: SyncCoordinator

        init() throws {
            store = try MailStore(path: nil)
            account = Harness.account(imapPort: 1, smtpPort: 1)
            try store.save(account)
            try store.replaceFolders(
                [Folder(
                    id: FolderID(raw: 0), accountID: account.id, path: "INBOX", name: "INBOX", kind: .inbox,
                    uidValidity: 1, unread: 0, isFavorite: false)],
                for: account.id)
            inbox = try #require(try store.folders(account.id).first).id
            coordinator = SyncCoordinator(
                store: store, secrets: InMemorySecretStore(), now: { AnnounceNewMailTests.now }, resolver: FakeDoH(),
                davSession: URLSession(configuration: .ephemeral), probe: { _ in nil },
                reminders: RecordingReminders(), newMail: notices)
        }

        func on() throws {
            try store.setNotifiesNewMail(true, for: account.id, now: AnnounceNewMailTests.now)
        }

        func add(_ uid: UInt32, inboxClass: InboxClass = .focused) throws {
            var row = inboxRow(account.id, uid: uid, inboxClass: inboxClass)
            row.folderID = inbox
            row.id = MessageID(raw: 0)
            _ = try store.upsert([row])
        }
    }

    @Test func newMailIsPostedOnePerMessage() async throws {
        let s = try Setup()
        try s.on()
        try s.add(1)
        try s.add(2)
        await s.coordinator.announceNewMail(skipping: [], focusedOnly: false) { "\($0)" }
        #expect(s.notices.all.map(\.body) == ["Subject 1", "Subject 2"])
    }

    /// With Focused Inbox on, only Focused mail notifies, as in Outlook.
    @Test func focusedOnlyLeavesOtherMailQuiet() async throws {
        let s = try Setup()
        try s.on()
        try s.add(1, inboxClass: .other)
        try s.add(2)
        await s.coordinator.announceNewMail(skipping: [], focusedOnly: true) { "\($0)" }
        #expect(s.notices.all.map(\.body) == ["Subject 2"])
    }

    @Test func withoutFocusedInboxOtherMailNotifiesToo() async throws {
        let s = try Setup()
        try s.on()
        try s.add(1, inboxClass: .other)
        await s.coordinator.announceNewMail(skipping: [], focusedOnly: false) { "\($0)" }
        #expect(s.notices.all.map(\.body) == ["Subject 1"])
    }

    @Test func anAccountWithPushIsLeftToPush() async throws {
        let s = try Setup()
        try s.on()
        try s.add(1)
        await s.coordinator.announceNewMail(skipping: [s.account.id], focusedOnly: false) { "\($0)" }
        #expect(s.notices.all.isEmpty)
    }

    @Test func anAccountWithNoticesOffPostsNothing() async throws {
        let s = try Setup()
        try s.add(1)
        await s.coordinator.announceNewMail(skipping: [], focusedOnly: false) { "\($0)" }
        #expect(s.notices.all.isEmpty)
    }

    @Test func movedMarksPostNothing() async throws {
        let s = try Setup()
        try s.on()
        try s.add(1)
        try s.store.moveNewMailMarks(now: AnnounceNewMailTests.now)
        await s.coordinator.announceNewMail(skipping: [], focusedOnly: false) { "\($0)" }
        #expect(s.notices.all.isEmpty)
    }

    @Test func noticeIsNotScheduledWhileDoNotDisturb() async throws {
        let s = try Setup()
        try s.on()
        try s.add(1)
        let silent = DoNotDisturb.untilOneHour(from: Date())
        await s.coordinator.announceNewMail(skipping: [], focusedOnly: false, doNotDisturb: silent) { "\($0) more" }
        #expect(s.notices.all.isEmpty)
    }

    /// Do Not Disturb is judged by the coordinator's clock, like the claim of the mail.
    @Test func doNotDisturbFollowsTheCoordinatorsClock() async throws {
        let s = try Setup()
        try s.on()
        try s.add(1)
        let silent = DoNotDisturb.untilOneHour(from: AnnounceNewMailTests.now)
        await s.coordinator.announceNewMail(skipping: [], focusedOnly: false, doNotDisturb: silent) { "\($0) more" }
        #expect(s.notices.all.isEmpty)
    }

    /// The app icon shows the unread Inbox mail, and follows it as mail comes and is read.
    /// Waits on the badge itself, never on a clock: under a full run's load a change can take
    /// seconds to arrive. The time limit only ends a badge that never comes.
    @Test(.timeLimit(.minutes(1))) func theBadgeFollowsTheUnreadInboxMail() async throws {
        let s = try Setup()
        let coordinator = s.coordinator
        let watching = Task { await coordinator.showBadge(focusedOnly: true) }
        defer { watching.cancel() }
        await s.notices.badgeShows(0)
        try s.add(1)
        try s.add(2, inboxClass: .other)
        await s.notices.badgeShows(1)
        let id = try #require(try s.store.folderIndex(s.inbox)[1])
        try s.store.updateFlags(id, isRead: true, isFlagged: false)
        await s.notices.badgeShows(0)
        #expect(s.notices.badge == 0)
    }
}
