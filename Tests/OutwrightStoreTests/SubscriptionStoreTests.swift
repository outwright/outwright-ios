// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import GRDB
import OutwrightModel
import Testing

@testable import OutwrightStore

private let now = Date(timeIntervalSince1970: 1_793_966_400)
private let window = now.addingTimeInterval(-86_400 * 30)...now.addingTimeInterval(86_400 * 60)

@Suite struct SubscriptionStoreTests {
    let base: Fixture
    var store: MailStore { base.store }
    var account: AccountID { base.account.id }

    init() throws {
        base = try Fixture()
    }

    func add(_ name: String = "Work") throws -> CalendarID {
        try store.addSubscription(key: UUID(), host: "outlook.example.org", name: name, color: nil)
    }

    func putEvent(in cal: CalendarID) throws {
        let details = EventDetails(
            title: "Review", start: .utc(now.addingTimeInterval(86_400)), end: .utc(now.addingTimeInterval(90_000)))
        try store.upsertRemote(
            href: "uid:e1", etag: "x", ics: Data("BEGIN:VCALENDAR".utf8),
            series: EventSeries(uid: "e1", base: details), in: cal, window: window, phoneZone: .gmt, scheduleTag: nil)
    }

    func events() throws -> [CalendarEvent] {
        try store.occurrences(from: window.lowerBound, to: window.upperBound, in: nil)
    }

    @Test func addAndList() throws {
        let cal = try add()
        let found = try #require(try store.subscriptions().first)
        #expect(found.id == cal)
        #expect(found.host == "outlook.example.org")
        #expect(found.calendar.isReadOnly)
        #expect(found.calendar.accountID == nil)
        #expect(found.fetchedAt == nil && found.failure == nil)
        #expect(try !store.calendars(account).contains { $0.id == cal })
        #expect(try store.allCalendars().contains { $0.id == cal })
    }

    @Test func replaceAndClearKeepSubscriptions() throws {
        let cal = try add()
        try putEvent(in: cal)
        try store.replaceCalendars([], for: account)
        #expect(try store.subscriptions().count == 1)
        #expect(try events().count == 1)
        try store.clearCalendars(of: account)
        #expect(try store.subscriptions().count == 1)
        #expect(try events().count == 1)
    }

    @Test func fetchedAndFailureRoundTrip() throws {
        let cal = try add()
        let validators = SubscriptionValidators(etag: "\"a\"", lastModified: "x", bodyHash: "h")
        try store.setSubscriptionFailure(cal, .unreachable, at: now)
        try store.setSubscriptionFetched(cal, at: now, validators: validators)
        var found = try #require(try store.subscriptions().first)
        #expect(found.failure == nil && found.fetchedAt == now)
        #expect(try store.subscriptionValidators(cal) == validators)
        try store.setSubscriptionFailure(cal, .unpublished, at: now.addingTimeInterval(60))
        found = try #require(try store.subscriptions().first)
        #expect(found.failure == .unpublished)
        #expect(try store.subscriptionValidators(cal) == validators)
    }

    @Test func updateRenamesAndRecolours() throws {
        let cal = try add()
        try store.updateSubscription(cal, name: "Jobb", color: 0x2E9E6B)
        let found = try #require(try store.subscriptions().first)
        #expect(found.calendar.name == "Jobb" && found.calendar.color == 0x2E9E6B)
    }

    @Test func removeSubscriptionDropsEvents() throws {
        let key = UUID()
        let cal = try store.addSubscription(key: key, host: "h", name: "Work", color: nil)
        try putEvent(in: cal)
        #expect(try store.removeSubscription(cal) == key)
        #expect(try store.subscriptions().isEmpty)
        #expect(try events().isEmpty)
    }

    @Test func removingAnAccountKeepsSubscriptions() throws {
        let cal = try add()
        try putEvent(in: cal)
        try store.removeAccount(account)
        #expect(try store.subscriptions().map(\.id) == [cal])
        #expect(try events().count == 1)
    }

    @Test func subscriptionsNeedNoAccount() throws {
        let empty = try MailStore(path: nil)
        let cal = try empty.addSubscription(key: UUID(), host: "h", name: "Work", color: nil)
        #expect(try empty.subscriptions().map(\.id) == [cal])
    }

    @Test func migrationTakesSubscriptionsOffTheirAccount() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("v16-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let id = UUID().uuidString
        do {
            let old = try DatabaseQueue(path: url.path)
            try Schema.migrator().migrate(old, upTo: "v16")
            try old.write { database in
                try database.execute(
                    sql: """
                        INSERT INTO account (id, displayName, email, colorIndex, imapHost, imapPort,
                            imapSecurity, smtpHost, smtpPort, smtpSecurity, user, signature, sortOrder)
                        VALUES ('\(id)', 'Anna', 'anna@example.org', 0, 'm.example.org', 993, 'tls',
                            'm.example.org', 465, 'tls', 'anna', '', 0);
                        INSERT INTO calendar (id, accountId, href, name, color, isReadOnly)
                        VALUES (1, '\(id)', '/cal/', 'Home', 0, 0), (2, '\(id)', 'subscription:x', 'Work', 0, 1);
                        INSERT INTO calendar_subscription (calendarId, key, host)
                        VALUES (2, '\(UUID().uuidString)', 'h');
                        INSERT INTO event (id, accountId, calendarId, uid, seriesJSON) VALUES (1, '\(id)', 2, 'e', '{}');
                        """)
            }
        }
        let store = try MailStore(path: url)
        let owner = try #require(try store.accounts().first).id
        #expect(try store.subscriptions().first?.calendar.accountID == nil)
        #expect(try store.calendars(owner).map(\.name) == ["Home"])
        try store.removeAccount(owner)
        #expect(try store.subscriptions().count == 1)
        let held = try DatabaseQueue(path: url.path).read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM event WHERE accountId IS NULL")
        }
        #expect(held == 1)
    }

    @Test func notTheDefault() throws {
        _ = try add()
        #expect(try store.defaultCalendar() == nil)
    }

    @Test func asManyAsTheOwnerWants() throws {
        for index in 0..<120 { _ = try add("c\(index)") }
        #expect(try store.subscriptions().count == 120)
    }
}
