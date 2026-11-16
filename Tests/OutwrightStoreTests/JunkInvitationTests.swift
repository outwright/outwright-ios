// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import GRDB
import OutwrightModel
import Testing

@testable import OutwrightStore

/// An account with an Inbox, Junk, Trash and Archive, in `store`.
private func junkAccount(_ store: MailStore) throws -> (AccountID, [FolderKind: FolderID]) {
    let account = Fixture.makeAccount(name: "Anna", email: "anna@example.org", order: 0)
    try store.save(account)
    let junk = Folder(
        id: FolderID(raw: 0), accountID: account.id, path: "Junk", name: "Junk", kind: .junk, uidValidity: 1,
        unread: 0, isFavorite: false)
    try store.replaceFolders(Fixture.folders(for: account.id) + [junk], for: account.id)
    let folders = Dictionary(
        try store.folders(account.id).map { ($0.kind, $0.id) }, uniquingKeysWith: { first, _ in first })
    return (account.id, folders)
}

/// An invitation mail in `folder`, with its body, that the intake refused (nothing applied).
private func refusedInvitation(
    _ store: MailStore, _ account: AccountID, _ folder: FolderID, uid: UInt32,
    method: InvitationMethod = .request, applied: Bool = false
) throws -> MessageID {
    var invitation = row(account, folder, uid: uid)
    invitation.isInvitation = true
    let id = try #require(try store.upsert([invitation]).first)
    let body = [
        "From: bo@example.org", "Subject: Invitation", "Content-Type: text/calendar; charset=utf-8; method=REQUEST", "",
        "BEGIN:VCALENDAR", "METHOD:REQUEST", "END:VCALENDAR", "",
    ]
    try store.setBody(Data(body.joined(separator: "\r\n").utf8), for: id)
    try store.recordInvitation(
        message: id, method: method, uid: "u\(uid)", recurrenceID: nil, sequence: 0, event: nil, applied: applied)
    return id
}

@Suite struct JunkInvitationTests {
    /// Junk refuses an invitation; out of Junk it is an invitation like any other, taken again.
    @Test func anInvitationLeavingJunkIsTakenAgain() throws {
        let store = try MailStore(path: nil)
        let (account, folders) = try junkAccount(store)
        let junk = try #require(folders[.junk])
        let toInbox = try refusedInvitation(store, account, junk, uid: 1)
        let toArchive = try refusedInvitation(store, account, junk, uid: 2)
        try store.apply(.move(toInbox, to: .inbox))
        try store.apply(.moveTo(toArchive, try #require(folders[.archive])))
        for id in [toInbox, toArchive] {
            #expect(!(try store.isInvitationRecorded(id)))
            #expect(try store.invitationsAwaitingIntake(account, limit: 10).contains(id))
        }
    }

    /// After a move only what has no record is taken: an invitation waiting for the account's
    /// calendars waits for the next calendar sync, not for every change the owner makes.
    @Test func whatWaitsForTheCalendarsIsLeftOutWhenAsked() throws {
        let store = try MailStore(path: nil)
        let (account, folders) = try junkAccount(store)
        let junk = try #require(folders[.junk])
        let freed = try refusedInvitation(store, account, junk, uid: 1)
        try store.apply(.move(freed, to: .inbox))
        let waiting = try refusedInvitation(store, account, try #require(folders[.inbox]), uid: 2)
        try store.recordInvitation(
            message: waiting, method: .request, uid: "u2", recurrenceID: nil, sequence: 0, event: nil, applied: false,
            awaitingCalendar: true)
        #expect(Set(try store.invitationsAwaitingIntake(account, limit: 10)) == [freed, waiting])
        #expect(try store.invitationsAwaitingIntake(account, limit: 10, waitingForCalendars: false) == [freed])
    }

    /// Only leaving Junk for a folder that is read takes it again: to Trash, or between other folders,
    /// what the intake decided stands.
    @Test func otherMovesKeepWhatTheIntakeDecided() throws {
        let store = try MailStore(path: nil)
        let (account, folders) = try junkAccount(store)
        let trashed = try refusedInvitation(store, account, try #require(folders[.junk]), uid: 1)
        let archived = try refusedInvitation(store, account, try #require(folders[.inbox]), uid: 2)
        try store.apply(.move(trashed, to: .trash))
        try store.apply(.move(archived, to: .archive))
        for id in [trashed, archived] {
            #expect(try store.isInvitationRecorded(id))
            #expect(try store.invitation(for: id)?.wasApplied == false)
        }
    }

    /// A store from before: an invitation refused in Junk and moved out then is taken again once the
    /// store is opened; what was applied, a REPLY, and what is still in Junk or Trash are kept.
    @Test func invitationsRefusedBeforeAreTakenAgainOnce() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("mail.sqlite")
        var ids: (stuck: MessageID, applied: MessageID, reply: MessageID, junk: MessageID, trash: MessageID)
        var account: AccountID
        do {
            let store = try MailStore(path: path)
            let (owner, folders) = try junkAccount(store)
            account = owner
            let inbox = try #require(folders[.inbox])
            ids = (
                try refusedInvitation(store, owner, inbox, uid: 1),
                try refusedInvitation(store, owner, inbox, uid: 2, applied: true),
                try refusedInvitation(store, owner, inbox, uid: 3, method: .reply),
                try refusedInvitation(store, owner, try #require(folders[.junk]), uid: 4),
                try refusedInvitation(store, owner, try #require(folders[.trash]), uid: 5)
            )
        }
        let old = try DatabaseQueue(path: path.path)
        try old.write { try $0.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'junkInvitations'") }
        try old.close()
        let store = try MailStore(path: path)
        #expect(try store.invitationsAwaitingIntake(account, limit: 10) == [ids.stuck])
        for kept in [ids.applied, ids.reply, ids.junk, ids.trash] {
            #expect(try store.isInvitationRecorded(kept))
        }
    }
}
