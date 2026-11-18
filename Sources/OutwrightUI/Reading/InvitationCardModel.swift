// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Observation
import OutwrightMIME
import OutwrightModel
import OutwrightStore
import OutwrightSync

/// Why an answer, a removal or a retry did not go through.
enum InvitationError: Error, Equatable {
    case store
    /// The event cannot be answered or removed (not an invitation, a read-only calendar).
    case readOnly
    /// The account has no Drafts folder yet, where the reply mail is kept until it is sent.
    case noDraftsFolder

    init(_ error: StoreError) {
        switch error {
        case .readOnly: self = .readOnly
        case .noSuchFolder: self = .noDraftsFolder
        default: self = .store
        }
    }
}

/// What the meeting card above an invitation message says.
enum Headline: Equatable {
    /// "Maja Ek invited you".
    case invited
    /// The organiser changed the meeting; when its time moved, the owner is asked again.
    case updated(timeMoved: Bool)
    case cancelled
    /// Someone answered the owner's own meeting.
    case replied(name: String, response: Attendee.Response)
    /// A newer version of the meeting came since this message.
    case outdated
}

/// The meeting card of a message read as an invitation (REQUEST, ADD, CANCEL or REPLY), from the store:
/// the meeting as the calendar holds it, the owner's calendar around its time, and the answers. A
/// message that changed nothing (its sender is not the organiser, it came to Junk) shows no card: it is
/// an ordinary message. Everything shown is the sender's text, data only.
@Observable @MainActor
final class InvitationCardModel {
    private(set) var state: InvitationState?
    /// The occurrence the message is about, as the calendar holds it now.
    private(set) var event: CalendarEvent?
    /// The owner's timed events overlapping the hour before the meeting to the hour after it.
    private(set) var around: [CalendarEvent] = []
    /// The meeting's calendar, which takes the answer when it is writable.
    private(set) var calendar: CalendarInfo?
    /// What was last shown: a cancelled meeting removed from the calendar is still named on the card.
    private var shown: CalendarEvent?
    private var series: EventSeries?
    /// "Don't send a response" can be kept for this copy (`ReplyRoute.canWithholdReply`).
    private var withholdable = false
    private var colors: [CalendarID: Int] = [:]
    /// The message: its sender (for a REPLY, the attendee who answered) and subject.
    private var row: MessageRow?
    private var sender: Address? { row?.from }

    @ObservationIgnored private let app: AppModel
    @ObservationIgnored let message: MessageID
    @ObservationIgnored let phone: Calendar

    init(app: AppModel, message: MessageID, calendar: Calendar = .autoupdatingCurrent) {
        self.app = app
        self.message = message
        phone = calendar
        reload()
    }

    /// Follows the store while the card is on screen: an answer, a sync or the intake of the message
    /// shows. Until the task is cancelled.
    func observe() async {
        do {
            for try await _ in app.store.observeCalendars() { reload() }
        } catch {
            return
        }
    }

    func reload() {
        guard let found = try? app.store.invitation(for: message) else { return }
        state = found
        if row == nil { row = try? app.store.message(message) }
        let current = found.event.map { occurrence(of: $0, at: found.recurrenceID) }
        event = current
        if let current { shown = current }
        guard let current else {
            around = []
            return
        }
        calendar = (try? app.store.allCalendars())?.first { $0.id == current.calendarID }
        withholdable = ReplyRoute.canWithholdReply(
            copy: (try? app.store.eventObject(current.id)) ?? nil,
            onServer: (try? app.store.isOnServer(current.id)) ?? true,
            serverSchedules: current.accountID.flatMap { try? app.store.serverSchedules($0) } ?? true)
        around = neighbours(of: current)
        let chosen = CalendarColors.chosen(.standard)
        colors = Dictionary(
            ((try? app.store.allCalendars()) ?? []).map { ($0.id, CalendarColors.applied($0, chosen).color) },
            uniquingKeysWith: { first, _ in first })
    }

    /// A calendar's colour (0xRRGGBB).
    func color(of id: CalendarID) -> Int { colors[id] ?? 0x8A8F98 }

    /// The store matches an occurrence by the very form of its time: one the message names in another
    /// form (a zone's wall time where the calendar holds UTC) is found here by its instant.
    private func occurrence(of found: CalendarEvent, at time: EventTime?) -> CalendarEvent {
        series = try? app.store.series(found.id)
        guard let time, found.occurrence.recurrenceID != time else { return found }
        let zones = series?.zones ?? [:]
        guard let instant = time.instant(in: phone.timeZone, zones: zones) else { return found }
        let zone = phone.timeZone
        if let own = series?.overrides.first(where: { $0.recurrenceID.instant(in: zone, zones: zones) == instant }),
            let held = try? app.store.event(found.id, occurrence: own.recurrenceID) {
            return held
        }
        let near = (try? app.store.occurrences(from: instant, to: instant.addingTimeInterval(1), in: nil)) ?? []
        return near.first {
            $0.id == found.id && $0.occurrence.recurrenceID?.instant(in: phone.timeZone, zones: zones) == instant
        } ?? found
    }

    /// The owner's other timed events from an hour before the meeting to an hour after it.
    private func neighbours(of meeting: CalendarEvent) -> [CalendarEvent] {
        guard let range = stripRange(of: meeting) else { return [] }
        let events = (try? app.store.occurrences(from: range.lowerBound, to: range.upperBound, in: nil)) ?? []
        return events.filter { $0.id != meeting.id && $0.occurrence.allDayStart == nil }
    }

    /// The hours the strip shows: the meeting's, an hour either side; nil for an all-day meeting.
    func stripRange(of meeting: CalendarEvent? = nil) -> ClosedRange<Date>? {
        guard let occurrence = (meeting ?? shown)?.occurrence, occurrence.allDayStart == nil else { return nil }
        let start = occurrence.start.addingTimeInterval(-3_600)
        return start...max(occurrence.end, occurrence.start).addingTimeInterval(3_600)
    }

    // MARK: What the card shows

    /// A message that changed the calendar (shown from its record when the event has gone since), or
    /// a REPLY that names who answered a meeting the calendar holds, the account organises, and that
    /// lists the one who answered. Any other REPLY is an ordinary message.
    var isShown: Bool {
        guard let state else { return false }
        if state.method == .reply { return isTrustedReply(state) }
        return state.wasApplied
    }

    private func isTrustedReply(_ state: InvitationState) -> Bool {
        guard let reply = state.reply, let event,
            let account = app.accounts.first(where: { $0.id == event.accountID })
        else { return false }
        let details = event.occurrence.details
        return EventOwnership.isOrganizer(details, accountEmail: account.email)
            && details.attendees.contains { $0.email.lowercased() == reply.email.lowercased() }
    }

    var headline: Headline {
        guard let state else { return .invited }
        if state.method == .reply, let reply = state.reply {
            return .replied(name: name(of: reply.email), response: reply.response)
        }
        if state.isOutdated { return .outdated }
        if state.method == .cancel { return .cancelled }
        // Whether the time moved is known only for an update the phone applied.
        if state.isUpdate { return .updated(timeMoved: state.timeMoved ?? false) }
        return .invited
    }

    /// The meeting shown: the occurrence the message is about, or the one last held.
    var meeting: CalendarEvent? { event ?? shown }

    /// The meeting's title as the calendar holds it, else as the message's iCalendar gave it, else the
    /// message's subject.
    var title: String {
        if let held = meeting?.occurrence.details.title { return held }
        if let given = state?.title, !given.isEmpty { return given }
        return row?.subject ?? ""
    }
    var place: String { meeting?.occurrence.details.place ?? "" }
    var isTentative: Bool { event?.isTentative ?? false }

    var timeText: String {
        guard let occurrence = meeting?.occurrence else { return "" }
        return EventText.time(occurrence, in: phone)
    }

    /// The time in the meeting's own zone, when that zone's clock differs from the phone's.
    var zoneNote: String? {
        guard let occurrence = meeting?.occurrence else { return nil }
        return EventText.zoneNote(occurrence, zones: series?.zones ?? [:], phone: phone)
    }

    /// The organiser's name (from their attendee line), else their address; empty when there is none.
    var organizer: String {
        guard let email = meeting?.occurrence.details.organizer else { return "" }
        return name(of: email)
    }

    /// An attendee's name as the meeting holds it, else as the message's sender gave it, else the address.
    private func name(of email: String) -> String {
        let line = meeting?.occurrence.details.attendees.first { $0.email.lowercased() == email.lowercased() }
        var name = line?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if name.isEmpty, let sender, sender.email.lowercased() == email.lowercased() {
            name = sender.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        return name.isEmpty ? email : name
    }

    /// The owner's own answer, when the owner is an attendee.
    var response: Attendee.Response? { event?.ownResponse }

    private var isWritable: Bool { calendar.map { !$0.isReadOnly } ?? false }

    /// Accept, Tentative and Decline (and, once answered, a change of answer): the current version of a
    /// meeting the owner is invited to, not called off, in a writable calendar.
    var canAnswer: Bool {
        guard isShown, let state, state.method == .request || state.method == .add, !state.isOutdated,
            let event
        else { return false }
        return event.isInvitation && !event.isCancelled && isWritable
    }

    /// Remove from calendar, for the cancellation of a meeting the calendar still holds.
    var canRemove: Bool {
        guard isShown, let state, state.method == .cancel, !state.isOutdated, let event else { return false }
        return event.isCancelled && !event.isEditable && isWritable
    }

    /// "Don't send a response" is offered where the server will not send one, and over Graph, which
    /// takes `sendResponse: false`.
    var canWithholdReply: Bool {
        withholdable || app.accounts.first { $0.id == event?.accountID }?.calendarVia == .graph
    }

    /// A comment can go with the answer wherever the reply can be kept back: the app writes it, or Graph.
    var canComment: Bool { canWithholdReply }

    /// For a message about one occurrence of a series: that occurrence, which the answer asks to choose
    /// between it and the whole series. Nil when the message holds the whole event.
    var occurrenceScope: EditScope? {
        guard state?.recurrenceID != nil, let event, event.isSeries, let time = event.occurrence.recurrenceID
        else { return nil }
        return .occurrence(time)
    }

    /// The server took the owner's answer, but its reply mail could not be sent: Retry sends it.
    var replyFailed: Bool { event?.replyFailed ?? false }

    /// The owner chose not to send a response, and the server sent one anyway (it had scheduled the
    /// copy since the card offered the choice).
    var replySentByServer: Bool { event?.replySentByServer ?? false }

    // MARK: Actions

    /// Answers the meeting, for the occurrence or the whole event. A reply always goes where the owner
    /// cannot keep it back (the server sends it). The owner's `comment` goes with the reply.
    func answer(
        _ response: Attendee.Response, sendReply: Bool, scope: EditScope, comment: String? = nil
    ) throws(InvitationError) {
        guard let id = event?.id else { return }
        let sends = sendReply || !canWithholdReply
        try change { () throws(StoreError) in
            try app.store.respond(id, response, scope: scope, sendReply: sends, comment: sends ? comment : nil)
        }
    }

    /// Takes the cancelled meeting out of the calendar.
    func removeFromCalendar() throws(InvitationError) {
        guard let id = event?.id else { return }
        try change { () throws(StoreError) in try app.store.removeCancelled(id) }
    }

    /// Queues the owner's current answer again, for the reply that could not be sent.
    func retryReply() throws(InvitationError) {
        guard let id = event?.id else { return }
        try change { () throws(StoreError) in try app.store.retryEventReply(id) }
    }

    private func change(_ body: () throws(StoreError) -> Void) throws(InvitationError) {
        do {
            try body()
        } catch {
            throw InvitationError(error)
        }
        reload()
    }
}
