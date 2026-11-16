// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightDAV
import OutwrightModel
import OutwrightStore

/// Never two copies of one meeting on the server: the app's own copy of an invitation is created
/// only when the server holds none of its UID.
extension CalendarSyncer {
    /// Before the create of the app's own copy of an invitation: the server's copy of the same UID in
    /// any of the account's writable calendars (a read-only one's copy is
    /// someone else's), other than at the create's own place (an earlier send of
    /// ours, which the create's 412 handles). When there is one it is stored as the event with its ETag and
    /// `Schedule-Tag`, and the app copy gives way to it (`upsertRemote`): the owner's answer and
    /// reminder are queued onto the server's copy, the queued create becomes a delete of a place the
    /// server never had. True when the create is not to be sent.
    func adoptsServerCopy(
        _ change: QueuedEventChange, _ target: CreateTarget, calendars: [CalendarInfo], _ client: CalDAVClient
    ) async throws(SyncError) -> Bool {
        guard try stored({ try store.eventOrigin(change.event) }) == .app else { return false }
        for calendar in calendars where !calendar.isReadOnly {
            guard let folder = Self.folder(calendar.href) else { continue }
            let found = try await dav { () async throws(DAVError) in
                try await client.events(withUID: target.uid, in: folder)
            }
            for object in found where !Self.samePlace(object.href, target.href) {
                guard let parsed = Self.parse(object.data),
                    let series = EventMapping.series(parsed).first(where: { $0.uid == target.uid })
                else { continue }
                let zone = phoneZone()
                try stored {
                    _ = try store.upsertRemote(
                        href: object.href.absoluteString, etag: object.etag, ics: object.data, series: series,
                        in: calendar.id, window: CalendarWindow.window(now: now(), zone: zone), phoneZone: zone,
                        scheduleTag: object.scheduleTag)
                }
                // Stored nothing (no occurrence in the window, say): still never a second copy.
                if try stored({ try store.invitationEvent(accountId: account.id, uid: target.uid) }) == change.event {
                    try stored { try store.eventChangeFailed(change.event, revision: change.revision) }
                }
                return true
            }
        }
        return false
    }

    /// After an answer written onto the app's own copy of an invitation whose replies the app sends
    /// (`ReplyRoute.app`), before its REPLY is queued: the server's scheduled copy of the same
    /// UID in any of the account's writable calendars, other than at `href`. When there is one it is
    /// stored as the event (`upsertRemote`), and the answer is queued onto it, so the server answers
    /// the organiser and the app mails nothing. True when the app's REPLY is not to be queued: an
    /// answer was queued onto the server's copy.
    func adoptsScheduledCopy(
        _ change: QueuedEventChange, uid: String, at href: URL, route: ReplyRoute, _ client: CalDAVClient
    ) async throws(SyncError) -> Bool {
        let owed = change.edits.contains { edit in
            if case .respond(_, _, true) = edit { return true }
            return false
        }
        guard owed, route == .app,
            try stored({ try store.eventOrigin(change.event) }) == .app
        else { return false }
        for calendar in try stored({ try store.calendars(account.id) }) where !calendar.isReadOnly {
            guard let folder = Self.folder(calendar.href) else { continue }
            let found = try await dav { () async throws(DAVError) in try await client.events(withUID: uid, in: folder) }
            for object in found where object.scheduleTag != nil && !Self.samePlace(object.href, href) {
                guard let parsed = Self.parse(object.data),
                    let series = EventMapping.series(parsed).first(where: { $0.uid == uid })
                else { continue }
                let zone = phoneZone()
                try stored {
                    _ = try store.upsertRemote(
                        href: object.href.absoluteString, etag: object.etag, ics: object.data, series: series,
                        in: calendar.id, window: CalendarWindow.window(now: now(), zone: zone), phoneZone: zone,
                        scheduleTag: object.scheduleTag)
                }
                // Stored as another event, and the app copy's answer went over to it.
                guard let taken = try stored({ try store.invitationEvent(accountId: account.id, uid: uid) }),
                    taken != change.event
                else { return false }
                return try answered(taken, with: change)
            }
        }
        return false
    }

    /// The server's copy `taken` has an answer queued: the one the merge carried over, else the owed
    /// answers of `change`, which just landed on the app's copy and so are the owner's latest, queued
    /// here (a copy that holds another answer already keeps it in the merge). False when none could be.
    private func answered(_ taken: EventID, with change: QueuedEventChange) throws(SyncError) -> Bool {
        let carried = try stored({ try store.pendingEventChanges(account.id) }).contains { entry in
            entry.event == taken && entry.edits.contains {
                if case .respond = $0 { return true }
                return false
            }
        }
        if carried { return true }
        var queued = false
        for edit in change.edits {
            guard case let .respond(response, scope, true) = edit else { continue }
            do {
                try store.respond(taken, response, scope: scope, sendReply: true)
                queued = true
            } catch .readOnly, .noSuchEvent {
                continue
            } catch {
                throw .store(String(describing: error))
            }
        }
        return queued
    }

    /// Whether the server may answer the organiser for a delete. Never for the app's own copy of an
    /// invitation: it goes only because the server's copy took its place (or its meeting was called
    /// off), and the server would send a DECLINED for it (RFC 6638 › 8.1, `Schedule-Reply: F`).
    func repliesOnDelete(_ change: QueuedEventChange) throws(SyncError) -> Bool {
        try stored { try store.eventOrigin(change.event) } != .app
    }

    static func samePlace(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.path(percentEncoded: false) == rhs.path(percentEncoded: false)
    }
}
