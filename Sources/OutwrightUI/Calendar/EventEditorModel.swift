// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Observation
import OutwrightMIME
import OutwrightModel
import OutwrightStore
import OutwrightSync

/// A request to open the event editor: a new event (on a day), or an event as one occurrence or the
/// whole series.
struct EventEditorRequest: Identifiable, Equatable {
    let id = UUID()
    var editing: EventRequest?
    var day: Date?
    var scope: EditScope = .event
}

enum EventEditError: Error, Equatable {
    /// No calendar to put the event in.
    case noCalendar
    case endBeforeStart
    /// The store refused.
    case store
}

/// The editor of one event: a new one (in the chosen calendar), one occurrence of a series, or the
/// series. Times are edited as the occurrence opened shows them; the store applies what a change of
/// the series' times means for its exceptions.
@Observable @MainActor
final class EventEditorModel {
    var details: EventDetails
    var rule: RecurrenceRule?
    var calendar: CalendarID?
    /// The people invited, other than the organiser.
    var people: [Address]
    /// Where a new event can go: the calendars that can be written to, by account.
    private(set) var writableCalendars: [(account: Account, calendars: [CalendarInfo])] = []
    let editing: EventRequest?
    /// What `editing` opened: one occurrence, or the event (the whole series).
    let scope: EditScope
    private var zoneStorage: TimeZone

    @ObservationIgnored let app: AppModel
    @ObservationIgnored let phone: Calendar
    @ObservationIgnored let series: EventSeries?
    @ObservationIgnored let eventID: EventID?
    /// The details as the editor opened, to tell what the owner changed.
    @ObservationIgnored let opened: EventDetails
    @ObservationIgnored let openedRule: RecurrenceRule?
    /// The hours of a timed event while All day is on, to come back to.
    @ObservationIgnored private var timedHours: (start: EventTime, end: EventTime)?
    @ObservationIgnored private var zoneChosen = false
    @ObservationIgnored private lazy var known: [Address] = PeopleIndex.known(app.store, accounts: app.accounts)

    static let defaultReminder = 15

    init(
        app: AppModel, editing: EventRequest?, day: Date?, scope: EditScope = .event,
        calendar phone: Calendar = .autoupdatingCurrent, now: () -> Date = Date.init
    ) {
        self.app = app
        self.editing = editing
        self.scope = scope
        self.phone = phone
        let event = editing.flatMap { try? app.store.event($0.event, occurrence: $0.occurrence) }
        let series = event.flatMap { try? app.store.series($0.id) }
        self.series = series
        eventID = event?.id
        let loaded = event.map { Self.loaded($0, series: series, scope: scope, phone: phone) }
            ?? Self.fresh(day: day, now: now(), phone: phone)
        opened = loaded
        details = loaded
        rule = series?.rule
        openedRule = series?.rule
        people = loaded.attendees.filter { !Self.same($0.email, loaded.organizer) }
            .map { Address(name: $0.name.isEmpty ? nil : $0.name, email: $0.email) }
        zoneStorage = Self.zone(of: loaded.start) ?? phone.timeZone
        calendar = event?.calendarID
        writableCalendars = app.writableAccounts.compactMap { account in
            let calendars = ((try? app.store.calendars(account.id)) ?? []).filter { !$0.isReadOnly }
            return calendars.isEmpty ? nil : (account: account, calendars: calendars)
        }
        if calendar == nil {
            let all = writableCalendars.flatMap(\.calendars)
            let preferred = (try? app.store.defaultCalendar())?.id
            calendar = all.first { $0.id == preferred }?.id ?? all.first?.id
        }
    }

    /// A new event: at the next whole hour on the day (today when none), an hour long, in the phone's zone.
    private static func fresh(day: Date?, now: Date, phone: Calendar) -> EventDetails {
        let clock = phone.dateComponents([.hour, .minute, .second], from: now)
        let late = (clock.minute ?? 0) > 0 || (clock.second ?? 0) > 0
        let hour = (clock.hour ?? 0) + (late ? 1 : 0)
        let base = phone.startOfDay(for: day ?? now)
        // After 23:00 the next whole hour is midnight, the start of the next day.
        let start = hour > 23
            ? (phone.date(byAdding: .day, value: 1, to: base) ?? base)
            : (phone.date(bySettingHour: hour, minute: 0, second: 0, of: base) ?? base)
        let zone = phone.timeZone
        return EventDetails(
            title: "", start: .zoned(EditorTimes.clock(start, in: zone), zone: zone.identifier),
            end: .zoned(EditorTimes.clock(start.addingTimeInterval(3_600), in: zone), zone: zone.identifier),
            reminder: defaultReminder)
    }

    /// What the editor shows of a stored event: the series' own fields when the whole series is edited
    /// (an occurrence's change is not the series'), and always the times of the occurrence opened.
    private static func loaded(
        _ event: CalendarEvent, series: EventSeries?, scope: EditScope, phone: Calendar
    ) -> EventDetails {
        let occurrence = event.occurrence
        var details = occurrence.details
        if scope == .event, event.isSeries, let base = series?.base { details = base }
        guard event.isSeries, let time = occurrence.recurrenceID else { return details }
        if let override = series?.overrides.first(where: { $0.recurrenceID == time }) {
            details.start = override.details.start
            details.end = override.details.end
        } else if let series, let range = Recurrence.range(holding: time, in: series, phoneZone: phone.timeZone) {
            // Inside a range the occurrence has the range's shift and length, in wall time like the range.
            if let shift = EditorTimes.distance(from: range.recurrenceID, to: range.details.start),
                let length = EditorTimes.distance(from: range.details.start, to: range.details.end),
                let start = EditorTimes.moved(time, by: shift, like: range.details.start),
                let end = EditorTimes.moved(start, by: length, like: range.details.end) {
                details.start = start
                details.end = end
            } else {
                details.start = EditorTimes.make(like: range.details.start, at: occurrence.start, phone: phone)
                details.end = EditorTimes.make(like: range.details.end, at: occurrence.end, phone: phone)
            }
        } else {
            details.start = time
            // The base's end moved by the wall time from its start to this occurrence's, in its own
            // kind of time: right also for a zone only the object's VTIMEZONE defines.
            if let base = series?.base, let delta = EditorTimes.distance(from: base.start, to: time),
                let end = EditorTimes.moved(base.end, by: delta, like: base.end) {
                details.end = end
            } else {
                details.end = EditorTimes.make(like: occurrence.details.end, at: occurrence.end, phone: phone)
            }
        }
        return details
    }

    private static func zone(of time: EventTime) -> TimeZone? {
        guard case let .zoned(_, tzid) = time else { return nil }
        return EditorTimes.zoneNamed(tzid)
    }

    static func same(_ email: String, _ other: String?) -> Bool {
        guard let other else { return false }
        return email.lowercased() == other.lowercased()
    }

}

extension EventEditorModel {
    // MARK: What the sheet shows

    /// The calendar and its account, for showing where the event goes.
    var chosen: (account: Account, calendar: CalendarInfo)? {
        for group in writableCalendars {
            if let found = group.calendars.first(where: { $0.id == calendar }) { return (group.account, found) }
        }
        return nil
    }

    var isNew: Bool { eventID == nil }

    /// Something has been typed, chosen or removed since the editor opened.
    var hasChanges: Bool {
        let invited = opened.attendees.filter { !Self.same($0.email, opened.organizer) }.map { $0.email.lowercased() }
        return details != opened || rule != openedRule || people.map { $0.email.lowercased() } != invited
    }

    /// A repeating event edited as a whole: the repeat row is shown.
    var editsRule: Bool { scope == .event }

    var canSave: Bool { calendar != nil && !endsBeforeStart && !isOverLimits }

    /// The calendar comes over Graph and Graph's patterns can't hold the repeat to save.
    var isOverLimits: Bool {
        guard scope == .event, let rule = savedRule, let calendar,
            let owner = writableCalendars.first(where: { $0.calendars.contains { $0.id == calendar } })?.account,
            owner.calendarVia == .graph
        else { return false }
        return !GraphEventMapping.canHold(rule, start: details.start)
    }

    /// Saving changes the times or the rule of a series that has exceptions, which the change drops:
    /// the editor warns first.
    var dropsOverrides: Bool {
        guard scope == .event, let series, series.rule != nil || !series.rdates.isEmpty,
            !series.overrides.isEmpty || !series.exdates.isEmpty
        else { return false }
        return details.start != opened.start || details.end != opened.end || savedRule != openedRule
    }

    /// The event keeps a rule the repeat picker cannot show.
    var hasCustomRule: Bool {
        RepeatChoice.of(openedRule, start: instant(opened.start), phone: phone) == .custom
    }

    /// The rule to save. A rule the picker shows stays that choice when the start moves to another
    /// weekday or date: "every week" on Tuesdays moved to a Wednesday repeats on Wednesdays. A rule the
    /// picker cannot show is kept as it is.
    var savedRule: RecurrenceRule? {
        guard let rule, rule == openedRule else { return rule }
        let was = RepeatChoice.of(rule, start: instant(opened.start), phone: phone)
        guard was != .custom, was != .never else { return rule }
        return RepeatChoice.of(rule, start: start, phone: phone) == was ? rule : was.rule
    }

    var repeatChoice: RepeatChoice {
        get { RepeatChoice.of(savedRule, start: start, phone: phone) }
        set {
            if newValue == .custom {
                if hasCustomRule { rule = openedRule }
            } else {
                rule = newValue.rule
            }
        }
    }

    var endsBeforeStart: Bool { end < start }

    /// People whose name or address starts with `prefix` (at a word), not those already invited.
    func suggestions(for prefix: String) -> [Address] {
        let wanted = prefix.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return [] }
        let taken = Set(people.map { $0.email.lowercased() })
        return known.filter { person in
            !taken.contains(person.email.lowercased()) && PeopleIndex.matches(person, wanted)
        }.prefix(8).map { $0 }
    }
}

extension EventEditorModel {
    // MARK: Times

    /// The zone the hours are in; changing it keeps the hours shown and moves the event.
    var zone: TimeZone {
        get { zoneStorage }
        set {
            guard newValue != zoneStorage else { return }
            let old = zoneStorage
            zoneStorage = newValue
            zoneChosen = true
            guard !isAllDay else { return }
            details.start = rezoned(details.start, from: old)
            details.end = rezoned(details.end, from: old)
        }
    }

    private func rezoned(_ time: EventTime, from old: TimeZone) -> EventTime {
        let wall = switch time {
        case .utc(let date): EditorTimes.clock(date, in: old)
        default: EditorTimes.wall(time)
        }
        return .zoned(wall, zone: zoneStorage.identifier)
    }

    /// The zone the date pickers read: the event's for hours, the phone's for days.
    var pickerZone: TimeZone { isAllDay ? phone.timeZone : zoneStorage }

    var isAllDay: Bool {
        get {
            if case .date = details.start { return true }
            return false
        }
        set {
            guard newValue != isAllDay else { return }
            if newValue { makeAllDay() } else { makeTimed() }
            if isNew, details.reminder == (newValue ? Self.defaultReminder : nil) {
                details.reminder = newValue ? nil : Self.defaultReminder
            }
        }
    }

    private func makeAllDay() {
        let first = phone.startOfDay(for: start)
        var last = phone.startOfDay(for: end)
        if last <= first || end > last { last = phone.date(byAdding: .day, value: 1, to: last) ?? last }
        timedHours = (details.start, details.end)
        details.start = EditorTimes.make(like: .date(year: 1, month: 1, day: 1), at: first, phone: phone)
        details.end = EditorTimes.make(like: .date(year: 1, month: 1, day: 1), at: max(last, first), phone: phone)
    }

    /// Back to hours: the ones it had on its first day, else 9 to 10.
    private func makeTimed() {
        let day = EditorTimes.wall(details.start)
        var startWall = DateComponents(year: day.year, month: day.month, day: day.day, hour: 9, minute: 0, second: 0)
        var length = 3_600
        if let hours = timedHours {
            let wall = EditorTimes.wall(hours.start)
            startWall.hour = wall.hour
            startWall.minute = wall.minute
            length = max(EditorTimes.distance(from: hours.start, to: hours.end) ?? 3_600, 0)
        }
        let start = Date.zonedStart(startWall, zoneStorage)
        details.start = .zoned(EditorTimes.clock(start, in: zoneStorage), zone: zoneStorage.identifier)
        details.end = .zoned(
            EditorTimes.clock(start.addingTimeInterval(TimeInterval(length)), in: zoneStorage),
            zone: zoneStorage.identifier)
    }

    /// The start; moving it keeps the length.
    var start: Date {
        get { instant(details.start) }
        set {
            let length = end.timeIntervalSince(start)
            let days = phone.dateComponents([.day], from: start, to: end).day ?? 0
            details.start = time(newValue)
            if isAllDay {
                details.end = time(phone.date(byAdding: .day, value: max(days, 0) + 1, to: newValue) ?? newValue)
            } else {
                details.end = time(newValue.addingTimeInterval(max(length, 0)))
            }
        }
    }

    /// The end; for an all-day event its last day (stored as the day after).
    var end: Date {
        get {
            let stored = instant(details.end)
            guard isAllDay else { return stored }
            return phone.date(byAdding: .day, value: -1, to: stored) ?? stored
        }
        set {
            let last = isAllDay ? (phone.date(byAdding: .day, value: 1, to: newValue) ?? newValue) : newValue
            details.end = time(last)
        }
    }

    /// "1 h 30 min", "2 days".
    var durationText: String {
        let formatter = DateComponentsFormatter()
        formatter.calendar = phone
        formatter.unitsStyle = .abbreviated
        if isAllDay {
            formatter.allowedUnits = [.day]
            let days = (phone.dateComponents([.day], from: start, to: end).day ?? 0) + 1
            return formatter.string(from: DateComponents(day: max(days, 1))) ?? ""
        }
        formatter.allowedUnits = [.day, .hour, .minute]
        return formatter.string(from: max(end.timeIntervalSince(start), 0)) ?? ""
    }

    func instant(_ time: EventTime) -> Date {
        time.instant(in: phone.timeZone, zones: series?.zones ?? [:]) ?? Date(timeIntervalSince1970: 0)
    }

    /// A picked date as the kind of time the event has: a day when all day; else the hours in the zone,
    /// kept floating or UTC as stored until the owner chooses a zone.
    private func time(_ date: Date) -> EventTime {
        if isAllDay { return EditorTimes.make(like: details.start, at: date, phone: phone) }
        switch details.start {
        case .floating where !zoneChosen, .utc where !zoneChosen:
            return EditorTimes.make(like: details.start, at: date, phone: phone)
        default:
            return .zoned(EditorTimes.clock(date, in: zoneStorage), zone: zoneStorage.identifier)
        }
    }
}

extension Date {
    /// The instant of a wall time in a zone.
    fileprivate static func zonedStart(_ wall: DateComponents, _ zone: TimeZone) -> Date {
        var calendar = EditorTimes.utc
        calendar.timeZone = zone
        return calendar.date(from: wall) ?? Date(timeIntervalSince1970: 0)
    }
}
