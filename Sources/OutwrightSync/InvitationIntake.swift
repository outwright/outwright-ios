// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightDAV
import OutwrightMIME
import OutwrightModel
import OutwrightStore

/// A fetched message with a calendar part, read as iTIP (RFC 5546) and applied to the store: an
/// invitation goes in the calendar at once, an update or a cancellation changes the event it is
/// about. Everything in the message came from its sender: only its ORGANIZER may change the calendar,
/// never from Junk, and only for an invitation that names the account as an attendee.
enum InvitationIntake {
    /// Runs once per message (`isInvitationRecorded`); true when the calendar was written (an event
    /// queued, or a held one changed). A message without a readable iTIP part is left alone; any other
    /// is recorded with what it did. A store failure throws and records nothing, so a later pass
    /// takes the message again.
    @discardableResult
    // swiftlint:disable:next function_parameter_count
    static func process(
        _ row: MessageRow, parsed: MIMEMessage, account: Account, folder: Folder, store: MailStore,
        window: ClosedRange<Date>, phoneZone: TimeZone, now: Date
    ) throws(SyncError) -> Bool {
        guard let part = parsed.calendar, !(try stored { try store.isInvitationRecorded(row.id) }) else {
            return false
        }
        guard let read = ITIP.read(part.data, method: part.method),
            let method = InvitationMethod(rawValue: read.method.rawValue)
        else {
            // Unreadable, or not one of the four methods: kept as such, never read again.
            if parsed.isInvitation {
                try stored { try store.recordUnreadableInvitation(row.id) }
            }
            return false
        }
        let intake = Intake(
            row: row, account: account, store: store, window: window, phoneZone: phoneZone, method: method)
        let trusted = folder.kind != .junk && ITIP.senderMayApply(read, from: row.from.email)
        if read.method == .reply {
            try intake.recordReply(read, trusted: trusted)
            if trusted { try intake.takeGuestAnswer(read) }
            return false
        }
        let lead = EventMapping.series(read.calendar).first(where: { $0.uid == read.uid }).flatMap(Self.lead)
        guard trusted, !account.calDAVOff, let lead, EventOwnership.isInvitation(lead, accountEmail: account.email)
        else {
            let why = refusal(trusted: trusted, folder: folder, account: account, hasEvent: lead != nil)
            syncLog.notice("Invitation refused: \(why, privacy: .public)")
            try intake.record(read, event: nil, applied: false)
            return false
        }
        if account.calendarVia == .graph {
            try intake.heldByExchange(read)
            return false
        }
        // Mail can come in before the calendars are listed (the first sync, a CalDAV address still
        // to be found): the message waits for them and is taken again after a calendar sync.
        let listed = try stored { try store.calendars(account.id) }
        if account.calDAV == nil || listed.isEmpty {
            try intake.record(read, event: nil, applied: false, awaitingCalendar: true)
            return false
        }
        guard let held = try stored({ try store.invitationEvent(accountId: account.id, uid: read.uid) }) else {
            if read.method == .cancel {
                try intake.record(read, event: nil, applied: false)
                return false
            }
            return try intake.insert(read)
        }
        return try intake.change(held, with: read)
    }

    static func lead(_ series: EventSeries) -> EventDetails? { series.base ?? series.overrides.first?.details }

    /// Why an invitation was not taken, for the log: nothing from the message itself.
    private static func refusal(trusted: Bool, folder: Folder, account: Account, hasEvent: Bool) -> String {
        if folder.kind == .junk { return "in Junk" }
        if !trusted { return "the sender is not its organiser" }
        if account.calDAVOff { return "calendars are off" }
        if !hasEvent { return "it holds no event with its UID" }
        return "the account is not one of its attendees"
    }

    /// The message's RECURRENCE-IDs written as the stored copy writes the same occurrence: a TZID form
    /// and a UTC form of one instant are one occurrence, and iTIP matches them by text.
    static func aligned(_ message: ITIPMessage, to stored: ICalComponent, phoneZone: TimeZone) -> ITIPMessage {
        let ours = EventMapping.zones(stored)
        let held: [(instant: Date, line: ICalProperty)] = stored.components.compactMap { component in
            guard component.name == "VEVENT", let line = component.first("RECURRENCE-ID"),
                let moment = instant(line, zones: ours, phoneZone: phoneZone)
            else { return nil }
            return (moment, line)
        }
        guard !held.isEmpty else { return message }
        let theirs = EventMapping.zones(message.calendar)
        func matching(_ line: ICalProperty) -> ICalProperty? {
            guard let moment = instant(line, zones: theirs, phoneZone: phoneZone),
                let found = held.first(where: { $0.instant == moment })?.line, found != line
            else { return nil }
            // The occurrence as stored, with the message's own RANGE.
            var result = found
            result.parameters = found.parameters.filter { $0.name != "RANGE" }
                + line.parameters.filter { $0.name == "RANGE" }
            return result
        }
        var result = message
        result.calendar.components = message.calendar.components.map { component in
            guard component.name == "VEVENT", let line = component.first("RECURRENCE-ID"), let stored = matching(line)
            else { return component }
            return component.replacing("RECURRENCE-ID", with: [stored])
        }
        if let line = message.recurrenceID, let stored = matching(line) { result.recurrenceID = stored }
        return result
    }

    /// Whether `message`, applied to `held`, moves the meeting, compared by instant: the series event's
    /// start, end or repeat changed, an occurrence the copy holds changed its start or end, or an
    /// occurrence new to the copy starts elsewhere than the occurrence it stands for or lasts another
    /// length than the series.
    static func movesTime(_ message: ITIPMessage, of held: ICalComponent) -> Bool {
        let utc = ICalValue.utcZone
        guard let new = EventMapping.series(message.calendar).first(where: { $0.uid == message.uid }) else {
            return false
        }
        let old = EventMapping.series(held).first { $0.uid == message.uid }
        func at(_ time: EventTime, _ zones: [String: ZoneRules]) -> Date? { time.instant(in: utc, zones: zones) }
        func span(_ details: EventDetails?, _ zones: [String: ZoneRules]) -> [Date?] {
            [details.flatMap { at($0.start, zones) }, details.flatMap { at($0.end, zones) }]
        }
        func length(_ details: EventDetails?, _ zones: [String: ZoneRules]) -> TimeInterval? {
            guard let details, let start = at(details.start, zones), let end = at(details.end, zones) else {
                return nil
            }
            return end.timeIntervalSince(start)
        }
        let oldZones = old?.zones ?? [:]
        if let base = new.base {
            guard let old, old.base != nil else { return true }
            func moments(_ times: [EventTime], _ zones: [String: ZoneRules]) -> Set<Date> {
                Set(times.compactMap { at($0, zones) })
            }
            if span(base, new.zones) != span(old.base, oldZones) || new.rule != old.rule
                || moments(new.rdates, new.zones) != moments(old.rdates, oldZones)
                || moments(new.exdates, new.zones) != moments(old.exdates, oldZones) {
                return true
            }
        }
        for own in new.overrides {
            let moment = at(own.recurrenceID, new.zones)
            if let before = old?.overrides.first(where: { at($0.recurrenceID, oldZones) == moment }) {
                if span(own.details, new.zones) != span(before.details, oldZones) { return true }
                continue
            }
            if at(own.details.start, new.zones) != moment { return true }
            let seriesLength = length(old?.base, oldZones) ?? length(new.base, new.zones)
            if let seriesLength, let ownLength = length(own.details, new.zones), ownLength != seriesLength {
                return true
            }
        }
        return false
    }

    private static func instant(_ line: ICalProperty, zones: [String: ZoneRules], phoneZone: TimeZone) -> Date? {
        ICalValue.time(line, zones: zones)?.instant(in: phoneZone, zones: zones)
    }
}

/// One message's intake.
private struct Intake {
    let row: MessageRow
    let account: Account
    let store: MailStore
    let window: ClosedRange<Date>
    let phoneZone: TimeZone
    let method: InvitationMethod

    /// A REPLY is recorded; it names who answered only when it came from that attendee.
    func recordReply(_ message: ITIPMessage, trusted: Bool) throws(SyncError) {
        let sender = row.from.email.lowercased()
        let answer = trusted
            ? EventMapping.series(message.calendar).first(where: { $0.uid == message.uid })
                .flatMap(InvitationIntake.lead)?.attendees
                .first { $0.email.lowercased() == sender }.map { (email: sender, response: $0.response) }
            : nil
        try record(message, event: nil, applied: false, reply: answer)
    }

    /// A guest's REPLY to the owner's own meeting is written to it, for the series and each
    /// occurrence it answers, where the CalDAV server does not take REPLYs itself (one that schedules
    /// updates the organiser's copy, RFC 6638 › 3.2.2.3). Graph's server takes them for a Graph calendar.
    func takeGuestAnswer(_ message: ITIPMessage) throws(SyncError) {
        guard account.calendarVia == .calDAV, !account.calDAVOff, account.calDAV != nil,
            message.organizer == account.email.lowercased(),
            try !stored({ try store.serverSchedules(account.id) }),
            let event = try stored({ try store.invitationEvent(accountId: account.id, uid: message.uid) }),
            let held = try stored({ try store.eventObject(event) }).flatMap({ try? ICalendarReader.calendar($0) })
        else { return }
        // Its RECURRENCE-IDs written as the meeting writes the same occurrences, so they match.
        let aligned = InvitationIntake.aligned(message, to: held, phoneZone: phoneZone)
        guard let series = EventMapping.series(aligned.calendar).first(where: { $0.uid == message.uid }) else { return }
        let stamp = ITIP.stamp(message)
        let guest = row.from.email.lowercased()
        var answers: [(scope: EditScope, details: EventDetails)] = []
        if let base = series.base { answers.append((.event, base)) }
        answers += series.overrides.map { (.occurrence($0.recurrenceID), $0.details) }
        for (scope, details) in answers {
            guard let own = details.attendees.first(where: { $0.email.lowercased() == guest }),
                own.response != .needsAction, own.response != .delegated
            else { continue }
            _ = try stored {
                try store.takeGuestAnswer(
                    event, guest: guest, response: own.response, scope: scope, sequence: details.sequence,
                    stamp: stamp)
            }
        }
    }

    func record(
        _ message: ITIPMessage, event: EventID?, applied: Bool,
        reply: (email: String, response: Attendee.Response)? = nil, awaitingCalendar: Bool = false,
        isUpdate: Bool = false, timeMoved: Bool? = nil
    ) throws(SyncError) {
        let zones = EventMapping.zones(message.calendar)
        let title = EventMapping.series(message.calendar).first { $0.uid == message.uid }
            .flatMap(InvitationIntake.lead)?.title
        let recurrence = message.recurrenceID.flatMap { ICalValue.time($0, zones: zones) }
        let outcome = applied ? "applied" : awaitingCalendar ? "waits for the calendars" : "not applied"
        syncLog.notice("Invitation \(method.rawValue, privacy: .public): \(outcome, privacy: .public)")
        try stored {
            try store.recordInvitation(
                message: row.id, method: method, uid: message.uid, recurrenceID: recurrence,
                sequence: message.sequence, event: event, applied: applied, reply: reply,
                awaitingCalendar: awaitingCalendar, isUpdate: isUpdate, timeMoved: timeMoved, title: title)
        }
    }

    /// A Graph calendar's invitation: Exchange puts it in the calendar and changes it there, and
    /// answers go through Graph, so the mail writes nothing. It shows the meeting Exchange holds (as
    /// applied). Before Exchange's copy has come down it waits for one calendar sync; one Exchange
    /// still doesn't hold then (declined or deleted elsewhere, out of the window) it never will, and
    /// is only recorded, as a cancellation of a meeting not held is.
    func heldByExchange(_ message: ITIPMessage) throws(SyncError) {
        if let held = try stored({ try store.invitationEvent(accountId: account.id, uid: message.uid) }) {
            try record(message, event: held, applied: true)
            return
        }
        let waitedBefore = try stored { try store.invitation(for: row.id) } != nil
        try record(message, event: nil, applied: false, awaitingCalendar: message.method != .cancel && !waitedBefore)
    }

    /// A new invitation, into the account's calendar for invitations: the default calendar when it is
    /// this account's, else its first writable one. With none it waits, and is taken again after the
    /// next calendar sync.
    func insert(_ message: ITIPMessage) throws(SyncError) -> Bool {
        let calendar = ITIP.applying(message, to: nil, ownEmail: account.email)
        guard let target = try invitationCalendar(),
            let series = EventMapping.series(calendar).first(where: { $0.uid == message.uid })
        else {
            try record(message, event: nil, applied: false, awaitingCalendar: true)
            return false
        }
        if try stored({ try store.isCalledOff(accountId: account.id, uid: message.uid, sequence: message.sequence) }) {
            syncLog.notice("Invitation refused: the meeting was called off")
            try record(message, event: nil, applied: false)
            return false
        }
        let id: EventID
        do {
            id = try store.insertInvitation(
                ics: ICalendarWriter.write(calendar), series: series, uid: message.uid, in: target, window: window,
                phoneZone: phoneZone)
        } catch .noCalDAV, .noSuchCalendar {
            try record(message, event: nil, applied: false, awaitingCalendar: true)
            return false
        } catch .readOnly {
            try record(message, event: nil, applied: false)
            return false
        } catch {
            throw .store(String(describing: error))
        }
        try record(message, event: id, applied: true)
        return true
    }

    /// An update or a cancellation of the event held for the UID, when the copy is of that UID and
    /// the message is not older than it. A message as old as the copy is already in it: applied. True
    /// when the event was changed.
    func change(_ id: EventID, with read: ITIPMessage) throws(SyncError) -> Bool {
        guard let data = try stored({ try store.eventObject(id) }),
            let held = try? ICalendarReader.calendar(data),
            case let uids = held.components.filter({ $0.name == "VEVENT" }).map({ $0.first("UID")?.value ?? "" }),
            !uids.isEmpty, uids.allSatisfy({ $0.trimmingCharacters(in: .whitespaces) == read.uid })
        else {
            try record(read, event: nil, applied: false)
            return false
        }
        let shown = try stored { try store.series(id) }
        // Only the meeting's own organiser changes it: a co-attendee who knows the UID and names herself
        // ORGANIZER (and is the From) is not the organiser the calendar holds.
        let heldOrganizer = shown.flatMap(InvitationIntake.lead)?.organizer
            ?? EventMapping.series(held).first(where: { $0.uid == read.uid }).flatMap(InvitationIntake.lead)?.organizer
        guard let heldOrganizer, let claimed = read.organizer,
            heldOrganizer.trimmingCharacters(in: .whitespaces).lowercased() == claimed.lowercased()
        else {
            try record(read, event: nil, applied: false)
            return false
        }
        let message = InvitationIntake.aligned(read, to: held, phoneZone: phoneZone)
        // The phone may hold a later change than the server's copy says (the organiser's updates to a
        // server copy are shown here only until the server sends its own).
        let older = shown.map { message.sequence < Self.sequence(of: $0, at: message, phoneZone: phoneZone) } ?? false
        let apply = !older && (message.method == .cancel || ITIP.isNewer(message, than: held))
        let isRequest = message.method == .request || message.method == .add
        var timeMoved: Bool?
        if apply {
            if isRequest { timeMoved = InvitationIntake.movesTime(message, of: held) }
            let result = ITIP.applying(message, to: held, ownEmail: account.email)
            guard let series = EventMapping.series(result).first(where: { $0.uid == message.uid }) else {
                try record(message, event: id, applied: false)
                return false
            }
            do {
                try store.applyInvitationChange(
                    id, ics: ICalendarWriter.write(result), series: series, window: window, phoneZone: phoneZone)
            } catch .readOnly, .noSuchEvent {
                try record(message, event: nil, applied: false)
                return false
            } catch {
                throw .store(String(describing: error))
            }
        }
        // An update the phone applied; one the server applied first is told by the store from the
        // earlier messages of this account (`invitation(for:)`).
        try record(message, event: id, applied: true, isUpdate: timeMoved != nil, timeMoved: timeMoved)
        return apply
    }

    /// The SEQUENCE shown for the message's occurrence (its override's), else for the series.
    private static func sequence(of series: EventSeries, at message: ITIPMessage, phoneZone: TimeZone) -> Int {
        let zones = EventMapping.zones(message.calendar)
        if let line = message.recurrenceID,
            let moment = ICalValue.time(line, zones: zones)?.instant(in: phoneZone, zones: zones),
            let own = series.overrides.first(where: {
                $0.recurrenceID.instant(in: phoneZone, zones: series.zones) == moment
            }) {
            return own.details.sequence
        }
        return InvitationIntake.lead(series)?.sequence ?? 0
    }

    private func invitationCalendar() throws(SyncError) -> CalendarID? {
        if let chosen = try stored({ try store.defaultCalendar() }), chosen.accountID == account.id,
            !chosen.isReadOnly {
            return chosen.id
        }
        return try stored { try store.calendars(account.id) }.first { !$0.isReadOnly }?.id
    }
}
