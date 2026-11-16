// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import GRDB
import OutwrightModel

/// `EventSeries` as stored.
private struct StoredSeries: Codable {
    var uid: String
    var base: EventDetails?
    var rule: RecurrenceRule?
    var rdates: [EventTime]
    var exdates: [EventTime]
    var overrides: [EventOverride]
    var zones: [String: ZoneRules]

    init(_ series: EventSeries) {
        uid = series.uid
        base = series.base
        rule = series.rule
        rdates = series.rdates
        exdates = series.exdates
        overrides = series.overrides
        zones = series.zones
    }

    var series: EventSeries {
        EventSeries(
            uid: uid, base: base, rule: rule, rdates: rdates, exdates: exdates,
            overrides: overrides, zones: zones)
    }
}

/// The window the occurrences are laid out for, and the zone of the phone they are laid out in.
struct Expansion {
    var from: Date
    var to: Date
    var zone: TimeZone

    /// The last one stored; before any, a year back to two years ahead from the start of today in the phone's zone.
    static func current(_ database: Database) throws -> Expansion {
        let meta = try Row.fetchAll(database, sql: "SELECT key, value FROM calendar_meta")
        var values: [String: String] = [:]
        for row in meta {
            if let key = row["key"] as String?, let value = row["value"] as String? { values[key] = value }
        }
        let zone = values["phoneZone"].flatMap { TimeZone(identifier: $0) } ?? .current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let today = calendar.startOfDay(for: Date())
        let from = values["windowFrom"].flatMap(finite) ?? calendar.date(byAdding: .year, value: -1, to: today)
            ?? today.addingTimeInterval(-365 * 86_400)
        let to = values["windowTo"].flatMap(finite) ?? calendar.date(byAdding: .year, value: 2, to: today)
            ?? today.addingTimeInterval(730 * 86_400)
        return Expansion(from: from, to: to, zone: zone)
    }

    /// A stored instant, only when it is a finite number.
    private static func finite(_ text: String) -> Date? {
        guard let seconds = Double(text), seconds.isFinite else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    func save(_ database: Database) throws {
        let values: [(String, String)] = [
            ("windowFrom", String(from.timeIntervalSince1970)), ("windowTo", String(to.timeIntervalSince1970)),
            ("phoneZone", zone.identifier)
        ]
        for (key, value) in values {
            try database.execute(
                sql: "INSERT OR REPLACE INTO calendar_meta (key, value) VALUES (?, ?)", arguments: [key, value])
        }
    }

    /// yyyymmdd of an instant on the phone.
    func dayKey(_ date: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return (parts.year ?? 0) * 10_000 + (parts.month ?? 0) * 100 + (parts.day ?? 0)
    }
}

enum CalendarRecords {
    private static func json<T: Encodable>(_ value: T) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(value) else { return nil }
        return String(bytes: data, encoding: .utf8)
    }

    private static func value<T: Decodable>(_ type: T.Type, _ json: String?) -> T? {
        guard let data = json?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func encode(_ series: EventSeries) -> String { json(StoredSeries(series)) ?? "{}" }
    static func decodeSeries(_ text: String?) -> EventSeries? { value(StoredSeries.self, text)?.series }
    static func encode(_ edits: [EventEdit]) -> String { json(edits) ?? "[]" }
    /// The queued edits in order; none when absent or unreadable.
    static func decodeEdits(_ text: String?) -> [EventEdit] { value([EventEdit].self, text) ?? [] }
    static func encode(_ scopes: [EditScope]) -> String { json(scopes) ?? "[]" }
    /// The scopes held; none when absent or unreadable.
    static func decodeScopes(_ text: String?) -> [EditScope] { value([EditScope].self, text) ?? [] }

    /// Whether the series says who organizes it, and who: the base's, else the first override's.
    static func ownership(_ series: EventSeries) -> (detailed: Bool, organizer: String?) {
        guard let details = series.base ?? series.overrides.first?.details else { return (false, nil) }
        return (true, details.organizer)
    }

    /// Writes the series and what is worked out from it: its ownership, and whether the owner
    /// declined it all (`hidden`).
    static func save(_ database: Database, _ series: EventSeries, event id: Int64) throws {
        let owner = ownership(series)
        let email = try String.fetchOne(
            database, sql: "SELECT a.email FROM event e JOIN account a ON a.id = e.accountId WHERE e.id = ?",
            arguments: [id]) ?? ""
        try database.execute(
            sql: "UPDATE event SET uid = ?, seriesJSON = ?, detailed = ?, organizer = ?, hidden = ? WHERE id = ?",
            arguments: [
                series.uid, encode(series), owner.detailed, owner.organizer, isDeclined(series, email: email), id
            ])
    }

    /// The series' own details: the base's, else the first override's.
    static func lead(_ series: EventSeries) -> EventDetails? { series.base ?? series.overrides.first?.details }

    /// The highest SEQUENCE of the series event and its overrides.
    static func topSequence(_ series: EventSeries) -> Int {
        ((series.base.map { [$0] } ?? []) + series.overrides.map(\.details)).map(\.sequence).max() ?? 0
    }

    /// An invitation the owner declined as a whole: the series event and every override say so. One
    /// occurrence declined alone is left out of the views by `occurrences`, not hidden here.
    static func isDeclined(_ series: EventSeries, email: String) -> Bool {
        let parts = (series.base.map { [$0] } ?? []) + series.overrides.map(\.details)
        guard let first = parts.first, EventOwnership.isInvitation(first, accountEmail: email) else { return false }
        return parts.allSatisfy { EventOwnership.ownAttendee($0, accountEmail: email)?.response == .declined }
    }

    /// The owner may answer the event and keep an own reminder on it: an invitation (`EventOwnership`)
    /// in a writable calendar.
    static func canRespond(calendarReadOnly: Bool, series: EventSeries, email: String) -> Bool {
        guard !calendarReadOnly, let details = lead(series) else { return false }
        return EventOwnership.isInvitation(details, accountEmail: email)
    }

    /// Whether the owner may queue the edit: an answer or an own reminder on an invitation
    /// (`canRespond`), anything else only on an own event (`canEdit`).
    static func allows(_ edit: EventEdit, calendarReadOnly: Bool, series: EventSeries, email: String) -> Bool {
        switch edit {
        case .respond, .ownReminder, .organiserChange:
            canRespond(calendarReadOnly: calendarReadOnly, series: series, email: email)
        case .create, .update, .delete, .guestAnswer:
            canEdit(calendarReadOnly: calendarReadOnly, series: series, email: email)
        }
    }
    static func encode(_ details: EventDetails) -> String { json(details) ?? "{}" }
    static func encode(_ time: EventTime) -> String { json(time) ?? "{}" }
    static func decodeTime(_ text: String?) -> EventTime? { value(EventTime.self, text) }

    /// An event the owner's change, a held conflict or a failed edit has not been settled for: the
    /// server must not overwrite or remove it.
    static let protected = "(pendingEditJSON IS NOT NULL OR conflictJSON IS NOT NULL OR changeFailed = 1)"

    /// The occurrences of the account's events with a UID (two arguments); a subscribed calendar
    /// belongs to no account, so its copy is never among them.
    static let ownByUID = "o.eventId IN (SELECT id FROM event WHERE accountId = ? AND uid = ?)"

    static func calendar(_ row: Row) -> CalendarInfo? {
        guard let id = row["id"] as Int64? else { return nil }
        let account = (row["accountId"] as String?).map { UUID(uuidString: $0) }
        // An account id that doesn't read is unusable; none at all is a subscribed calendar.
        if case .some(.none) = account { return nil }
        return CalendarInfo(
            id: CalendarID(raw: id), accountID: account.flatMap { $0 }.map(AccountID.init(raw:)),
            href: (row["href"] as String?) ?? "",
            name: (row["name"] as String?) ?? "", color: (row["color"] as Int?) ?? 0,
            isReadOnly: ((row["isReadOnly"] as Int?) ?? 0) != 0, isDefault: ((row["isDefault"] as Int?) ?? 0) != 0)
    }

    /// The one rule for whether the owner may change an event, and the only place it lives: the
    /// calendar is writable and the account, by its email now, owns the event (`EventOwnership`).
    /// CalDAV gives no privilege per object beyond the calendar's, so nothing else is stored for it.
    static func canEdit(calendarReadOnly: Bool, detailed: Bool, organizer: String?, email: String) -> Bool {
        guard !calendarReadOnly, detailed else { return false }
        let details = EventDetails(
            title: "", start: .utc(.distantPast), end: .utc(.distantPast), organizer: organizer)
        return EventOwnership.isOrganizer(details, accountEmail: email)
    }

    static func canEdit(calendarReadOnly: Bool, series: EventSeries, email: String) -> Bool {
        let owner = ownership(series)
        return canEdit(
            calendarReadOnly: calendarReadOnly, detailed: owner.detailed,
            organizer: owner.organizer, email: email)
    }

    static let occurrenceSelect = """
        SELECT o.eventId, o.recurrenceIdJSON, o.detailsJSON, o.startUTC, o.endUTC, o.allDayStart, o.allDayEnd,
            e.calendarId, e.accountId, e.conflictJSON, e.changeFailed, e.failedReplyJSON, e.detailed, e.organizer,
            e.origin, e.serverRepliedJSON,
            c.isReadOnly, a.email
        FROM occurrence o JOIN event e ON e.id = o.eventId JOIN calendar c ON c.id = e.calendarId
        LEFT JOIN account a ON a.id = e.accountId
        """

    /// A row of `occurrenceSelect`. Nil when stored data is unusable.
    static func event(_ row: Row) -> CalendarEvent? {
        let account = (row["accountId"] as String?).map { UUID(uuidString: $0) }
        if case .some(.none) = account { return nil }
        guard let id = row["eventId"] as Int64?, let calendar = row["calendarId"] as Int64?,
            let details = value(EventDetails.self, row["detailsJSON"] as String?),
            let start = row["startUTC"] as Double?, let end = row["endUTC"] as Double?
        else { return nil }
        let recurrenceID = (row["recurrenceIdJSON"] as String?).flatMap { value(EventTime.self, $0) }
        let email = (row["email"] as String?) ?? ""
        let occurrence = Occurrence(
            recurrenceID: recurrenceID, details: details, start: Date(timeIntervalSince1970: start),
            end: Date(timeIntervalSince1970: end), allDayStart: row["allDayStart"] as Int?,
            allDayEnd: row["allDayEnd"] as Int?)
        let held = decodeEdits(row["conflictJSON"] as String?)
        return CalendarEvent(
            id: EventID(raw: id), calendarID: CalendarID(raw: calendar),
            accountID: account.flatMap { $0 }.map(AccountID.init(raw:)),
            occurrence: occurrence, isSeries: recurrenceID != nil,
            isEditable: canEdit(
                calendarReadOnly: ((row["isReadOnly"] as Int?) ?? 1) != 0,
                detailed: ((row["detailed"] as Int?) ?? 0) != 0, organizer: row["organizer"] as String?,
                email: email),
            isTentative: EventOwnership.isTentative(details, accountEmail: email),
            conflict: held.last, conflictChanges: held.count,
            // An answer whose reply mail could not be queued counts as a failed change.
            changeFailed: ((row["changeFailed"] as Int?) ?? 0) != 0 || (row["failedReplyJSON"] as String?) != nil,
            origin: CopyOrigin(rawValue: (row["origin"] as String?) ?? "") ?? .server,
            isCancelled: details.status == .cancelled,
            isInvitation: EventOwnership.isInvitation(details, accountEmail: email),
            ownResponse: EventOwnership.ownAttendee(details, accountEmail: email)?.response,
            replyFailed: (row["failedReplyJSON"] as String?) != nil,
            replySentByServer: decodeScopes(row["serverRepliedJSON"] as String?).contains { scope in
                scope == .event || recurrenceID.map { scope == .occurrence($0) } == true
            })
    }

    /// An event's words as searched: title, place, notes and its people's names and addresses,
    /// folded, one space between words and one at each end (so `LIKE '% word%'` finds a word's start),
    /// at most `SearchText.maxStored` characters.
    static func searchText(_ details: EventDetails) -> String {
        let people = details.attendees.flatMap { [$0.name, $0.email] }
        let words = SearchText.words(
            ([details.title, details.place, details.notes] + people).joined(separator: " "), limit: 4_096)
        return " " + String((words.joined(separator: " ") + " ").prefix(SearchText.maxStored))
    }

    /// Lays the series out again in the window and stores its occurrences; returns how many there are.
    @discardableResult
    static func expand(_ database: Database, event: Int64, series: EventSeries, _ window: Expansion) throws -> Int {
        try database.execute(sql: "DELETE FROM occurrence WHERE eventId = ?", arguments: [event])
        let found = Recurrence.occurrences(series, from: window.from, to: window.to, phoneZone: window.zone)
        for occurrence in found {
            try database.execute(
                sql: """
                    INSERT INTO occurrence (eventId, recurrenceIdJSON, detailsJSON, startUTC, endUTC,
                        allDayStart, allDayEnd, searchText) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    event, occurrence.recurrenceID.map(encode), encode(occurrence.details),
                    occurrence.start.timeIntervalSince1970, occurrence.end.timeIntervalSince1970,
                    occurrence.allDayStart, occurrence.allDayEnd, searchText(occurrence.details)
                ])
        }
        return found.count
    }
}
