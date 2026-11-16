// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import GRDB
import OutwrightMIME
import OutwrightModel
import Testing

@testable import OutwrightStore

private let utcZone = TimeZone(identifier: "UTC") ?? .gmt

private func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = utcZone
    return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour)) ?? .distantPast
}

/// Inside the window the events are laid out in.
private let now = utc(2027, 1, 1, 12)
private let window = utc(2026, 10, 1)...utc(2027, 4, 1)

private func details(
    _ title: String, at start: Date, place: String = "", notes: String = "", attendees: [Attendee] = []
) -> EventDetails {
    EventDetails(
        title: title, place: place, notes: notes, start: .utc(start), end: .utc(start.addingTimeInterval(3_600)),
        attendees: attendees)
}

private struct EventFixture {
    let base: Fixture
    let cal: CalendarInfo
    var store: MailStore { base.store }

    init() throws {
        base = try Fixture()
        var account = base.account
        account.calDAV = "https://dav.example.org/"
        try base.store.save(account)
        try base.store.replaceCalendars(
            [(href: "/cal/work/", name: "Work", color: nil, isReadOnly: false)], for: base.account.id)
        cal = try #require(try base.store.calendars(base.account.id).first)
    }

    func add(_ uid: String, _ base: EventDetails, rule: RecurrenceRule? = nil) throws {
        try store.upsertRemote(
            href: "/cal/work/\(uid).ics", etag: "e1", ics: Data("BEGIN:VCALENDAR".utf8),
            series: EventSeries(uid: uid, base: base, rule: rule), in: cal.id, window: window, phoneZone: utcZone,
            scheduleTag: nil)
    }

    func titles(_ text: String) throws -> [String] {
        try store.searchEvents(text, now: now, limit: 10).map(\.occurrence.details.title)
    }
}

@Suite struct SearchStoreTests {
    @Test func eventFoundByTitlePlaceNotesAndAttendee() throws {
        let f = try EventFixture()
        try f.add(
            "a",
            details(
                "Presidieberedning", at: utc(2027, 1, 5, 9), place: "Rådhuset", notes: "budget",
                attendees: [Attendee(email: "bea@example.org", name: "Bea Berg")]))
        try f.add("b", details("Lunch", at: utc(2027, 1, 6, 12)))
        for word in ["presid", "radhus", "RÅDHUS", "budg", "bea", "berg", "bea@example"] {
            #expect(try f.titles(word) == ["Presidieberedning"], "\(word)")
        }
        #expect(try f.titles("beredning").isEmpty)
        #expect(try f.titles("presid lunch").isEmpty)
    }

    @Test func weeklySeriesIsOneRowAtItsNextOccurrence() throws {
        let f = try EventFixture()
        try f.add("w", details("Veckomöte", at: utc(2026, 11, 2, 9)), rule: RecurrenceRule(freq: .weekly))
        let found = try f.store.searchEvents("veckomöte", now: now, limit: 10)
        #expect(found.count == 1)
        let start = try #require(found.first?.occurrence.start)
        #expect(start > now)
        #expect(start.timeIntervalSince(now) < 7 * 86_400)
    }

    @Test func upcomingFirstThenPastNewestFirst() throws {
        let f = try EventFixture()
        let day = 86_400.0
        for (uid, offset) in [("m2", -2.0), ("m1", -1.0), ("p3", 3.0), ("p1", 1.0)] {
            try f.add(uid, details("Möte \(uid)", at: now.addingTimeInterval(offset * day)))
        }
        #expect(try f.titles("möte") == ["Möte p1", "Möte p3", "Möte m1", "Möte m2"])
        #expect(try f.store.searchEvents("möte", now: now, limit: 2).count == 2)
    }

    @Test func declinedInvitationIsNotFound() throws {
        let f = try EventFixture()
        var invited = details(
            "Avböjt", at: utc(2027, 1, 7, 9),
            attendees: [Attendee(email: f.base.account.email, response: .declined)])
        invited.organizer = "boss@example.org"
        try f.add("d", invited)
        #expect(try f.store.occurrences(from: window.lowerBound, to: window.upperBound, in: nil).isEmpty)
        #expect(try f.titles("avböjt").isEmpty)
    }

    @Test func existingOccurrencesGetSearchTextOnMigration() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("v11-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let id = UUID().uuidString
        let soon = Date().addingTimeInterval(86_400)
        let series = EventSeries(uid: "old", base: details("Styrelsemöte", at: soon))
        do {
            let old = try DatabaseQueue(path: url.path)
            try Schema.migrator().migrate(old, upTo: "v11")
            try old.write { database in
                try database.execute(
                    sql: """
                        INSERT INTO account (id, displayName, email, colorIndex, imapHost, imapPort,
                            imapSecurity, smtpHost, smtpPort, smtpSecurity, user, signature, sortOrder)
                        VALUES (?, 'Anna', 'anna@example.org', 0, 'm.example.org', 993, 'tls',
                            'm.example.org', 465, 'tls', 'anna', '', 0)
                        """, arguments: [id])
                try database.execute(
                    sql: "INSERT INTO calendar (id, accountId, href, name, color, isReadOnly) VALUES (1, ?, '/cal/', 'Work', 0, 0)",
                    arguments: [id])
                try database.execute(
                    sql: "INSERT INTO event (id, accountId, calendarId, href, uid, seriesJSON) VALUES (1, ?, 1, '/cal/old.ics', 'old', ?)",
                    arguments: [id, CalendarRecords.encode(series)])
            }
        }
        let store = try MailStore(path: url)
        #expect(try store.searchEvents("styrelse", now: Date(), limit: 5).map(\.occurrence.details.title)
            == ["Styrelsemöte"])
    }

    @Test func suggestionsCompleteTheWordMostMessagesFirst() throws {
        let f = try Fixture()
        let subjects = ["performance", "performance", "performance plan", "personal", "per", "per"]
        _ = try f.store.upsert(subjects.enumerated().map { index, subject in
            row(f.account.id, f.inbox.id, uid: UInt32(index + 1), subject: subject)
        })
        #expect(try f.store.suggestedWords(startingWith: "Per", limit: 3) == ["performance", "personal"])
        #expect(try f.store.suggestedWords(startingWith: "p", limit: 3).isEmpty)
        #expect(try f.store.suggestedWords(startingWith: "perf", limit: 1) == ["performance"])
    }

    @Test func searchToleratesAnyText() throws {
        let f = try EventFixture()
        try f.add("a", details("Möte", at: utc(2027, 1, 5, 9)))
        _ = try f.store.upsert([row(f.base.account.id, f.base.inbox.id, uid: 1, subject: "per cent")])
        var generator = SystemRandomNumberGenerator()
        let specials: [Character] = ["%", "_", "\\", "\"", "*", "'", " ", "-", "^", ":", "(", ")"]
        for _ in 0..<500 {
            var text = ""
            for _ in 0..<Int.random(in: 0...12, using: &generator) {
                if Bool.random(using: &generator), let special = specials.randomElement(using: &generator) {
                    text.append(special)
                } else if let scalar = Unicode.Scalar(UInt32.random(in: 0x20...0x2FFF, using: &generator)) {
                    text.unicodeScalars.append(scalar)
                }
            }
            #expect(try f.store.searchEvents(text, now: now, limit: 3).count <= 3)
            #expect(try f.store.suggestedWords(startingWith: text, limit: 3).count <= 3)
        }
    }
}

private struct PeopleFixture {
    let base: Fixture
    let book: AddressBook
    var store: MailStore { base.store }

    init() throws {
        base = try Fixture()
        var account = base.account
        account.cardDAV = "https://dav.example.org/"
        try base.store.save(account)
        try base.store.replaceAddressBooks([(href: "/book/", name: "Contacts", isReadOnly: false)], for: account.id)
        book = try #require(try base.store.addressBooks(account.id).first)
    }

    func add(_ href: String, _ details: ContactDetails) throws {
        try store.upsertRemote(
            href: href, etag: "e1", vcard: Data("BEGIN:VCARD".utf8), details: details, photo: nil, in: book.id)
    }

    func names(_ text: String) throws -> [String] {
        try store.searchContacts(text, limit: 10).map(\.details.name)
    }
}

extension SearchStoreTests {
    @Test func contactFoundByNameOrganizationAddressAndPhone() throws {
        let f = try PeopleFixture()
        try f.add(
            "/book/t.vcf",
            ContactDetails(
                givenName: "Therese", familyName: "Persson", organization: "Stampen",
                emails: [Labeled(label: "work", value: "therese@example.org")],
                phones: [Labeled(label: "cell", value: "+46 70-123 45 67")]))
        try f.add("/book/o.vcf", ContactDetails(givenName: "Olle", familyName: "Berg"))
        for text in ["pers", "THER", "stamp", "therese@", "therese pers", "0701234", "70-123"] {
            #expect(try f.names(text) == ["Therese Persson"], "\(text)")
        }
        #expect(try f.names("erss").isEmpty)
        #expect(try f.names("12").isEmpty)
    }

    @Test func contactWithOnlyAnOrganizationIsFound() throws {
        let f = try PeopleFixture()
        try f.add("/book/k.vcf", ContactDetails(organization: "Kommunen"))
        let found = try f.store.searchContacts("kommun", limit: 10)
        #expect(found.map(\.details.organization) == ["Kommunen"])
    }

    @Test func personFromAndTo() throws {
        let f = try Fixture()
        var copied = row(f.account.id, f.inbox.id, uid: 3, subject: "cc", from: "carl@example.org", minutes: 3)
        copied.cc = [Address(name: nil, email: "Bo@Example.org")]
        _ = try f.store.upsert([
            row(f.account.id, f.inbox.id, uid: 1, subject: "from bo", from: "bo@example.org", minutes: 1),
            row(f.account.id, f.sent.id, uid: 2, subject: "to bo", from: "anna@example.org",
                to: ["bo@example.org"], minutes: 2),
            copied,
            row(f.account.id, f.inbox.id, uid: 4, subject: "from jbo", from: "jbo@example.org",
                to: ["jbo@example.org"], minutes: 4)
        ])
        func subjects(_ direction: PersonDirection) throws -> [String] {
            try f.store.messages(
                involving: ["bo@example.org"], direction: direction, matching: nil, filter: SearchFilter(), limit: 50
            ).map(\.subject)
        }
        #expect(try subjects(.from) == ["from bo"])
        #expect(try subjects(.to) == ["cc", "to bo"])
    }

    @Test func personMailMatchesWordsAndFilters() throws {
        let f = try Fixture()
        var attached = row(f.account.id, f.inbox.id, uid: 3, subject: "budget bilaga", minutes: 3, read: true)
        attached.hasAttachment = true
        _ = try f.store.upsert([
            row(f.account.id, f.inbox.id, uid: 1, subject: "budget olästa", minutes: 1),
            row(f.account.id, f.inbox.id, uid: 2, subject: "budget flaggad", minutes: 2, read: true, flagged: true),
            attached,
            row(f.account.id, f.inbox.id, uid: 4, subject: "lunch", minutes: 4, read: true)
        ])
        func subjects(_ text: String?, _ filter: SearchFilter) throws -> [String] {
            try f.store.messages(
                involving: ["bo@example.org"], direction: .from, matching: text, filter: filter, limit: 50
            ).map(\.subject)
        }
        #expect(try subjects("budget", SearchFilter()) == ["budget bilaga", "budget flaggad", "budget olästa"])
        #expect(try subjects(nil, SearchFilter(unread: true)) == ["budget olästa"])
        #expect(try subjects(nil, SearchFilter(flagged: true)) == ["budget flaggad"])
        #expect(try subjects(nil, SearchFilter(attachments: true)) == ["budget bilaga"])
        #expect(try subjects(nil, SearchFilter(unread: true, flagged: true)).isEmpty)
        let cut = Date(timeIntervalSince1970: 1_700_000_000 + 2.5 * 60)
        #expect(try subjects(nil, SearchFilter(olderThan: cut)) == ["budget flaggad", "budget olästa"])
        #expect(SearchFilter(unread: true, flagged: true).count == 2)
        #expect(SearchFilter(olderThan: cut).count == 0)
    }

    @Test func textSearchTakesTheFilter() throws {
        let f = try Fixture()
        var attached = row(f.account.id, f.inbox.id, uid: 2, subject: "lunch med bilaga", minutes: 2)
        attached.hasAttachment = true
        _ = try f.store.upsert([row(f.account.id, f.inbox.id, uid: 1, subject: "lunch", minutes: 1), attached])
        #expect(try f.store.search("lunch", filter: SearchFilter(attachments: true), limit: 10).map(\.subject)
            == ["lunch med bilaga"])
        #expect(try f.store.search("lunch", filter: SearchFilter(), limit: 10).count == 2)
    }

    @Test func contactAndPersonSearchTolerateAnyText() throws {
        let f = try PeopleFixture()
        try f.add("/book/a.vcf", ContactDetails(givenName: "Åsa", phones: [Labeled(label: "", value: "+46 8 123")]))
        _ = try f.store.upsert([row(f.base.account.id, f.base.inbox.id, uid: 1, subject: "hej")])
        var generator = SystemRandomNumberGenerator()
        let specials: [Character] = ["%", "_", "\\", "\"", "*", "'", " ", "@", "1", "/", "(", ")"]
        for _ in 0..<500 {
            var text = ""
            for _ in 0..<Int.random(in: 0...16, using: &generator) {
                if Bool.random(using: &generator), let special = specials.randomElement(using: &generator) {
                    text.append(special)
                } else if let scalar = Unicode.Scalar(UInt32.random(in: 0x20...0x2FFF, using: &generator)) {
                    text.unicodeScalars.append(scalar)
                }
            }
            #expect(try f.store.searchContacts(text, limit: 3).count <= 3)
            let mail = try f.store.messages(
                involving: [text, "bo@example.org"], direction: .to, matching: text,
                filter: SearchFilter(unread: true), limit: 3)
            #expect(mail.count <= 3)
            #expect(try f.store.search(text, filter: SearchFilter(flagged: true), limit: 3).count <= 3)
        }
    }
}

extension SearchStoreTests {
    /// A quote followed by a combining mark is one Character: it must still be dropped from the
    /// FTS5 query instead of breaking it.
    @Test func quoteBeforeACombiningMarkDoesNotBreakTheSearch() throws {
        let f = try Fixture()
        _ = try f.store.upsert([row(f.account.id, f.inbox.id, uid: 1, subject: "hej")])
        #expect(try f.store.search("a\"\u{0301}b", limit: 5).isEmpty)
    }
}

extension SearchStoreTests {
    /// Many matching series in the past must not crowd out the next occurrences and later events.
    @Test func manyPastOccurrencesDoNotHideUpcomingOnes() throws {
        let f = try EventFixture()
        for index in 0..<60 {
            try f.add("d\(index)", details("Möte \(index)", at: utc(2026, 10, 2, 8)), rule: RecurrenceRule(freq: .daily))
        }
        try f.add("future", details("Möte framåt", at: utc(2027, 3, 1, 9)))
        let found = try f.store.searchEvents("möte", now: now, limit: 100)
        #expect(found.count == 61)
        #expect(found.allSatisfy { $0.occurrence.end > now })
        #expect(found.contains { $0.occurrence.details.title == "Möte framåt" })
    }
}
