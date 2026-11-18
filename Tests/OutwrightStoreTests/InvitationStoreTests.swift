// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import GRDB
import OutwrightMIME
import OutwrightModel
import Testing

@testable import OutwrightStore

private let utcZone = TimeZone(identifier: "UTC") ?? .gmt

private func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = utcZone
    return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour)) ?? .distantPast
}

private let window = utc(2026, 12, 1)...utc(2027, 2, 1)
private let weekly = RecurrenceRule(freq: .weekly, count: 4)
private let organizer = "boss@example.org"

/// An invitation from `organizer` to the account (anna@example.org), not yet answered.
private func invited(
    _ title: String = "Planning", day: Int = 10, response: Attendee.Response = .needsAction,
    status: EventStatus = .confirmed, sequence: Int = 0, reminder: Int? = nil
) -> EventDetails {
    EventDetails(
        title: title, start: .utc(utc(2026, 12, day, 9)), end: .utc(utc(2026, 12, day, 10)), reminder: reminder,
        attendees: [Attendee(email: organizer, response: .accepted), Attendee(email: "anna@example.org", response: response)],
        organizer: organizer, status: status, sequence: sequence)
}

private func own(_ title: String = "Own") -> EventDetails {
    EventDetails(title: title, start: .utc(utc(2026, 12, 11, 9)), end: .utc(utc(2026, 12, 11, 10)))
}

private func expectReadOnly(_ body: () throws -> Void) {
    do {
        try body()
        Issue.record("expected the edit to be refused")
    } catch {
        guard case .readOnly? = error as? StoreError else { Issue.record("wrong error \(error)"); return }
    }
}

private struct InviteFixture {
    let base: Fixture
    let cal: CalendarInfo
    let drafts: Folder
    var store: MailStore { base.store }
    var account: AccountID { base.account.id }

    init(readOnly: Bool = false) throws {
        base = try Fixture()
        var account = base.account
        account.calDAV = "https://dav.example.org/"
        try base.store.save(account)
        let folders = Fixture.folders(for: account.id) + [
            Folder(
                id: FolderID(raw: 0), accountID: account.id, path: "Drafts", name: "Drafts", kind: .drafts,
                uidValidity: 1, unread: 0, isFavorite: false)
        ]
        try base.store.replaceFolders(folders, for: account.id)
        drafts = try #require(try base.store.folders(account.id).first { $0.kind == .drafts })
        try base.store.replaceCalendars(
            [(href: "https://dav.example.org/cal/work/", name: "Work", color: nil, isReadOnly: readOnly)],
            for: account.id)
        cal = try #require(try base.store.calendars(account.id).first)
    }

    @discardableResult
    func remote(_ href: String, _ series: EventSeries, etag: String = "e1", scheduleTag: String? = nil) throws -> Bool {
        try store.upsertRemote(
            href: href, etag: etag, ics: Data("BEGIN:VCALENDAR".utf8), series: series, in: cal.id, window: window,
            phoneZone: utcZone, scheduleTag: scheduleTag)
    }

    func insert(_ series: EventSeries) throws -> EventID {
        try store.insertInvitation(
            ics: Data("INVITE \(series.uid)".utf8), series: series, uid: series.uid, in: cal.id, window: window,
            phoneZone: utcZone)
    }

    func all() throws -> [CalendarEvent] {
        try store.occurrences(from: window.lowerBound, to: window.upperBound, in: nil)
    }

    func theEvent() throws -> CalendarEvent {
        try #require(try all().first)
    }

    func pending(_ id: EventID) throws -> (edits: [EventEdit], href: String?, revision: Int)? {
        try store.pendingEventChanges(account).first { $0.event == id }.map { ($0.edits, $0.href, $0.revision) }
    }

    func message(uid: UInt32) throws -> MessageID {
        try #require(try store.upsert([row(account, base.inbox.id, uid: uid)]).first)
    }

    func draftsHeld() throws -> [MessageRow] {
        try store.queue.read { database in
            try Row.fetchAll(
                database, sql: "SELECT \(Records.messageColumns), 1 AS cnt FROM message m WHERE m.folderId = ?",
                arguments: [drafts.id.raw]
            ).compactMap(Records.message)
        }
    }

    func reply(_ header: String = "<reply@example.org>", subject: String = "Accepted: Planning")
        -> (row: MessageRow, body: Data) {
        let row = MessageRow(
            id: MessageID(raw: 0), accountID: account, folderID: base.inbox.id, uid: 0,
            threadID: ThreadID(raw: "reply"), from: Address(name: nil, email: "anna@example.org"),
            to: [Address(name: nil, email: organizer)], cc: [], subject: subject, preview: "",
            date: utc(2026, 12, 1), isRead: true, isFlagged: false, hasAttachment: false, isInvitation: true,
            inboxClass: .focused, hasBody: true, threadCount: 1, messageIDHeader: header)
        return (row, mime("Anna has accepted."))
    }
}

@Suite struct InvitationStoreTests {
    @Test func migrationFromV6KeepsEvents() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("v6-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let id = UUID().uuidString
        let series = CalendarRecords.encode(EventSeries(uid: "u1", base: invited()))
        let details = CalendarRecords.encode(invited())
        do {
            let old = try DatabaseQueue(path: url.path)
            try Schema.migrator().migrate(old, upTo: "v6")
            try old.write { database in
                try database.execute(
                    sql: """
                        INSERT INTO account (id, displayName, email, colorIndex, imapHost, imapPort,
                            imapSecurity, smtpHost, smtpPort, smtpSecurity, user, signature, sortOrder, calDAV)
                        VALUES (?, 'Anna', 'anna@example.org', 0, 'm.example.org', 993, 'tls',
                            'm.example.org', 465, 'tls', 'anna', '', 0, 'https://dav.example.org/');
                        INSERT INTO calendar (id, accountId, href, name, color, isReadOnly) VALUES (1, ?, '/c/', 'C', 0, 0);
                        INSERT INTO event (id, accountId, calendarId, href, etag, uid, seriesJSON, detailed, organizer)
                        VALUES (1, ?, 1, '/c/a.ics', 'e1', 'u1', ?, 1, 'boss@example.org');
                        INSERT INTO occurrence (eventId, detailsJSON, startUTC, endUTC) VALUES (1, ?, ?, ?);
                        """,
                    arguments: [
                        id, id, id, series, details, utc(2026, 12, 10, 9).timeIntervalSince1970,
                        utc(2026, 12, 10, 10).timeIntervalSince1970
                    ])
            }
        }
        let store = try MailStore(path: url)
        let event = try #require(try store.event(EventID(raw: 1), occurrence: nil))
        #expect(event.origin == .server)
        #expect(event.isInvitation)
        #expect(event.ownResponse == .needsAction)
        #expect(try store.scheduleTag(event.id) == nil)
        #expect(try store.occurrences(from: window.lowerBound, to: window.upperBound, in: nil).count == 1)
    }

    @Test func whetherTheServerSchedulesIsKeptPerAccount() throws {
        let f = try InviteFixture()
        let account = f.account
        // Not asked yet: taken as scheduling, as the supported server does.
        #expect(try f.store.serverSchedules(account))
        try f.store.setServerSchedules(false, for: account)
        #expect(try !f.store.serverSchedules(account))
        try f.store.setServerSchedules(true, for: account)
        #expect(try f.store.serverSchedules(account))
    }

    @Test func onlyACopyWhoseCreateHasNotLandedIsOffTheServer() throws {
        let f = try InviteFixture()
        let inserted = try f.insert(EventSeries(uid: "inv-1", base: invited()))
        #expect(try !f.store.isOnServer(inserted))
        _ = try f.remote("/cal/inv-2.ics", EventSeries(uid: "inv-2", base: invited()))
        let held = try #require(try f.all().first { $0.id != inserted })
        #expect(try f.store.isOnServer(held.id))
    }

    /// The same meeting in a subscribed calendar (the published copy of a work calendar) is not the
    /// event an invitation is about: the invitation goes into the account's own calendar.
    @Test func subscriptionCopyIsNotTheInvitationsEvent() throws {
        let f = try InviteFixture()
        let published = try f.store.addSubscription(
            key: UUID(), host: "example.org", name: "Work (published)", color: nil)
        try f.store.upsertRemote(
            href: "uid:inv-2", etag: "x", ics: Data("BEGIN:VCALENDAR".utf8),
            series: EventSeries(uid: "inv-2", base: invited()), in: published, window: window, phoneZone: utcZone,
            scheduleTag: nil)
        #expect(try f.store.invitationEvent(accountId: f.account, uid: "inv-2") == nil)
        let id = try f.insert(EventSeries(uid: "inv-2", base: invited()))
        let own = try #require(try f.all().first { $0.id == id })
        #expect(own.calendarID == f.cal.id)
        #expect(own.isInvitation)
    }

    @Test func insertedInvitationIsQueuedAndTentative() throws {
        let f = try InviteFixture()
        let id = try f.insert(EventSeries(uid: "inv-1", base: invited()))
        let shown = try f.theEvent()
        #expect(shown.id == id)
        #expect(shown.isTentative)
        #expect(shown.isInvitation)
        #expect(!shown.isEditable)
        #expect(shown.origin == .app)
        let queued = try #require(try f.pending(id))
        guard case .create? = queued.edits.first, queued.edits.count == 1 else {
            Issue.record("a create is queued")
            return
        }
        #expect(queued.href == nil)
        let target = try #require(try f.store.eventCreateTarget(id))
        #expect(target.ics == Data("INVITE inv-1".utf8))
        #expect(target.href.hasPrefix("https://dav.example.org/cal/work/"))
        #expect(target.href.hasSuffix(".ics"))
        // The same UID again is the same event.
        #expect(try f.insert(EventSeries(uid: "inv-1", base: invited())) == id)
        #expect(try f.all().count == 1)
    }

    @Test func respondIsQueuedAndChangesTentative() throws {
        let f = try InviteFixture()
        try f.remote("https://dav.example.org/cal/work/a.ics", EventSeries(uid: "u1", base: invited()))
        let id = try f.theEvent().id
        try f.store.respond(id, .accepted, scope: .event, sendReply: true)
        let shown = try f.theEvent()
        #expect(!shown.isTentative)
        #expect(shown.ownResponse == .accepted)
        try f.store.respond(id, .tentative, scope: .event, sendReply: false)
        #expect(try f.theEvent().isTentative)
        let queued = try #require(try f.pending(id))
        #expect(queued.edits == [
            .respond(.accepted, scope: .event, sendReply: true), .respond(.tentative, scope: .event, sendReply: false)
        ])
    }

    @Test func respondToOneOccurrenceChangesOnlyIt() throws {
        let f = try InviteFixture()
        try f.remote("https://dav.example.org/cal/work/a.ics", EventSeries(uid: "u1", base: invited(), rule: weekly))
        let second = EventTime.utc(utc(2026, 12, 17, 9))
        let id = try f.theEvent().id
        try f.store.respond(id, .accepted, scope: .occurrence(second), sendReply: true)
        let shown = try f.all()
        #expect(shown.count == 4)
        #expect(shown.map(\.ownResponse) == [.needsAction, .accepted, .needsAction, .needsAction])
        #expect(shown.map(\.occurrence.start) == [10, 17, 24, 31].map { utc(2026, 12, $0, 9) })
        #expect(shown[1].occurrence.end == utc(2026, 12, 17, 10))
    }

    @Test func declineHidesButKeeps() throws {
        let f = try InviteFixture()
        try f.remote("https://dav.example.org/cal/work/a.ics", EventSeries(uid: "u1", base: invited()))
        let id = try f.theEvent().id
        try f.store.respond(id, .declined, scope: .event, sendReply: true)
        #expect(try f.all().isEmpty)
        let kept = try #require(try f.store.event(accountId: f.account, uid: "u1", recurrenceID: nil))
        #expect(kept.id == id)
        #expect(kept.ownResponse == .declined)
        // Accepting after all brings it back.
        try f.store.respond(id, .accepted, scope: .event, sendReply: true)
        #expect(try f.all().count == 1)
    }

    @Test func deleteOnInvitationDeclines() throws {
        let f = try InviteFixture()
        try f.remote("https://dav.example.org/cal/work/a.ics", EventSeries(uid: "u1", base: invited()))
        try f.remote(
            "https://dav.example.org/cal/work/b.ics", EventSeries(uid: "u2", base: invited("Weekly"), rule: weekly))
        let single = try #require(try f.all().first { $0.occurrence.details.title == "Planning" })
        try f.store.declineByDeleting(single.id, scope: .event)
        #expect(try f.pending(single.id)?.edits == [.respond(.declined, scope: .event, sendReply: true)])
        #expect(try f.store.event(single.id, occurrence: nil)?.ownResponse == .declined)
        let second = EventTime.utc(utc(2026, 12, 17, 9))
        let series = try #require(try f.all().first { $0.occurrence.details.title == "Weekly" })
        try f.store.declineByDeleting(series.id, scope: .occurrence(second))
        let left = try f.all()
        #expect(left.count == 3)
        #expect(!left.contains { $0.occurrence.recurrenceID == second })
    }

    @Test func ownReminderOnInvitationIsAllowed() throws {
        let f = try InviteFixture()
        try f.remote("https://dav.example.org/cal/work/a.ics", EventSeries(uid: "u1", base: invited()))
        let id = try f.theEvent().id
        try f.store.setOwnReminder(id, minutes: 15, scope: .event)
        #expect(try f.theEvent().occurrence.details.reminder == 15)
        #expect(try f.pending(id)?.edits == [.ownReminder(15, scope: .event)])
        try f.store.setOwnReminder(id, minutes: nil, scope: .event)
        #expect(try f.theEvent().occurrence.details.reminder == nil)
    }

    @Test func ownerEditsStillRefuseInvitations() throws {
        let f = try InviteFixture()
        try f.remote("https://dav.example.org/cal/work/a.ics", EventSeries(uid: "u1", base: invited()))
        let id = try f.theEvent().id
        expectReadOnly { try f.store.updateEvent(id, own("Mine"), rule: nil, scope: .event) }
        expectReadOnly { try f.store.deleteEvent(id, scope: .event) }
        #expect(try f.pending(id) == nil)
    }

    @Test func respondOnOwnEventIsRefused() throws {
        let f = try InviteFixture()
        try f.remote("https://dav.example.org/cal/work/b.ics", EventSeries(uid: "u2", base: own()))
        let id = try f.theEvent().id
        expectReadOnly { try f.store.respond(id, .accepted, scope: .event, sendReply: true) }
        expectReadOnly { try f.store.setOwnReminder(id, minutes: 5, scope: .event) }
        expectReadOnly { try f.store.declineByDeleting(id, scope: .event) }
        #expect(!(try f.theEvent().isInvitation))
        let locked = try InviteFixture(readOnly: true)
        try locked.remote("https://dav.example.org/cal/work/a.ics", EventSeries(uid: "u1", base: invited()))
        let invitation = try locked.theEvent().id
        expectReadOnly { try locked.store.respond(invitation, .accepted, scope: .event, sendReply: true) }
    }

    @Test func serverCopyReplacesAppCopy() throws {
        let f = try InviteFixture()
        let app = try f.insert(EventSeries(uid: "inv-1", base: invited()))
        let created = try #require(try f.pending(app))
        try f.store.eventChangeDone(
            app, revision: created.revision, href: "https://dav.example.org/cal/work/app.ics", etag: "a1",
            ics: Data("INVITE".utf8), series: EventSeries(uid: "inv-1", base: invited()), scheduleTag: nil)
        try f.store.respond(app, .accepted, scope: .event, sendReply: true)
        try f.store.setOwnReminder(app, minutes: 30, scope: .event)
        try f.remote("https://dav.example.org/cal/work/server.ics", EventSeries(uid: "inv-1", base: invited()))
        let shown = try f.all()
        #expect(shown.count == 1)
        let server = try #require(shown.first)
        #expect(server.id != app)
        #expect(server.origin == .server)
        #expect(server.ownResponse == .accepted)
        #expect(server.occurrence.details.reminder == 30)
        let gone = try #require(try f.pending(app))
        #expect(gone.edits == [.delete(scope: .event)])
        #expect(gone.href == "https://dav.example.org/cal/work/app.ics")
        #expect(try f.pending(server.id)?.edits == [
            .respond(.accepted, scope: .event, sendReply: true), .ownReminder(30, scope: .event)
        ])
        #expect(try f.store.event(accountId: f.account, uid: "inv-1", recurrenceID: nil)?.id == server.id)
    }

    @Test func serverCopyThatAnsweredKeepsItsOwnAnswer() throws {
        let f = try InviteFixture()
        let app = try f.insert(EventSeries(uid: "inv-1", base: invited()))
        try f.store.respond(app, .accepted, scope: .event, sendReply: true)
        try f.remote(
            "https://dav.example.org/cal/work/server.ics", EventSeries(uid: "inv-1", base: invited(response: .declined)))
        let kept = try #require(try f.store.event(accountId: f.account, uid: "inv-1", recurrenceID: nil))
        #expect(kept.id != app)
        #expect(kept.ownResponse == .declined)
        #expect(try f.pending(kept.id) == nil)
        #expect(try f.pending(app)?.edits == [.delete(scope: .event)])
    }

    @Test func invitationStateForMessage() throws {
        let f = try InviteFixture()
        try f.remote("https://dav.example.org/cal/work/a.ics", EventSeries(uid: "u1", base: invited()))
        let id = try f.theEvent().id
        let first = try f.message(uid: 1)
        let later = try f.message(uid: 2)
        #expect(!(try f.store.isInvitationRecorded(first)))
        #expect(try f.store.invitation(for: first) == nil)
        try f.store.recordInvitation(
            message: first, method: .request, uid: "u1", recurrenceID: nil, sequence: 0, event: id, applied: true)
        #expect(try f.store.isInvitationRecorded(first))
        let state = try #require(try f.store.invitation(for: first))
        #expect(state.method == .request)
        #expect(state.event?.id == id)
        #expect(state.sequence == 0)
        #expect(state.wasApplied)
        #expect(!state.isOutdated)
        #expect(state.reply == nil)
        try f.store.recordInvitation(
            message: later, method: .request, uid: "u1", recurrenceID: nil, sequence: 1, event: id, applied: true)
        #expect(try f.store.invitation(for: first)?.isOutdated == true)
        #expect(try f.store.invitation(for: later)?.isOutdated == false)
        let spoofed = try f.message(uid: 3)
        try f.store.recordInvitation(
            message: spoofed, method: .cancel, uid: "u1", recurrenceID: nil, sequence: 5, event: nil, applied: false)
        let refused = try #require(try f.store.invitation(for: spoofed))
        #expect(!refused.wasApplied)
        // What was not applied makes nothing outdated.
        #expect(try f.store.invitation(for: later)?.isOutdated == false)
    }

    @Test func replyStateShowsWhoAnswered() throws {
        let f = try InviteFixture()
        let message = try f.message(uid: 1)
        try f.store.recordInvitation(
            message: message, method: .reply, uid: "u9", recurrenceID: nil, sequence: 0, event: nil, applied: true,
            reply: (email: "bo@example.org", response: .accepted))
        let state = try #require(try f.store.invitation(for: message))
        #expect(state.method == .reply)
        #expect(state.reply?.email == "bo@example.org")
        #expect(state.reply?.response == .accepted)
        #expect(state.event == nil)
    }

    @Test func cancelledCanBeRemoved() throws {
        let f = try InviteFixture()
        try f.remote("https://dav.example.org/cal/work/a.ics", EventSeries(uid: "u1", base: invited()))
        let live = try f.theEvent()
        #expect(!live.isCancelled)
        expectReadOnly { try f.store.removeCancelled(live.id) }
        try f.remote(
            "https://dav.example.org/cal/work/a.ics", EventSeries(uid: "u1", base: invited(status: .cancelled)),
            etag: "e2")
        let cancelled = try f.theEvent()
        #expect(cancelled.isCancelled)
        try f.store.removeCancelled(cancelled.id)
        #expect(try f.all().isEmpty)
        #expect(try f.pending(cancelled.id)?.edits == [.delete(scope: .event)])
    }

    @Test func respondDoneQueuesTheReplyOnce() throws {
        let f = try InviteFixture()
        try f.remote("https://dav.example.org/cal/work/a.ics", EventSeries(uid: "u1", base: invited()))
        let id = try f.theEvent().id
        try f.store.respond(id, .accepted, scope: .event, sendReply: true)
        let first = try #require(try f.pending(id))
        try f.store.respond(id, .declined, scope: .event, sendReply: true)
        let second = try #require(try f.pending(id))
        let done = EventSeries(uid: "u1", base: invited(response: .accepted))
        try f.store.respondDone(
            id, revision: first.revision, href: "https://dav.example.org/cal/work/a.ics", etag: "e2",
            ics: Data("A".utf8), series: done, reply: f.reply(), scheduleTag: nil)
        #expect(try f.draftsHeld().count == 1)
        // The same answer done again sends nothing new.
        try f.store.respondDone(
            id, revision: first.revision, href: "https://dav.example.org/cal/work/a.ics", etag: "e2",
            ics: Data("A".utf8), series: done, reply: f.reply(), scheduleTag: nil)
        #expect(try f.draftsHeld().count == 1)
        try f.store.respondDone(
            id, revision: second.revision, href: "https://dav.example.org/cal/work/a.ics", etag: "e3",
            ics: Data("D".utf8), series: EventSeries(uid: "u1", base: invited(response: .declined)),
            reply: f.reply("<reply-2@example.org>"), scheduleTag: nil)
        let drafts = try f.draftsHeld()
        #expect(drafts.count == 2)
        #expect(drafts.filter(\.hasBody).count == 2)
        let sends = try f.store.pendingActions().filter {
            if case .send = $0.action { return true }
            return false
        }
        #expect(Set(sends.map(\.action.target)) == Set(drafts.map(\.id)))
        #expect(try f.pending(id) == nil)
    }

    @Test func aServerAnsweredCopyGetsNoReplyFromTheApp() throws {
        let f = try InviteFixture()
        try f.remote("https://dav.example.org/cal/work/a.ics", EventSeries(uid: "u1", base: invited()))
        let id = try f.theEvent().id
        try f.store.respond(id, .accepted, scope: .event, sendReply: true)
        let queued = try #require(try f.pending(id))
        try f.store.respondDone(
            id, revision: queued.revision, href: "https://dav.example.org/cal/work/a.ics", etag: "e2",
            ics: Data("A".utf8), series: EventSeries(uid: "u1", base: invited(response: .accepted)),
            reply: f.reply(), scheduleTag: "s2")
        #expect(try f.draftsHeld().isEmpty)
        #expect(try f.store.scheduleTag(id) == "s2")
    }

    @Test func scheduleTagIsKept() throws {
        let f = try InviteFixture()
        try f.remote("https://dav.example.org/cal/work/a.ics", EventSeries(uid: "u1", base: invited()), scheduleTag: "s1")
        let id = try f.theEvent().id
        #expect(try f.store.scheduleTag(id) == "s1")
        try f.store.setScheduleTag(nil, for: id)
        #expect(try f.store.scheduleTag(id) == nil)
        try f.store.setOwnReminder(id, minutes: 10, scope: .event)
        let queued = try #require(try f.pending(id))
        try f.store.eventChangeDone(
            id, revision: queued.revision, href: "https://dav.example.org/cal/work/a.ics", etag: "e2",
            ics: Data("A".utf8), series: EventSeries(uid: "u1", base: invited(reminder: 10)), scheduleTag: "s3")
        #expect(try f.store.scheduleTag(id) == "s3")
    }

    @Test func aConflictOrADiscardClearsAFailedReply() throws {
        let f = try InviteFixture()
        try f.store.replaceFolders(Fixture.folders(for: f.account), for: f.account)
        let href = "https://dav.example.org/cal/work/a.ics"
        try f.remote(href, EventSeries(uid: "u1", base: invited()))
        let id = try f.theEvent().id
        let accepted = EventSeries(uid: "u1", base: invited(response: .accepted))
        try f.store.respond(id, .accepted, scope: .event, sendReply: true)
        var queued = try #require(try f.pending(id))
        try f.store.respondDone(
            id, revision: queued.revision, href: href, etag: "e2", ics: Data("A".utf8), series: accepted,
            reply: f.reply(), scheduleTag: nil)
        #expect(try f.theEvent().changeFailed)
        try f.store.setOwnReminder(id, minutes: 5, scope: .event)
        try f.store.eventChangeConflicted(id, server: (etag: "e3", ics: Data("S".utf8), series: accepted))
        #expect(try f.theEvent().changeFailed == false)

        try f.store.respond(id, .declined, scope: .event, sendReply: true)
        queued = try #require(try f.pending(id))
        try f.store.respondDone(
            id, revision: queued.revision, href: href, etag: "e4", ics: Data("D".utf8),
            series: EventSeries(uid: "u1", base: invited(response: .declined)), reply: f.reply(), scheduleTag: nil)
        try f.store.discardEventConflict(id)
        #expect(try f.store.pendingEventChanges(f.account).isEmpty)
        try f.store.retryEventReply(id)
        #expect(try f.store.pendingEventChanges(f.account).isEmpty)
    }

    /// The owner gave the answer up while it was on its way, but the server took it: its reply is
    /// still owed and shown as failed.
    @Test func anAnswerGivenUpInFlightStillShowsItsFailedReply() throws {
        let f = try InviteFixture()
        try f.store.replaceFolders(Fixture.folders(for: f.account), for: f.account)
        let href = "https://dav.example.org/cal/work/a.ics"
        try f.remote(href, EventSeries(uid: "u1", base: invited()))
        let id = try f.theEvent().id
        try f.store.respond(id, .accepted, scope: .event, sendReply: true)
        let queued = try #require(try f.pending(id))
        try f.store.restoreEventServerVersion(id, series: EventSeries(uid: "u1", base: invited()))
        let accepted = EventSeries(uid: "u1", base: invited(response: .accepted))
        try f.store.respondDone(
            id, revision: queued.revision, href: href, etag: "e2", ics: Data("A".utf8), series: accepted,
            reply: f.reply(), scheduleTag: nil)
        try f.remote(href, accepted, etag: "e2")
        #expect(try f.theEvent().changeFailed)
        #expect(try f.theEvent().replyFailed)
    }

    @Test func aChangeTheServerRefusedIsNoFailedReply() throws {
        let f = try InviteFixture()
        try f.remote("https://dav.example.org/cal/work/a.ics", EventSeries(uid: "u1", base: invited()))
        let id = try f.theEvent().id
        try f.store.respond(id, .accepted, scope: .event, sendReply: true)
        let queued = try #require(try f.pending(id))
        try f.store.eventChangeFailed(id, revision: queued.revision)
        #expect(try f.theEvent().changeFailed)
        #expect(!(try f.theEvent().replyFailed))
    }

    @Test func invitationStateCarriesItsOccurrenceAndWhetherTheTimeMoved() throws {
        let f = try InviteFixture()
        try f.remote(
            "https://dav.example.org/cal/work/a.ics", EventSeries(uid: "u1", base: invited(), rule: weekly))
        let id = try f.theEvent().id
        let occurrence = EventTime.utc(utc(2026, 12, 17, 9))
        let first = try f.message(uid: 1)
        let update = try f.message(uid: 2)
        try f.store.recordInvitation(
            message: first, method: .request, uid: "u1", recurrenceID: nil, sequence: 0, event: id, applied: true)
        try f.store.recordInvitation(
            message: update, method: .request, uid: "u1", recurrenceID: occurrence, sequence: 1, event: id,
            applied: true, timeMoved: true)
        #expect(try f.store.invitation(for: first)?.recurrenceID == nil)
        #expect(try f.store.invitation(for: first)?.timeMoved == nil)
        #expect(try f.store.invitation(for: update)?.recurrenceID == occurrence)
        #expect(try f.store.invitation(for: update)?.timeMoved == true)
    }

    @Test func aConflictKeepsTheServersScheduleTag() throws {
        let f = try InviteFixture()
        try f.remote("https://dav.example.org/cal/work/a.ics", EventSeries(uid: "u1", base: invited()))
        let id = try f.theEvent().id
        try f.store.respond(id, .accepted, scope: .event, sendReply: true)
        try f.store.eventChangeConflicted(
            id, server: (etag: "e2", ics: Data("S".utf8), series: EventSeries(uid: "u1", base: invited("Moved"))),
            scheduleTag: "s9")
        #expect(try f.store.scheduleTag(id) == "s9")
    }

    /// RFC 6638 › 3.2.2.2: the organiser's change from mail is the client's to store on the server.
    @Test(.timeLimit(.minutes(1))) func invitationChangeOnServerCopyIsQueuedForTheServer() async throws {
        let f = try InviteFixture()
        try f.remote("https://dav.example.org/cal/work/a.ics", EventSeries(uid: "u1", base: invited()))
        let id = try f.theEvent().id
        var queued = f.store.queuedActions().makeAsyncIterator()
        try f.store.applyInvitationChange(
            id, ics: Data("MOVED".utf8), series: EventSeries(uid: "u1", base: invited(day: 12, sequence: 1)),
            window: window, phoneZone: utcZone)
        // The cue to send it now, not at the next calendar sync.
        #expect(await queued.next() == f.account)
        #expect(try f.theEvent().occurrence.start == utc(2026, 12, 12, 9))
        #expect(try f.pending(id)?.edits == [.organiserChange])
        #expect(try f.store.serverEvent(id) == Data("BEGIN:VCALENDAR".utf8))
        // A second change before the first is written is queued after it.
        try f.store.applyInvitationChange(
            id, ics: Data("MOVED2".utf8), series: EventSeries(uid: "u1", base: invited(day: 13, sequence: 2)),
            window: window, phoneZone: utcZone)
        #expect(try f.pending(id)?.edits == [.organiserChange, .organiserChange])
        #expect(try f.store.eventObject(id) == Data("MOVED2".utf8))
        // The first one's write lands after the second came: the second stays queued and shown.
        try f.store.eventChangeDone(
            id, revision: try #require(try f.pending(id)).revision - 1, href: "https://dav.example.org/cal/work/a.ics",
            etag: "e2", ics: Data("MOVED".utf8), series: EventSeries(uid: "u1", base: invited(day: 12, sequence: 1)),
            scheduleTag: nil, builtOn: Data("MOVED".utf8))
        #expect(try f.pending(id) != nil)
        #expect(try f.store.eventObject(id) == Data("MOVED2".utf8))
    }

    @Test func appliedChangeHoldsUntilTheServerCatchesUp() throws {
        let f = try InviteFixture()
        let href = "https://dav.example.org/cal/work/a.ics"
        try f.remote(href, EventSeries(uid: "u1", base: invited()))
        let id = try f.theEvent().id
        try f.store.applyInvitationChange(
            id, ics: Data("MOVED".utf8), series: EventSeries(uid: "u1", base: invited(day: 12, sequence: 1)),
            window: window, phoneZone: utcZone)
        #expect(try f.store.eventObject(id) == Data("MOVED".utf8))
        // The server would not take it (RFC 6638 › 3.2.2.1).
        try f.store.settleOrganiserChange(id, revision: try #require(try f.pending(id)).revision)
        #expect(try f.pending(id) == nil)
        // The server's copy is still the older one: the change from mail stays shown and held.
        try f.remote(href, EventSeries(uid: "u1", base: invited()), etag: "e2")
        #expect(try f.theEvent().occurrence.start == utc(2026, 12, 12, 9))
        #expect(try f.store.eventObject(id) == Data("MOVED".utf8))
        // The server has applied it (or something newer): the server's copy is the event again.
        try f.remote(href, EventSeries(uid: "u1", base: invited(day: 13, sequence: 1)), etag: "e3")
        #expect(try f.theEvent().occurrence.start == utc(2026, 12, 13, 9))
        #expect(try f.store.eventObject(id) == Data("BEGIN:VCALENDAR".utf8))
    }

    @Test func invitationEventIsFoundWithoutAnOccurrence() throws {
        let f = try InviteFixture()
        let far = EventDetails(
            title: "Far", start: .utc(utc(2028, 6, 1, 9)), end: .utc(utc(2028, 6, 1, 10)),
            attendees: [Attendee(email: organizer, response: .accepted), Attendee(email: "anna@example.org")],
            organizer: organizer)
        let id = try f.insert(EventSeries(uid: "far", base: far))
        #expect(try f.all().isEmpty)
        #expect(try f.store.invitationEvent(accountId: f.account, uid: "far") == id)
        #expect(try f.store.invitationEvent(accountId: f.account, uid: "none") == nil)
    }

    @Test func invitationChangeOnUnsentAppCopyRewritesTheCreate() throws {
        let f = try InviteFixture()
        let id = try f.insert(EventSeries(uid: "inv-1", base: invited()))
        let href = try #require(try f.store.eventCreateTarget(id)).href
        try f.store.applyInvitationChange(
            id, ics: Data("MOVED".utf8), series: EventSeries(uid: "inv-1", base: invited(day: 12, sequence: 1)),
            window: window, phoneZone: utcZone)
        #expect(try f.theEvent().occurrence.start == utc(2026, 12, 12, 9))
        let target = try #require(try f.store.eventCreateTarget(id))
        #expect(target.href == href)
        #expect(target.ics == Data("MOVED".utf8))
        guard case let .create(details, _)? = try f.pending(id)?.edits.first else {
            Issue.record("still a create")
            return
        }
        #expect(details.start == .utc(utc(2026, 12, 12, 9)))
    }
    @Test func anInvitationChangeWhileTheCreateIsUnderWayIsWrittenAfterIt() throws {
        let f = try InviteFixture()
        let id = try f.insert(EventSeries(uid: "inv-1", base: invited()))
        let target = try #require(try f.store.eventCreateTarget(id))
        let sending = try #require(try f.pending(id)).revision
        try f.store.applyInvitationChange(
            id, ics: Data("MOVED".utf8), series: EventSeries(uid: "inv-1", base: invited(day: 12, sequence: 1)),
            window: window, phoneZone: utcZone)
        // The create sent before the change came lands, as it was.
        try f.store.eventChangeDone(
            id, revision: sending, href: target.href, etag: "e1", ics: Data("FIRST".utf8),
            series: EventSeries(uid: "inv-1", base: invited()), scheduleTag: nil)
        #expect(try f.pending(id)?.edits == [.organiserChange], "the change is still to be written")
        #expect(try f.store.eventObject(id) == Data("MOVED".utf8))
        #expect(try f.theEvent().occurrence.start == utc(2026, 12, 12, 9), "and still shown")
    }

    @Test func aRetriedDoneOfAnEarlierAnswerSendsNoSecondReply() throws {
        let f = try InviteFixture()
        let href = "https://dav.example.org/cal/work/a.ics"
        try f.remote(href, EventSeries(uid: "u1", base: invited()))
        let id = try f.theEvent().id
        try f.store.respond(id, .accepted, scope: .event, sendReply: true)
        let accepted = try #require(try f.pending(id))
        let acceptedSeries = EventSeries(uid: "u1", base: invited(response: .accepted))
        try f.store.respondDone(
            id, revision: accepted.revision, href: href, etag: "e2", ics: Data("A".utf8), series: acceptedSeries,
            reply: f.reply("<a1@example.org>"), scheduleTag: nil)
        try f.store.respond(id, .declined, scope: .event, sendReply: true)
        let declined = try #require(try f.pending(id))
        // The accept's done comes again (its answer was lost, say): no second ACCEPTED.
        try f.store.respondDone(
            id, revision: accepted.revision, href: href, etag: "e2", ics: Data("A".utf8), series: acceptedSeries,
            reply: f.reply("<a2@example.org>"), scheduleTag: nil)
        #expect(try f.draftsHeld().map(\.subject) == ["Accepted: Planning"])
        try f.store.respondDone(
            id, revision: declined.revision, href: href, etag: "e3", ics: Data("D".utf8),
            series: EventSeries(uid: "u1", base: invited(response: .declined)),
            reply: f.reply("<d1@example.org>", subject: "Declined: Planning"), scheduleTag: nil)
        #expect(try f.draftsHeld().map(\.subject).sorted() == ["Accepted: Planning", "Declined: Planning"])
    }

    @Test func acceptingASeriesAnswersEveryOverride() throws {
        let f = try InviteFixture()
        let second = EventTime.utc(utc(2026, 12, 17, 9))
        var moved = invited(day: 17)
        moved.start = .utc(utc(2026, 12, 17, 13))
        moved.end = .utc(utc(2026, 12, 17, 14))
        try f.remote(
            "https://dav.example.org/cal/work/a.ics",
            EventSeries(uid: "u1", base: invited(), rule: weekly, overrides: [EventOverride(recurrenceID: second, details: moved)]))
        let id = try f.theEvent().id
        try f.store.respond(id, .accepted, scope: .event, sendReply: true)
        let shown = try f.all()
        #expect(shown.count == 4)
        #expect(shown.allSatisfy { $0.ownResponse == .accepted && !$0.isTentative })
    }

    @Test func decliningOneOfTwoOverridesKeepsTheOther() throws {
        let f = try InviteFixture()
        let first = EventTime.utc(utc(2026, 12, 10, 9))
        let second = EventTime.utc(utc(2026, 12, 17, 9))
        try f.remote(
            "https://dav.example.org/cal/work/a.ics",
            EventSeries(
                uid: "u1", base: nil,
                overrides: [
                    EventOverride(recurrenceID: first, details: invited(day: 10)),
                    EventOverride(recurrenceID: second, details: invited(day: 17))
                ]))
        let id = try #require(try f.all().first).id
        try f.store.declineByDeleting(id, scope: .occurrence(first))
        let left = try f.all()
        #expect(left.map(\.occurrence.start) == [utc(2026, 12, 17, 9)])
        // The same as the server holds it: the first override declined, the second not.
        try f.remote(
            "https://dav.example.org/cal/work/b.ics",
            EventSeries(
                uid: "u2", base: nil,
                overrides: [
                    EventOverride(recurrenceID: first, details: invited("Other", day: 10, response: .declined)),
                    EventOverride(recurrenceID: second, details: invited("Other", day: 17))
                ]))
        let other = try f.all().filter { $0.occurrence.details.title == "Other" }
        #expect(other.map(\.occurrence.start) == [utc(2026, 12, 17, 9)])
    }

    /// A series declined as a whole but for one occurrence the owner accepted: only that occurrence shows.
    @Test func aDeclinedSeriesShowsOnlyTheOccurrenceAnsweredOtherwise() throws {
        let f = try InviteFixture()
        let second = EventTime.utc(utc(2026, 12, 17, 9))
        try f.remote(
            "https://dav.example.org/cal/work/a.ics",
            EventSeries(
                uid: "u1", base: invited(response: .declined), rule: weekly,
                overrides: [EventOverride(recurrenceID: second, details: invited(day: 17, response: .accepted))]))
        #expect(try f.all().map(\.occurrence.start) == [utc(2026, 12, 17, 9)])
    }

    @Test func insertingWhatIsNotAnInvitationIsRefused() throws {
        let f = try InviteFixture()
        expectReadOnly { _ = try f.insert(EventSeries(uid: "mine", base: own())) }
        var forwarded = invited()
        forwarded.attendees = [Attendee(email: organizer), Attendee(email: "list@example.org")]
        expectReadOnly { _ = try f.insert(EventSeries(uid: "fwd", base: forwarded)) }
        #expect(try f.all().isEmpty)
    }

    @Test func invitationChangeOnAnOwnEventIsRefused() throws {
        let f = try InviteFixture()
        try f.remote("https://dav.example.org/cal/work/b.ics", EventSeries(uid: "u2", base: own()))
        let id = try f.theEvent().id
        expectReadOnly {
            try f.store.applyInvitationChange(
                id, ics: Data("X".utf8), series: EventSeries(uid: "u2", base: invited()), window: window,
                phoneZone: utcZone)
        }
        #expect(try f.theEvent().occurrence.details.title == "Own")
    }
}
