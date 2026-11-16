// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightDAV
import OutwrightModel
import OutwrightStore

extension CalendarSyncer {
    /// The create's href, UID and starting object: kept from an earlier send, else chosen and kept now.
    /// Nil when there is nothing to send: the change was marked failed, or a newer edit overtook it.
    func createTarget(
        _ change: QueuedEventChange, _ calendars: [CalendarInfo]
    ) throws(SyncError) -> CreateTarget? {
        if let kept = try stored({ try store.eventCreateTarget(change.event) }), let href = URL(string: kept.href),
            let calendar = Self.parse(kept.ics), let uid = EventMapping.series(calendar).first?.uid {
            return CreateTarget(href: href, uid: uid, calendar: calendar)
        }
        guard let first = change.edits.first, case .create = first,
            let home = calendars.first(where: { $0.id == change.calendar }), let folder = Self.folder(home.href)
        else {
            try failed(change)
            return nil
        }
        let made = EventMapping.apply(first, to: nil, uid: "", organizer: account.email)
        guard let uid = EventMapping.series(made).first?.uid,
            let href = URL(string: MailStore.resourceName(uid) + ".ics", relativeTo: folder)?.absoluteURL
        else {
            try failed(change)
            return nil
        }
        do {
            try store.setEventCreateTarget(change.event, href: href.absoluteString, ics: ICalendarWriter.write(made))
        } catch .noSuchEvent {
            return nil
        } catch {
            throw .store(String(describing: error))
        }
        return CreateTarget(href: href, uid: uid, calendar: made)
    }
}
