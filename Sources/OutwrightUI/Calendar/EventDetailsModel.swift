// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
import Observation
public import OutwrightModel
import OutwrightStore
import OutwrightSync

/// A request to show an event's details: one occurrence of it, or the event when it does not recur.
public struct EventRequest: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let event: EventID
    public let occurrence: EventTime?

    public init(id: UUID = UUID(), event: EventID, occurrence: EventTime?) {
        self.id = id
        self.event = event
        self.occurrence = occurrence
    }

    /// From a tapped reminder's `userInfo` (as `SystemReminders` writes it); nil when it names no event.
    public init?(userInfo: [AnyHashable: Any]) {
        let number: Int64? = (userInfo["event"] as? Int64) ?? (userInfo["event"] as? Int).map(Int64.init)
        guard let number else { return nil }
        var occurrence: EventTime?
        if let text = userInfo["occurrence"] as? String, text.utf8.count <= 4_096 {
            occurrence = try? JSONDecoder().decode(EventTime.self, from: Data(text.utf8))
        }
        self.init(event: EventID(raw: number), occurrence: occurrence)
    }
}

/// One event's details as the details sheet shows them; everything in it is the sender's text, data
/// only.
@Observable @MainActor
final class EventDetailsModel {
    private(set) var event: CalendarEvent?
    private(set) var calendar: CalendarInfo?
    private(set) var account: Account?
    private(set) var series: EventSeries?
    /// "Don't send a response" can be kept for this copy (`ReplyRoute.canWithholdReply`).
    private var withholdable = false
    /// The web links in the place and the notes, found once per load.
    private(set) var links: [URL] = []
    /// The store could not be read or watched: the sheet may be out of date, and says so.
    var failed: Bool { readFailed || watchFailed }
    private var readFailed = false
    private var watchFailed = false

    @ObservationIgnored private let app: AppModel
    @ObservationIgnored let request: EventRequest
    @ObservationIgnored let phone: Calendar

    init(app: AppModel, request: EventRequest, calendar: Calendar = .autoupdatingCurrent) {
        self.app = app
        self.request = request
        phone = calendar
        reload()
    }

    /// Follows the store while the sheet is open: a sync's change shows, and an event the server no
    /// longer has goes (the sheet then says so). Until the task is cancelled.
    func observe() async {
        await watch(app.store.observeCalendars())
    }

    /// Reloads for each value of the stream; an error other than the sheet going away shows as `failed`.
    func watch(_ stream: AsyncThrowingStream<Void, any Error>) async {
        do {
            for try await _ in stream { reload() }
        } catch is CancellationError {
            return
        } catch {
            watchFailed = true
        }
    }

    func reload() {
        let found: CalendarEvent?
        do {
            found = try app.store.event(request.event, occurrence: request.occurrence)
            readFailed = false
        } catch {
            // Not read is not gone: what was shown stays, under the banner.
            readFailed = true
            return
        }
        if found != event { event = found }
        guard let found else {
            calendar = nil
            account = nil
            series = nil
            links = []
            return
        }
        calendar = (try? app.store.allCalendars())?.first { $0.id == found.calendarID }
        account = app.accounts.first { $0.id == found.accountID }
        series = try? app.store.series(found.id)
        withholdable = ReplyRoute.canWithholdReply(
            copy: (try? app.store.eventObject(found.id)) ?? nil,
            onServer: (try? app.store.isOnServer(found.id)) ?? true,
            serverSchedules: found.accountID.flatMap { try? app.store.serverSchedules($0) } ?? true)
        links = EventLinks.find(in: found.occurrence.details.place + "\n" + found.occurrence.details.notes)
    }

    var details: EventDetails? { event?.occurrence.details }

    /// The owner may change or delete it: an own event in a writable calendar.
    var canEdit: Bool { event?.isEditable ?? false }

    /// The event repeats: an edit or a delete asks whether it is for this occurrence or the series.
    var isSeries: Bool { event?.isSeries ?? false }

    /// This occurrence alone; nil for an event that does not repeat.
    var occurrenceScope: EditScope? {
        guard isSeries, let time = event?.occurrence.recurrenceID else { return nil }
        return .occurrence(time)
    }

    /// The owner's change the server held a newer version against.
    var conflict: EventEdit? { event?.conflict }

    /// How many changes the conflict holds, all of which Apply again sends; 0 without a conflict.
    var conflictChanges: Int { event?.conflictChanges ?? 0 }

    /// The server refused the owner's last change.
    var changeFailed: Bool { event?.changeFailed ?? false }

    // MARK: An invitation

    /// Someone else's meeting the owner is invited to: answered, not changed.
    var isInvitation: Bool { event?.isInvitation ?? false }

    /// The owner's own answer, when the owner is an attendee.
    var response: Attendee.Response? { event?.ownResponse }

    /// The calendar takes the owner's answer and own reminder.
    private var isWritable: Bool { calendar.map { !$0.isReadOnly } ?? false }

    /// Accept, Tentative and Decline: an invitation the organiser has not called off, in a writable calendar.
    var canAnswer: Bool { isInvitation && isWritable && event?.isCancelled == false }

    /// The owner's own reminder on an invitation can be changed (RFC 6638 lets an attendee).
    var canEditReminder: Bool { isInvitation && isWritable }

    /// Delete on an invitation declines it.
    var canDecline: Bool { canAnswer }

    /// "Don't send a response" is offered only where the app sends the reply itself.
    var canWithholdReply: Bool { withholdable }

    /// The organiser called it off and the owner did not organise it: it can go from the calendar.
    var canRemoveCancelled: Bool { event?.isCancelled == true && !canEdit && isWritable }

    /// The server took the owner's answer, but its reply mail could not be sent: Retry sends it.
    var replyFailed: Bool { event?.replyFailed ?? false }

    /// Answers the invitation, for this occurrence or the whole event. A reply always goes where the
    /// owner cannot keep it back (the server sends it).
    func answer(_ response: Attendee.Response, sendReply: Bool, scope: EditScope) throws(InvitationError) {
        guard let id = event?.id else { return }
        let sends = sendReply || !canWithholdReply
        try invitationChange { () throws(StoreError) in
            try app.store.respond(id, response, scope: scope, sendReply: sends)
        }
    }

    /// The owner's own reminder, in minutes before the start; nil for none.
    func setReminder(_ minutes: Int?, scope: EditScope) throws(InvitationError) {
        guard let id = event?.id else { return }
        try invitationChange { () throws(StoreError) in
            try app.store.setOwnReminder(id, minutes: minutes, scope: scope)
        }
    }

    /// Delete on an invitation: a decline, sent to the organiser.
    func declineByDeleting(scope: EditScope) throws(InvitationError) {
        guard let id = event?.id else { return }
        try invitationChange { () throws(StoreError) in try app.store.declineByDeleting(id, scope: scope) }
    }

    /// Takes a cancelled meeting out of the calendar.
    func removeFromCalendar() throws(InvitationError) {
        guard let id = event?.id else { return }
        try invitationChange { () throws(StoreError) in try app.store.removeCancelled(id) }
    }

    /// Queues the owner's current answer again, for the reply that could not be sent.
    func retryReply() throws(InvitationError) {
        guard let id = event?.id else { return }
        try invitationChange { () throws(StoreError) in try app.store.retryEventReply(id) }
    }

    private func invitationChange(_ change: () throws(StoreError) -> Void) throws(InvitationError) {
        do {
            try change()
        } catch {
            throw InvitationError(error)
        }
        reload()
    }

    /// Queues the delete of the whole event or this occurrence; it is gone from the views at once.
    func delete(scope: EditScope) throws(StoreError) {
        guard let id = event?.id else { return }
        try mutate { () throws(StoreError) in try app.store.deleteEvent(id, scope: scope) }
    }

    /// Sends the owner's change again, over the server's newer version.
    func applyAgain() throws(StoreError) {
        guard let id = event?.id else { return }
        try mutate { () throws(StoreError) in try app.store.applyEventConflictAgain(id) }
    }

    /// Keeps the server's version and drops the owner's change.
    func discard() throws(StoreError) {
        guard let id = event?.id else { return }
        try mutate { () throws(StoreError) in try app.store.discardEventConflict(id) }
    }

    /// Gives up the change the server did not take: the server's version comes back (an event it
    /// never had goes).
    func discardFailedChange() throws(StoreError) {
        guard let id = event?.id else { return }
        try mutate { () throws(StoreError) in try EventRestore.discardFailedChange(id, in: app.store) }
    }

    private func mutate(_ change: () throws(StoreError) -> Void) throws(StoreError) {
        try change()
        reload()
    }

    var timeText: String {
        guard let occurrence = event?.occurrence else { return "" }
        return EventText.time(occurrence, in: phone)
    }

    /// The time in the event's own zone, when that zone's clock differs from the phone's at the time.
    var zoneNote: String? {
        guard let occurrence = event?.occurrence else { return nil }
        return EventText.zoneNote(occurrence, zones: series?.zones ?? [:], phone: phone)
    }

    /// The organiser's name (from their attendee line), else their address; nil when there is none.
    var organizer: String? {
        guard let details, let email = details.organizer else { return nil }
        let line = details.attendees.first { $0.email.lowercased() == email.lowercased() }
        let name = line?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? email : name
    }

    /// Everyone invited but the organiser, with their answers.
    var attendees: [Attendee] {
        guard let details else { return [] }
        let organizer = details.organizer?.lowercased()
        return details.attendees.filter { $0.email.lowercased() != organizer }
    }

    var reminderText: String {
        guard let minutes = details?.reminder else { return L10n.string("None", locale: phone.locale ?? .current) }
        return EventText.reminder(minutes, locale: phone.locale ?? .current)
    }

    /// How the series repeats; nil for an event that does not.
    var repeatText: String? {
        guard let series, series.rule != nil || !series.rdates.isEmpty else { return nil }
        return EventText.repeats(series.rule, calendar: phone)
    }
}
