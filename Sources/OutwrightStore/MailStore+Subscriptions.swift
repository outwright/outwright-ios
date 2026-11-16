// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
import GRDB
public import OutwrightModel

/// What the last answer for a subscription gave, to ask with next time and to tell an unchanged
/// body by.
public struct SubscriptionValidators: Sendable, Equatable {
    public var etag: String?
    public var lastModified: String?
    /// The lowercase hex SHA-256 of the last body read.
    public var bodyHash: String?

    public init(etag: String? = nil, lastModified: String? = nil, bodyHash: String? = nil) {
        self.etag = etag
        self.lastModified = lastModified
        self.bodyHash = bodyHash
    }
}

extension MailStore {
    /// Adds a read-only calendar for a subscription, belonging to no account; its address goes to the
    /// keychain under `key`.
    public func addSubscription(key: UUID, host: String, name: String, color: Int?) throws(StoreError) -> CalendarID {
        try write { database in
            let href = "subscription:" + key.uuidString
            let shade = color ?? CalendarPalette.color(account: nil, href: href)
            try database.execute(
                sql: "INSERT INTO calendar (accountId, href, name, color, isReadOnly) VALUES (NULL, ?, ?, ?, 1)",
                arguments: [href, name, shade & 0xFF_FFFF])
            let id = database.lastInsertedRowID
            try database.execute(
                sql: "INSERT INTO calendar_subscription (calendarId, key, host) VALUES (?, ?, ?)",
                arguments: [id, key.uuidString, host])
            return CalendarID(raw: id)
        }
    }

    /// The subscribed calendars, by name.
    public func subscriptions() throws(StoreError) -> [CalendarSubscription] {
        try read { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT c.*, s.key AS subKey, s.host AS subHost, s.fetchedAt AS subFetchedAt,
                        s.failure AS subFailure
                    FROM calendar_subscription s JOIN calendar c ON c.id = s.calendarId
                    ORDER BY c.name, c.id
                    """)
            return rows.compactMap { row in
                guard let calendar = CalendarRecords.calendar(row),
                    let key = (row["subKey"] as String?).flatMap(UUID.init(uuidString:))
                else { return nil }
                return CalendarSubscription(
                    calendar: calendar, key: key, host: (row["subHost"] as String?) ?? "",
                    fetchedAt: (row["subFetchedAt"] as Double?).map(Date.init(timeIntervalSince1970:)),
                    failure: (row["subFailure"] as String?).map { SubscriptionFailure(rawValue: $0) ?? .server })
            }
        }
    }

    public func subscriptionValidators(_ cal: CalendarID) throws(StoreError) -> SubscriptionValidators {
        try read { database in
            let row = try Row.fetchOne(
                database, sql: "SELECT etag, lastModified, bodyHash FROM calendar_subscription WHERE calendarId = ?",
                arguments: [cal.raw])
            return SubscriptionValidators(
                etag: row?["etag"], lastModified: row?["lastModified"], bodyHash: row?["bodyHash"])
        }
    }

    /// A fetch went through: its time and validators kept, any failure cleared.
    public func setSubscriptionFetched(
        _ cal: CalendarID, at time: Date, validators: SubscriptionValidators
    ) throws(StoreError) {
        try write { database in
            try database.execute(
                sql: """
                    UPDATE calendar_subscription SET fetchedAt = ?, failure = NULL, etag = ?, lastModified = ?,
                        bodyHash = ? WHERE calendarId = ?
                    """,
                arguments: [
                    time.timeIntervalSince1970, validators.etag, validators.lastModified, validators.bodyHash, cal.raw
                ])
        }
    }

    /// A fetch failed: its time and failure kept, the validators as they were.
    public func setSubscriptionFailure(
        _ cal: CalendarID, _ failure: SubscriptionFailure, at time: Date
    ) throws(StoreError) {
        try write { database in
            try database.execute(
                sql: "UPDATE calendar_subscription SET fetchedAt = ?, failure = ? WHERE calendarId = ?",
                arguments: [time.timeIntervalSince1970, failure.rawValue, cal.raw])
        }
    }

    public func updateSubscription(_ cal: CalendarID, name: String, color: Int) throws(StoreError) {
        try write { database in
            try database.execute(
                sql: """
                    UPDATE calendar SET name = ?, color = ?
                    WHERE id = ? AND id IN (SELECT calendarId FROM calendar_subscription)
                    """, arguments: [name, color & 0xFF_FFFF, cal.raw])
            guard database.changesCount > 0 else { throw StoreError.noSuchCalendar }
        }
    }

    /// Removes the subscription with its events; the key its address is kept under, for the keychain.
    public func removeSubscription(_ cal: CalendarID) throws(StoreError) -> UUID? {
        try write { database in
            let key = try String.fetchOne(
                database, sql: "SELECT key FROM calendar_subscription WHERE calendarId = ?", arguments: [cal.raw])
            guard let key else { return nil }
            try database.execute(sql: "DELETE FROM calendar WHERE id = ?", arguments: [cal.raw])
            return UUID(uuidString: key)
        }
    }
}
