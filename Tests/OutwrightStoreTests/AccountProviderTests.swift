// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import GRDB
import OutwrightModel
import Testing

@testable import OutwrightStore

@Suite struct AccountProviderTests {
    /// A store at the migration before providers, with one account row, then opened by today's code.
    private func migrated(auth: String, calDAV: String?, cardDAV: String?) throws -> (MailStore, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent("mail.sqlite")
        do {
            let old = try DatabaseQueue(path: path.path)
            try Schema.migrator().migrate(old, upTo: "v15")
            try old.write { database in
                try database.execute(
                    sql: """
                        INSERT INTO account (id, displayName, email, colorIndex, imapHost, imapPort,
                            imapSecurity, smtpHost, smtpPort, smtpSecurity, user, signature, sortOrder,
                            calDAV, cardDAV, auth)
                        VALUES (?, 'Anna', 'anna@example.org', 0, 'mail.example.org', 993, 'tls',
                            'mail.example.org', 465, 'tls', 'anna', '', 0, ?, ?, ?)
                        """, arguments: [UUID().uuidString, calDAV, cardDAV, auth])
            }
        }
        return (try MailStore(path: path), folder)
    }

    @Test func migratesMicrosoftAccount() throws {
        let (store, folder) = try migrated(auth: "microsoft", calDAV: nil, cardDAV: nil)
        defer { try? FileManager.default.removeItem(at: folder) }
        let account = try #require(try store.accounts().first)
        #expect(account.provider.raw == "microsoft")
        #expect(account.auth == .oauth)
        #expect(account.calendarVia == .graph)
        #expect(account.contactsVia == .graph)
    }

    @Test func migratesPasswordAccount() throws {
        let (store, folder) = try migrated(
            auth: "password", calDAV: "https://dav.example.org/cal/", cardDAV: "https://dav.example.org/card/")
        defer { try? FileManager.default.removeItem(at: folder) }
        let account = try #require(try store.accounts().first)
        #expect(account.provider == .ownServer)
        #expect(account.auth == .password)
        #expect(account.calendarVia == .calDAV)
        #expect(account.contactsVia == .cardDAV)
        #expect(account.calDAV == "https://dav.example.org/cal/")
        #expect(account.cardDAV == "https://dav.example.org/card/")
    }

    @Test func unknownProviderSurvivesSave() throws {
        let store = try MailStore(path: nil)
        var account = Fixture.makeAccount(name: "Anna", email: "anna@example.org", order: 0)
        account.provider = ProviderID(raw: "yahoo-future")
        try store.save(account)
        var read = try #require(try store.accounts().first)
        read.displayName = "Anna L"
        try store.save(read)
        #expect(try store.accounts().first?.provider.raw == "yahoo-future")
    }

    @Test func providerAndProtocolsRoundTrip() throws {
        let store = try MailStore(path: nil)
        var account = Fixture.makeAccount(name: "Anna", email: "anna@example.org", order: 0)
        account.auth = .oauth
        account.calendarVia = .graph
        account.contactsVia = .graph
        try store.save(account)
        let read = try #require(try store.accounts().first)
        #expect(read.auth == .oauth)
        #expect(read.calendarVia == .graph)
        #expect(read.contactsVia == .graph)
    }

    @Test func graphAccountHasSourcesWithoutAddresses() throws {
        let store = try MailStore(path: nil)
        var account = Fixture.makeAccount(name: "Anna", email: "anna@example.org", order: 0)
        account.calendarVia = .graph
        account.contactsVia = .graph
        try store.save(account)
        let row = try store.read { try Row.fetchOne($0, sql: "SELECT * FROM account") }
        #expect(MailStore.hasCalendarSource(row))
        #expect(MailStore.hasContactSource(row))
    }

    @Test func davAccountNeedsItsAddress() throws {
        let store = try MailStore(path: nil)
        try store.save(Fixture.makeAccount(name: "Anna", email: "anna@example.org", order: 0))
        let row = try store.read { try Row.fetchOne($0, sql: "SELECT * FROM account") }
        #expect(!MailStore.hasCalendarSource(row))
        #expect(!MailStore.hasContactSource(row))
    }

    @Test func unknownAuthReadsAsPassword() throws {
        let store = try MailStore(path: nil)
        try store.save(Fixture.makeAccount(name: "Anna", email: "anna@example.org", order: 0))
        try store.write { database in
            try database.execute(sql: "UPDATE account SET auth = 'kerberos'")
        }
        #expect(try store.accounts().first?.auth == .password)
    }
}
