// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
public import OutwrightModel
import UserNotifications

/// A reminder to hand to the phone: one occurrence's alarm.
public struct PlannedReminder: Sendable, Equatable {
    /// `outwright.event.<eventID>.<startUTC>`: the same for an occurrence however often it is planned.
    public var identifier: String
    public var fire: Date
    public var title: String
    /// The time and place.
    public var body: String
    public var event: EventID
    public var occurrence: EventTime?

    public init(identifier: String, fire: Date, title: String, body: String, event: EventID, occurrence: EventTime?) {
        self.identifier = identifier
        self.fire = fire
        self.title = title
        self.body = body
        self.event = event
        self.occurrence = occurrence
    }
}

/// The reminders the phone holds. iOS keeps at most 64 pending local notifications, so the nearest
/// are handed over and the set is refilled after every sync.
public enum ReminderPlan {
    public static let identifierPrefix = "outwright.event."

    /// The occurrences' reminders that fire after `now`, nearest first, at most `limit`. Cancelled
    /// occurrences have none.
    public static func plan(_ occurrences: [CalendarEvent], now: Date, limit: Int = 64) -> [PlannedReminder] {
        let planned = occurrences.compactMap { event -> PlannedReminder? in
            let details = event.occurrence.details
            guard let minutes = details.reminder, details.status != .cancelled, (0...40_320 * 4).contains(minutes)
            else { return nil }
            let start = event.occurrence.start
            let fire = start.addingTimeInterval(-Double(minutes) * 60)
            // A time past what a whole number of seconds holds gets no reminder.
            guard fire > now, let seconds = Int(exactly: start.timeIntervalSince1970.rounded(.down)) else { return nil }
            return PlannedReminder(
                identifier: "\(identifierPrefix)\(event.id.raw).\(seconds)", fire: fire, title: details.title,
                body: body(event), event: event.id, occurrence: event.occurrence.recurrenceID)
        }
        let sorted = planned.sorted { ($0.fire, $0.identifier) < ($1.fire, $1.identifier) }
        return Array(sorted.prefix(max(limit, 0)))
    }

    /// The occurrence's time (with its day when it is not today's) and place.
    private static func body(_ event: CalendarEvent) -> String {
        let occurrence = event.occurrence
        let time = occurrence.allDayStart != nil
            ? occurrence.start.formatted(date: .abbreviated, time: .omitted)
            : occurrence.start.formatted(date: .omitted, time: .shortened) + "–"
                + occurrence.end.formatted(date: .omitted, time: .shortened)
        let place = occurrence.details.place.trimmingCharacters(in: .whitespacesAndNewlines)
        return place.isEmpty ? time : time + " · " + place
    }
}

/// Where planned reminders go: the phone's notifications.
public protocol Reminders: Sendable {
    /// Whether reminders may be shown.
    func authorization() async -> Bool
    /// Asks the owner (once; later calls answer as before).
    func requestAuthorization() async -> Bool
    /// Makes the pending reminders exactly `planned`: every pending `outwright.event.` request not in
    /// it is removed, the missing (or changed) ones added.
    func replace(_ planned: [PlannedReminder]) async
}

/// The reminders as iOS local notifications. Kept thin, and checked by hand: it needs the permission.
/// Outside an app bundle (a test run) there is no notification centre, and it does nothing.
public struct SystemReminders: Reminders {
    /// The app's clock, which each trigger's interval counts from (a test may run it ahead).
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    private var center: UNUserNotificationCenter? {
        ["app", "appex"].contains(Bundle.main.bundleURL.pathExtension) ? UNUserNotificationCenter.current() : nil
    }

    public func authorization() async -> Bool {
        guard let center else { return false }
        let settings = await center.notificationSettings()
        return [.authorized, .provisional].contains(settings.authorizationStatus)
    }

    public func requestAuthorization() async -> Bool {
        guard let center else { return false }
        return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    public func replace(_ planned: [PlannedReminder]) async {
        guard let center else { return }
        let wanted = Dictionary(planned.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
        var kept: Set<String> = []
        var stale: [String] = []
        for request in await center.pendingNotificationRequests()
        where request.identifier.hasPrefix(ReminderPlan.identifierPrefix) {
            if let reminder = wanted[request.identifier], Self.same(request, reminder) {
                kept.insert(request.identifier)
            } else {
                stale.append(request.identifier)
            }
        }
        center.removePendingNotificationRequests(withIdentifiers: stale)
        for reminder in planned where !kept.contains(reminder.identifier) {
            try? await center.add(Self.request(reminder, now: now()))
        }
    }

    /// The fire instant is kept in the request (`fire`, seconds from 1970): a time-interval trigger
    /// does not tell its own reliably.
    private static func same(_ request: UNNotificationRequest, _ reminder: PlannedReminder) -> Bool {
        let fire = request.content.userInfo["fire"] as? Double
        return request.content.title == reminder.title && request.content.body == reminder.body
            && fire.map { abs($0 - reminder.fire.timeIntervalSince1970) < 1 } == true
    }

    static func request(_ reminder: PlannedReminder, now: Date) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = reminder.title
        content.body = reminder.body
        content.sound = .default
        var info: [String: Any] = ["event": reminder.event.raw, "fire": reminder.fire.timeIntervalSince1970]
        if let occurrence = reminder.occurrence, let data = try? JSONEncoder().encode(occurrence),
            let text = String(bytes: data, encoding: .utf8) {
            info["occurrence"] = text
        }
        content.userInfo = info
        // Exact in absolute time: a trigger on wall components can fire an hour early in the hour a
        // fall-back repeats. The set is refilled after every sync and zone change, so the interval
        // counted from now holds.
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: max(1, reminder.fire.timeIntervalSince(now)), repeats: false)
        return UNNotificationRequest(identifier: reminder.identifier, content: content, trigger: trigger)
    }
}
