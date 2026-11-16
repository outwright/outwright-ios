// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightDAV
import OutwrightModel
import OutwrightStore

/// One queued change of an event, as the store hands it out.
struct QueuedEventChange {
    let event: EventID
    let edits: [EventEdit]
    let href: String?
    let etag: String?
    let ics: Data?
    let calendar: CalendarID
    let revision: Int
    /// What the store shows the event as (`eventObject`): the object an edit is written onto.
    let object: Data?

    var isDelete: Bool { edits == [.delete(scope: .event)] }
}

/// What the server holds at an object's place.
enum ServerCopy {
    case found(RemoteResource)
    /// Past the iCalendar size cap: there, but not read.
    case oversized
    case absent
}

/// Where a create goes, with which UID, and the object it starts from.
struct CreateTarget {
    let href: URL
    let uid: String
    let calendar: ICalComponent
}

extension CalendarSyncer {
    /// The server's own trouble tolerated for one change before it is marked failed.
    static let serverAttempts = 10

    /// Sends the owner's queued changes in order. A change the server refuses for good is marked
    /// failed; a 412 keeps both versions; a connection or server failure stops the queue (the rest
    /// stays queued) and is thrown. A change the server failed `serverAttempts` times is marked failed
    /// (kept, shown) and the queue goes on.
    func runQueue(_ client: CalDAVClient) async throws(SyncError) {
        try stored { try store.queueOwedMeetingMails(account.id) }
        var pending: [QueuedEventChange] = []
        for entry in try stored({ try store.pendingEventChanges(account.id) }) {
            pending.append(
                QueuedEventChange(
                    event: entry.event, edits: entry.edits, href: entry.href, etag: entry.etag, ics: entry.ics,
                    calendar: entry.calendar, revision: entry.revision,
                    object: try stored { try store.eventObject(entry.event) }))
        }
        guard !pending.isEmpty else {
            return
        }
        let calendars = try stored { try store.calendars(account.id) }
        for change in pending {
            do {
                try await send(change, calendars: calendars, client)
            } catch {
                guard Self.isServerTrouble(error) else { throw error }
                let attempts = try stored { try store.eventChangeAttempted(change.event, revision: change.revision) }
                guard attempts >= Self.serverAttempts else { throw error }
                try failed(change)
            }
        }
    }

    /// A failure on the server's side: not the connection, not the login, not the account's setup (a
    /// redirect off the trusted hosts, plain `http`, an answer past a cap), not this phone's store.
    static func isServerTrouble(_ error: SyncError) -> Bool {
        guard case let .dav(dav) = error else { return false }
        switch dav {
        case .net, .unauthorized, .offDomainRedirect, .plainRefused, .tooLarge:
            return false
        case .notFound, .preconditionFailed, .attendeeChangeRefused, .tokenInvalid, .status, .malformed:
            return true
        }
    }

    private func send(_ change: QueuedEventChange, calendars: [CalendarInfo], _ client: CalDAVClient)
        async throws(SyncError) {
        guard let text = change.href, let href = URL(string: text) else {
            if change.isDelete {
                try await deleteUnsent(change, client)
            } else {
                try await sendCreate(change, calendars: calendars, client)
            }
            return
        }
        if change.isDelete {
            try await sendDelete(change, href, client)
            return
        }
        // Onto what the owner sees: the organiser's change from mail, while the server's copy is older.
        guard let held = (change.object ?? change.ics).flatMap({ try? ICalendarReader.calendar($0) }),
            let uid = EventMapping.series(held).first?.uid
        else {
            // Without the server's object an edit would strip what the app does not show.
            try failed(change)
            return
        }
        guard let etag = try await knownETag(change, href, client) else {
            return
        }
        let scheduled = try await scheduleTagSince(change, href, client)
        let edited = written(change.edits, onto: keepingOwn(held, change), uid: uid)
        try await put(edited, at: href, ifMatch: etag, change, client, scheduleTag: scheduled)
    }

    /// The edits applied in order, each onto the result of the one before.
    func written(_ edits: [EventEdit], onto calendar: ICalComponent?, uid: String) -> ICalComponent {
        var result = calendar
        for edit in edits {
            result = EventMapping.apply(edit, to: result, uid: uid, organizer: account.email)
        }
        return result ?? ICalComponent(name: "VCALENDAR")
    }

    /// A create goes to the place and with the UID chosen at its first send (`If-None-Match: *`).
    /// Refused there because it is already on the server: when the object there is ours (an earlier
    /// send whose answer was lost, perhaps edited since by another client) the owner's later edits go
    /// over the server's copy, never our first one, and with none the server's copy is kept as it is;
    /// another object there fails the change.
    private func sendCreate(
        _ change: QueuedEventChange, calendars: [CalendarInfo], _ client: CalDAVClient
    ) async throws(SyncError) {
        guard let target = try createTarget(change, calendars),
            !(try await adoptsServerCopy(change, target, calendars: calendars, client))
        else { return }
        let later = Array(change.edits.dropFirst())
        let schedules = try stored { try store.serverSchedules(account.id) }
        let (start, sendsAnswer) = Self.createStart(later, target.calendar, serverSchedules: schedules)
        let edited = sendsAnswer ? start : written(later, onto: start, uid: target.uid)
        let data = ICalendarWriter.write(edited)
        let answer: PutAnswer
        do {
            answer = try await client.put(data, at: target.href, ifMatch: nil)
        } catch .preconditionFailed {
            guard case let .found(server) = try await fetch(target.href, client), let held = Self.parse(server.data),
                EventMapping.series(held).first?.uid == target.uid
            else {
                try failed(change)
                return
            }
            guard !later.isEmpty else {
                let found = PutAnswer(etag: server.etag, scheduleTag: server.scheduleTag)
                try await sent(change, target.href, found, server.data, client)
                return
            }
            let merged = merging(later, start: target.calendar, over: held, uid: target.uid)
            try await put(merged, at: target.href, ifMatch: server.etag, change, client)
            return
        } catch {
            return try await refused(error, change, target.href, client)
        }
        guard sendsAnswer else { return try await sent(change, target.href, answer, data, client) }
        // With its ETag unknown, or moved on since, the next round finds the create there and writes
        // the answer over it.
        guard let etag = try await landedETag(answer, target.href, client) else { return }
        try await put(
            written(later, onto: start, uid: target.uid), at: target.href, ifMatch: etag, change, client,
            overCreate: true)
    }

    /// `scheduleTag`: the object's, read just before, for a server that leaves it out of the answer.
    /// `overCreate`: the write follows a create that landed, or a write refused once already; refused,
    /// it is left queued for the next round, which writes it over what the server then holds.
    func put(
        _ calendar: ICalComponent, at href: URL, ifMatch etag: String?, _ change: QueuedEventChange,
        _ client: CalDAVClient, scheduleTag: String? = nil, overCreate: Bool = false
    ) async throws(SyncError) {
        let data = ICalendarWriter.write(calendar)
        let answer: PutAnswer
        do {
            answer = try await client.put(data, at: href, ifMatch: etag)
        } catch .preconditionFailed where overCreate {
            return
        } catch {
            try await refused(error, change, href, client)
            return
        }
        let known = PutAnswer(etag: answer.etag, scheduleTag: answer.scheduleTag ?? scheduleTag)
        try await sent(change, href, known, data, client)
    }

    /// Records a write the server took, with the `Schedule-Tag` it answered with.
    func sent(
        _ change: QueuedEventChange, _ href: URL, _ answer: PutAnswer, _ data: Data, _ client: CalDAVClient
    ) async throws(SyncError) {
        var (tag, scheduleTag, held) = (answer.etag, answer.scheduleTag, data)
        if tag == nil, case let .found(fresh)? = try? await fetch(href, client) {
            // The server gave no ETag (it may have changed the object as it stored it): read it.
            tag = fresh.etag
            held = fresh.data
            scheduleTag = scheduleTag ?? fresh.scheduleTag
        }
        guard let calendar = Self.parse(held), let series = EventMapping.series(calendar).first else {
            try failed(change)
            return
        }
        // The write landed: a lookup that fails finds no scheduled copy, and the write is recorded.
        let route = ReplyRoute.route(calendar, serverSchedules: try stored { try store.serverSchedules(account.id) })
        let adopted =
            (try? await adoptsScheduledCopy(change, uid: series.uid, at: href, route: route, client))
            ?? false
        try done(
            change, Written(href: href.absoluteString, etag: tag, ics: held, scheduleTag: scheduleTag),
            calendar: calendar, series: series, replies: !adopted)
    }

    private func sendDelete(_ change: QueuedEventChange, _ href: URL, _ client: CalDAVClient) async throws(SyncError) {
        guard let etag = try await knownETag(change, href, client) else {
            return
        }
        let replies = try repliesOnDelete(change)
        do {
            try await client.delete(href, ifMatch: etag, scheduleReply: replies)
        } catch {
            try await refused(error, change, href, client)
            return
        }
        try deleteDone(change)
    }

    /// The owner's delete is done on the server: the event goes, and the guests of the owner's
    /// meeting get their CANCEL.
    private func deleteDone(_ change: QueuedEventChange) throws(SyncError) {
        let mails = try meetingMails(change, now: nil)
        try stored { try store.meetingDeleteDone(change.event, revision: change.revision, mails: mails) }
    }

    /// A delete of an event the server never confirmed. Never sent: dropped here without a request.
    /// Sent but unanswered: the object at the create's place is deleted if it is ours.
    private func deleteUnsent(_ change: QueuedEventChange, _ client: CalDAVClient) async throws(SyncError) {
        guard let kept = try stored({ try store.eventCreateTarget(change.event) }), let href = URL(string: kept.href)
        else {
            try dropped(change)
            return
        }
        let server: RemoteResource
        switch try await fetch(href, client) {
        case .absent:
            try dropped(change)
            return
        case .oversized:
            // It can't be read, so it can't be told to be ours: never treated as gone.
            try failed(change)
            return
        case let .found(found):
            server = found
        }
        let ours = Self.parse(kept.ics).flatMap { EventMapping.series($0).first?.uid }
        guard Self.parse(server.data).flatMap({ EventMapping.series($0).first?.uid }) == ours else {
            try dropped(change)
            return
        }
        let replies = try repliesOnDelete(change)
        do {
            try await client.delete(href, ifMatch: server.etag, scheduleReply: replies)
        } catch {
            try await refused(error, change, href, client)
            return
        }
        try dropped(change)
    }

    static func isGuestAnswer(_ edit: EventEdit) -> Bool {
        if case .guestAnswer = edit { return true }
        return false
    }

    private func dropped(_ change: QueuedEventChange) throws(SyncError) {
        try stored { try store.dropEventChange(change.event, revision: change.revision) }
    }

    /// The ETag to send with an update or delete. When none is held (the server gave none for an
    /// object made here), the server's object stands in only if it is still what was sent; otherwise
    /// it is a conflict, or, if the object is gone, a failed update or a finished delete. Nil: handled.
    private func knownETag(
        _ change: QueuedEventChange, _ href: URL, _ client: CalDAVClient
    ) async throws(SyncError) -> String? {
        if let etag = change.etag, !etag.isEmpty {
            return etag
        }
        guard let server = try await held(href, change, client) else {
            return nil
        }
        if server.data == change.ics {
            return server.etag
        }
        try conflicted(change, server)
        return nil
    }

    /// A refused write: a 412 keeps both versions, a refusal for good (a calendar gone, a read-only
    /// one) marks the change failed, anything else (the connection, the server's trouble, the login)
    /// stops the queue.
    private func refused(
        _ error: DAVError, _ change: QueuedEventChange, _ href: URL, _ client: CalDAVClient
    ) async throws(SyncError) {
        if change.object != change.ics, try await organiserChangeRefused(error, change, href, client) {
            return
        }
        switch error {
        case .preconditionFailed where change.href != nil:
            guard let server = try await held(href, change, client) else {
                return
            }
            // The write got there and its answer was lost (or the app stopped before recording it):
            // the server holds the owner's answer or reminder already. Done, not a conflict.
            if holdsAlready(change, server) {
                let found = PutAnswer(etag: server.etag, scheduleTag: server.scheduleTag)
                try await sent(change, href, found, server.data, client)
                return
            }
            // Guests' answers alone change one ATTENDEE's PARTSTAT each: written over the server's
            // version, never the owner's conflict.
            if change.edits.allSatisfy(Self.isGuestAnswer), let calendar = Self.parse(server.data),
                let uid = EventMapping.series(calendar).first?.uid {
                try await put(
                    written(change.edits, onto: calendar, uid: uid), at: href, ifMatch: server.etag, change, client,
                    overCreate: true)
                return
            }
            try conflicted(change, server)
        case .preconditionFailed, .notFound, .attendeeChangeRefused:
            try failed(change)
        case let .status(code) where (400..<500).contains(code) && ![408, 423, 429].contains(code):
            try failed(change)
        default:
            throw .dav(error)
        }
    }

    /// The server's object at `href`. Gone: a delete is done, anything else failed. Past the size cap
    /// (it can't be read): the change failed, never taken for gone. Nil: handled.
    func held(
        _ href: URL, _ change: QueuedEventChange, _ client: CalDAVClient
    ) async throws(SyncError) -> RemoteResource? {
        switch try await fetch(href, client) {
        case let .found(server):
            return server
        case .absent:
            try gone(change)
        case .oversized:
            try failed(change)
        }
        return nil
    }

    /// The object is no longer on the server: a delete is done, anything else failed.
    private func gone(_ change: QueuedEventChange) throws(SyncError) {
        if change.isDelete {
            try deleteDone(change)
        } else {
            try failed(change)
        }
    }

    func failed(_ change: QueuedEventChange) throws(SyncError) {
        try stored { try store.eventChangeFailed(change.event, revision: change.revision) }
    }

    private func conflicted(_ change: QueuedEventChange, _ server: RemoteResource) throws(SyncError) {
        guard let series = Self.parse(server.data).flatMap({ EventMapping.series($0).first }) else {
            // The server's version cannot be read: the owner's stays, the change marked failed.
            try failed(change)
            return
        }
        try stored {
            try store.eventChangeConflicted(
                change.event, server: (etag: server.etag, ics: server.data, series: series),
                scheduleTag: server.scheduleTag)
        }
    }

    /// The server's object at `href`: there, past the size cap, or not there.
    func fetch(_ href: URL, _ client: CalDAVClient) async throws(SyncError) -> ServerCopy {
        let calendar = href.deletingLastPathComponent()
        let fetched = try await dav { () async throws(DAVError) in try await client.fetch(calendar, hrefs: [href]) }
        if let found = fetched.found.first {
            return .found(found)
        }
        return fetched.oversized.isEmpty ? .absent : .oversized
    }

    static func parse(_ data: Data) -> ICalComponent? {
        try? ICalendarReader.calendar(data)
    }

    /// A calendar's address as a folder (ending in a slash), so an object name resolves inside it.
    static func folder(_ href: String) -> URL? {
        URL(string: href.hasSuffix("/") ? href : href + "/")
    }
}
