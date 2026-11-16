// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightGraph
import OutwrightModel
import OutwrightStore

extension GraphCalendarSyncer {
    /// Sends the owner's queued changes in order, with `CalendarSyncer`'s outcomes: a refusal for good
    /// fails the change, a 412 keeps both versions, the connection, the sign-in or throttling stops the
    /// queue (the rest stays queued), and server trouble fails a change only after
    /// `CalendarSyncer.serverAttempts` tries.
    func runQueue(_ client: GraphClient) async throws(SyncError) {
        let pending = try stored { try store.pendingEventChanges(account.id) }.map {
            QueuedEventChange(
                event: $0.event, edits: $0.edits, href: $0.href, etag: $0.etag, ics: $0.ics, calendar: $0.calendar,
                revision: $0.revision, object: nil)
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
                guard attempts >= CalendarSyncer.serverAttempts else { throw error }
                try failed(change)
            }
        }
    }

    private func send(
        _ change: QueuedEventChange, calendars: [CalendarInfo], _ client: GraphClient
    ) async throws(SyncError) {
        do throws(SyncError) {
            if change.isDelete {
                try await sendDelete(change, calendars: calendars, client)
                return
            }
            guard let local = try stored({ try store.series(change.event) }) else {
                try failed(change)
                return
            }
            var target: Target
            var later = change.edits
            if let id = Self.id(change.href) {
                guard let held = change.ics, let etag = GraphCalendars.event(held)?.etag else {
                    // Without Graph's copy an edit can't tell what changed, nor its ETag.
                    try failed(change)
                    return
                }
                target = Target(
                    id: id, etag: etag, held: mapped(held), wantsResponse: GraphCalendars.wantsResponse(held))
            } else {
                guard let made = try await create(change, local, calendars: calendars, client) else { return }
                target = made
                // The create sent the series as it stands; what is left are its occurrences' edits.
                later = change.edits.filter(\.isOccurrenceEdit)
            }
            for edit in later {
                try await apply(edit, to: &target, local: local, client)
            }
            try await done(change, id: target.id, isSeries: local.rule != nil, client)
        } catch {
            try await refused(error, change, client)
        }
    }

    /// The event being written: its id, its current ETag, and Graph's version of it.
    struct Target {
        var id: String
        var etag: String
        var held: EventSeries?
        /// The organiser asked for answers (Graph's `responseRequested`; true when not said).
        var wantsResponse = true
    }

    /// Where a create goes and under which create id, and whether it was sent before.
    struct CreatePlace {
        let calendar: GraphCalendar
        let createID: String
        let sentBefore: Bool
    }

    // MARK: - Create

    /// Creates the event as the owner has it now, under the create id chosen at its first send. Sent
    /// before (its answer lost), the event made then is looked for by that id and brought up to date
    /// instead. Nil when the change was marked failed.
    private func create(
        _ change: QueuedEventChange, _ local: EventSeries, calendars: [CalendarInfo], _ client: GraphClient
    ) async throws(SyncError) -> Target? {
        guard let base = local.base, let place = try createPlace(change, calendars) else {
            try failed(change)
            return nil
        }
        let zone = phoneZone()
        if place.sentBefore, let earlier = try await graph({ () async throws(GraphError) in
            try await client.findEvent(createID: place.createID, in: place.calendar)
        }) {
            let held = GraphEventMapping.series(earlier.data, ownEmail: account.email)
            let body = GraphEventMapping.body(base, rule: local.rule, over: (held?.base, held?.rule), phoneZone: zone)
            guard !body.isEmpty else { return Target(id: earlier.id, etag: earlier.etag, held: held) }
            let updated = try await graph { () async throws(GraphError) in
                try await client.updateEvent(id: earlier.id, body, ifMatch: earlier.etag)
            }
            return Target(id: updated.id, etag: updated.etag, held: mapped(updated.data))
        }
        let body = GraphEventMapping.body(base, rule: local.rule, over: nil, phoneZone: zone)
        let made = try await graph { () async throws(GraphError) in
            try await client.createEvent(body, createID: place.createID, in: place.calendar)
        }
        return Target(id: made.id, etag: made.etag, held: mapped(made.data))
    }

    /// The create's place: kept from an earlier send, else chosen and kept now, as
    /// `<calendar path>#<create id>` in the store's create slot.
    private func createPlace(
        _ change: QueuedEventChange, _ calendars: [CalendarInfo]
    ) throws(SyncError) -> CreatePlace? {
        if let kept = try stored({ try store.eventCreateTarget(change.event) }) {
            guard let kept = Self.createTarget(kept.href), let home = calendars.first(where: { $0.href == kept.path })
            else { return nil }
            return CreatePlace(calendar: Self.calendar(home), createID: kept.createID, sentBefore: true)
        }
        guard let home = calendars.first(where: { $0.id == change.calendar }) else {
            return nil
        }
        let createID = UUID().uuidString.lowercased()
        do {
            try store.setEventCreateTarget(change.event, href: home.href + "#" + createID, ics: Data())
        } catch .noSuchEvent {
            return nil
        } catch {
            throw .store(String(describing: error))
        }
        return CreatePlace(calendar: Self.calendar(home), createID: createID, sentBefore: false)
    }

    /// The Graph calendar a stored one is (its href is `me/calendars/<id>`).
    static func calendar(_ info: CalendarInfo) -> GraphCalendar {
        let id = info.href.split(separator: "/").last.map(String.init) ?? ""
        return GraphCalendar(
            id: id.removingPercentEncoding ?? id, name: info.name, color: info.color, canEdit: !info.isReadOnly,
            isDefault: info.isDefault)
    }

    // MARK: - Edits

    /// One edit sent: the whole event's to the event (only what differs from Graph's version), an
    /// occurrence's to its instance.
    private func apply(
        _ edit: EventEdit, to target: inout Target, local: EventSeries, _ client: GraphClient
    ) async throws(SyncError) {
        let zone = phoneZone()
        switch edit {
        case .create, .delete(.event), .guestAnswer, .organiserChange:
            // Exchange takes a guest's answer and the organiser's changes itself.
            return
        case .respond, .ownReminder:
            try await applyInvitee(edit, to: &target, local: local, client)
        case let .update(details, rule, .event):
            let body = GraphEventMapping.body(
                details, rule: rule, over: (target.held?.base, target.held?.rule), phoneZone: zone)
            guard !body.isEmpty else { return }
            let (id, etag) = (target.id, target.etag)
            let updated = try await graph { () async throws(GraphError) in
                try await client.updateEvent(id: id, body, ifMatch: etag)
            }
            target = Target(id: updated.id, etag: updated.etag, held: mapped(updated.data))
        case let .update(details, _, .occurrence(time)):
            guard let instance = try await instance(of: target.id, at: time, zones: local.zones, client) else {
                throw .graph(.notFound)
            }
            let over = target.held?.overrides.first { $0.recurrenceID == time }?.details ?? target.held?.base
            let body = GraphEventMapping.body(details, rule: nil, over: (over, nil), phoneZone: zone)
            guard !body.isEmpty else { return }
            _ = try await graph { () async throws(GraphError) in
                try await client.updateEvent(id: instance, body, ifMatch: nil)
            }
            try await refreshETag(&target, client)
        case let .delete(.occurrence(time)):
            // Already gone (deleted elsewhere, or by an earlier try of this change): done.
            guard let instance = try await instance(of: target.id, at: time, zones: local.zones, client) else {
                return
            }
            try await graph { () async throws(GraphError) in
                try await client.deleteEvent(id: instance, ifMatch: nil)
            }
            try await refreshETag(&target, client)
        }
    }

    /// An occurrence's change gives the series event a new version: a whole-event edit after it
    /// matches that one, not the one held before.
    func refreshETag(_ target: inout Target, _ client: GraphClient) async throws(SyncError) {
        let id = target.id
        if let fresh = try await graph({ () async throws(GraphError) in try await client.event(id: id) }) {
            target.etag = fresh.etag
        }
    }

    /// The id of the occurrence of a series that started at `time` (its RECURRENCE-ID); nil when
    /// Graph has none. An occurrence never changed has no version of its own, so its writes go
    /// without If-Match.
    func instance(
        of series: String, at time: EventTime, zones: [String: ZoneRules], _ client: GraphClient
    ) async throws(SyncError) -> String? {
        // An all-day occurrence is its date (Graph's start is that date's midnight in the event's zone,
        // as UTC, within twelve hours of midnight UTC); a timed one is its instant.
        let utc = TimeZone(identifier: "UTC") ?? .current
        guard let instant = time.instant(in: time.isAllDay ? utc : phoneZone(), zones: zones) else { return nil }
        let found = try await graph { () async throws(GraphError) in
            try await client.instances(
                of: series, from: instant.addingTimeInterval(-2 * 86_400), to: instant.addingTimeInterval(2 * 86_400))
        }
        if time.isAllDay {
            return found.first { abs($0.originalStart.timeIntervalSince(instant)) <= 12 * 3_600 }?.id
        }
        return found.first { abs($0.originalStart.timeIntervalSince(instant)) < 60 }?.id
    }

    // MARK: - Delete

    /// A delete. An event never confirmed by Graph is looked for by its create id when it was sent;
    /// one Graph no longer has counts as deleted.
    private func sendDelete(
        _ change: QueuedEventChange, calendars: [CalendarInfo], _ client: GraphClient
    ) async throws(SyncError) {
        var target: (id: String, etag: String?)?
        if let id = Self.id(change.href) {
            target = (id, change.ics.flatMap(GraphCalendars.event)?.etag)
        } else if let kept = try stored({ try store.eventCreateTarget(change.event) }) {
            if let kept = Self.createTarget(kept.href), let home = calendars.first(where: { $0.href == kept.path }),
                let found = try await graph({ () async throws(GraphError) in
                    try await client.findEvent(createID: kept.createID, in: Self.calendar(home))
                }) {
                target = (found.id, found.etag)
            }
        }
        if let target {
            try await graph { () async throws(GraphError) in
                try await client.deleteEvent(id: target.id, ifMatch: target.etag)
            }
        }
        try stored { try store.dropEventChange(change.event, revision: change.revision) }
    }

    // MARK: - Outcomes

    /// Graph took the change: its version of the event is fetched and held.
    private func done(
        _ change: QueuedEventChange, id: String, isSeries: Bool, _ client: GraphClient
    ) async throws(SyncError) {
        guard let fresh = try await fetch(id, isSeries: isSeries, client),
            let series = GraphEventMapping.series(fresh.data, ownEmail: account.email)
        else {
            // Graph takes a declined meeting out of the calendar: the answer went.
            if try declinedAndGone(change) { return }
            try failed(change)
            return
        }
        try stored {
            try store.eventChangeDone(
                change.event, revision: change.revision, href: Self.href(id), etag: Self.version(fresh.data),
                ics: fresh.data, series: series, scheduleTag: nil)
        }
    }

    private func fetch(
        _ id: String, isSeries: Bool, _ client: GraphClient
    ) async throws(SyncError) -> GraphEventData? {
        try await graph { () async throws(GraphError) in
            isSeries ? try await client.series(id: id) : try await client.event(id: id)
        }
    }

    /// A refused write: a 412 keeps both versions (a delete of an event Graph no longer has is done),
    /// a 404 fails an update and finishes a delete, a refusal for good fails the change; anything else
    /// is thrown.
    private func refused(
        _ error: SyncError, _ change: QueuedEventChange, _ client: GraphClient
    ) async throws(SyncError) {
        guard case let .graph(graph) = error else { throw error }
        switch graph {
        case .preconditionFailed:
            let isSeries = change.ics.flatMap { GraphEventMapping.series($0) }?.rule != nil
            guard let id = Self.id(change.href), let server = try await fetch(id, isSeries: isSeries, client),
                let series = GraphEventMapping.series(server.data, ownEmail: account.email)
            else {
                if change.isDelete {
                    try stored { try store.dropEventChange(change.event, revision: change.revision) }
                } else {
                    try failed(change)
                }
                return
            }
            try stored {
                try store.eventChangeConflicted(
                    change.event, server: (etag: Self.version(server.data), ics: server.data, series: series))
            }
        case .notFound where change.isDelete:
            try stored { try store.dropEventChange(change.event, revision: change.revision) }
        case .notFound where change.edits.contains(where: \.declines):
            // The meeting (or the occurrence) gone before the decline came: nothing is left to decline.
            if try !declinedAndGone(change) { try failed(change) }
        case _ where GraphContactSyncer.refusedForGood(graph):
            try failed(change)
        default:
            throw error
        }
    }

    /// A change with a decline whose meeting Graph no longer holds is done, as the owner has it; the
    /// next sync takes the event (or the occurrence) away. False when it is not such a change.
    private func declinedAndGone(_ change: QueuedEventChange) throws(SyncError) -> Bool {
        guard change.edits.contains(where: \.declines), let href = change.href, let ics = change.ics,
            let local = try stored({ try store.series(change.event) })
        else { return false }
        try stored {
            try store.eventChangeDone(
                change.event, revision: change.revision, href: href, etag: change.etag, ics: ics, series: local,
                scheduleTag: nil)
        }
        return true
    }

    private func failed(_ change: QueuedEventChange) throws(SyncError) {
        try stored { try store.eventChangeFailed(change.event, revision: change.revision) }
    }

    /// The Graph id of a held event's href (`me/events/<id>`).
    static func id(_ href: String?) -> String? {
        guard let href, href.hasPrefix("me/events/") else { return nil }
        let id = String(href.dropFirst("me/events/".count))
        return id.isEmpty ? nil : id
    }

    /// An event's version as the listing tells it: its change key, with its exceptions' ids and keys.
    static func version(_ data: Data) -> String {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return "" }
        let key = (object["changeKey"] as? String) ?? ""
        guard object["recurrence"] is [String: Any] else { return key }
        let exceptions = ((object["exceptionOccurrences"] as? [Any]) ?? []).compactMap { entry -> String? in
            guard let entry = entry as? [String: Any], let id = entry["id"] as? String else { return nil }
            return id + ":" + ((entry["changeKey"] as? String) ?? "")
        }
        return ([key] + exceptions.sorted()).joined(separator: "|")
    }
}

extension EventEdit {
    /// An edit of one occurrence (not of the whole event or series).
    var isOccurrenceEdit: Bool {
        switch self {
        case .update(_, _, .occurrence), .delete(.occurrence): true
        default: false
        }
    }
}
