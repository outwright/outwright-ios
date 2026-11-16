// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightDAV
import OutwrightModel

/// The organiser's change from mail, held apart (`appliedIcs`) and written to the owner's copy on the
/// server (RFC 6638 › 3.2.2.2), when the server does not take the write.
extension CalendarSyncer {
    /// A write made onto the organiser's change, refused. A 412 for the organiser's change itself: the
    /// server's copy moved on. As new as the organiser's change, the server applied it (› 4.1, an
    /// organiser on the same server): the owner's other edits go onto the server's copy, and with none
    /// the change is settled. Older: the organiser's change is written over it once. A forbidden
    /// attendee change (› 3.2.2.1): the server keeps its copy, the owner's other edits go onto it, and
    /// the organiser's change stays shown. False when the refusal is none of these.
    func organiserChangeRefused(
        _ error: DAVError, _ change: QueuedEventChange, _ href: URL, _ client: CalDAVClient
    ) async throws(SyncError) -> Bool {
        guard let object = change.object, let own = Self.parse(object),
            let uid = EventMapping.series(own).first?.uid
        else { return false }
        let others = change.edits.filter { $0 != .organiserChange }
        switch error {
        case .preconditionFailed where change.edits.contains(.organiserChange):
            guard let server = try await held(href, change, client) else { return true }
            guard !holdsAlready(change, server), let onServer = Self.parse(server.data) else { return false }
            if Self.topSequence(onServer, uid: uid) < Self.topSequence(own, uid: uid) {
                let over = ITIP.keepingOwn(own, from: onServer, ownEmail: account.email)
                try await put(
                    written(change.edits, onto: over, uid: uid), at: href, ifMatch: server.etag, change, client,
                    overCreate: true)
            } else if others.isEmpty {
                try stored { try store.settleOrganiserChange(change.event, revision: change.revision) }
            } else {
                try await put(
                    written(others, onto: onServer, uid: uid), at: href, ifMatch: server.etag, change, client,
                    overCreate: true)
            }
            return true
        case .attendeeChangeRefused:
            guard !others.isEmpty else {
                try stored { try store.settleOrganiserChange(change.event, revision: change.revision) }
                return true
            }
            try await writeOnlyOwnEdits(others, change, href, own: own, client)
            return true
        case let .status(code) where others.isEmpty && (400..<500).contains(code) && ![408, 423, 429].contains(code):
            // Refused for good (a calendar that turned read-only): the change stays shown on the phone.
            try stored { try store.settleOrganiserChange(change.event, revision: change.revision) }
            return true
        default:
            return false
        }
    }

    /// The owner's edits written onto the server's copy, which refused the organiser's change; then
    /// the organiser's change, with those edits on it, is held and shown again.
    private func writeOnlyOwnEdits(
        _ edits: [EventEdit], _ change: QueuedEventChange, _ href: URL, own: ICalComponent, _ client: CalDAVClient
    ) async throws(SyncError) {
        guard let uid = EventMapping.series(own).first?.uid,
            let server = try await held(href, change, client)
        else { return }
        guard let onServer = Self.parse(server.data) else {
            try failed(change)
            return
        }
        let data = ICalendarWriter.write(written(edits, onto: onServer, uid: uid))
        let scheduled = try await scheduleTagSince(change, href, client)
        let answer: PutAnswer
        do {
            answer = try await client.put(data, at: href, ifMatch: server.etag)
        } catch .preconditionFailed {
            // Changed again since it was read: the next round writes over what it holds then.
            return
        } catch .attendeeChangeRefused, .notFound {
            try failed(change)
            return
        } catch let .status(code) where (400..<500).contains(code) && ![408, 423, 429].contains(code) {
            try failed(change)
            return
        } catch {
            throw .dav(error)
        }
        let known = PutAnswer(etag: answer.etag, scheduleTag: answer.scheduleTag ?? scheduled)
        try await sent(change, href, known, data, client)
        let kept = written(edits, onto: own, uid: uid)
        guard let series = EventMapping.series(kept).first(where: { $0.uid == uid }) else { return }
        try stored {
            try store.holdOrganiserChange(change.event, ics: ICalendarWriter.write(kept), series: series)
        }
    }

    /// The object a change is written onto: with the organiser's change in it, what is the owner's in
    /// the server's copy kept (`ITIP.keepingOwn`).
    func keepingOwn(_ held: ICalComponent, _ change: QueuedEventChange) -> ICalComponent {
        guard change.edits.contains(.organiserChange), let server = change.ics.flatMap(Self.parse) else { return held }
        return ITIP.keepingOwn(held, from: server, ownEmail: account.email)
    }

    /// The highest SEQUENCE of the object's VEVENTs of `uid`; 0 for none.
    static func topSequence(_ calendar: ICalComponent, uid: String) -> Int {
        guard let series = EventMapping.series(calendar).first(where: { $0.uid == uid }) else { return 0 }
        return ((series.base.map { [$0] } ?? []) + series.overrides.map(\.details)).map(\.sequence).max() ?? 0
    }
}
