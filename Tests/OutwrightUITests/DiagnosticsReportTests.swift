// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightModel
import Testing

@testable import OutwrightUI

@Suite struct DiagnosticsReportTests {
    private func anna() -> Account {
        Account(
            id: AccountID(), displayName: "Anna Andersson", email: "anna@example.org", colorIndex: 0,
            imap: MailEndpoint(host: "imap.example.org", port: 993, security: "tls"),
            smtp: MailEndpoint(host: "smtp.example.org", port: 465, security: "tls"), user: "anna",
            signature: "", sortOrder: 0, cardDAVUnconfirmed: "https://contacts.example.net/dav/",
            calDAV: "https://calendar.example.org/dav/")
    }

    @Test func scrubsAccountIdentifiers() {
        let account = anna()
        let leaked = "ANNA@example.org anna IMAP.example.org smtp.example.org Anna Andersson "
            + "calendar.example.org contacts.example.net"
        let report = DiagnosticsReport(
            version: "1.0 (1)", system: "iOS 26", accounts: [account],
            problems: [AccountProblem(account: account, problem: .signIn)],
            payloads: [Data("{\"note\":\"\(leaked)\"}".utf8)], log: ["connect \(leaked)"]).text
        let lowered = report.lowercased()
        for identifier in [
            "anna@example.org", "anna", "imap.example.org", "smtp.example.org", "calendar.example.org",
            "contacts.example.net"
        ] {
            #expect(!lowered.contains(identifier), "\(identifier) is in the report")
        }
        #expect(report.contains("account 1"))
        #expect(report.contains("account 1: signIn"))
    }

    @Test func capsTheLog() {
        let report = DiagnosticsReport(
            version: "1.0", system: "iOS", accounts: [], problems: [], payloads: [],
            log: (0..<800).map { "line \($0)" }).text
        let lines = report.split(separator: "\n").filter { $0.hasPrefix("line ") }
        #expect(lines.count == 500)
        #expect(lines.first == "line 300")
        #expect(lines.last == "line 799")
    }

    @Test func noAccountsStillReports() {
        let report = DiagnosticsReport(version: "", system: "", accounts: [], problems: [], payloads: [], log: []).text
        #expect(!report.isEmpty)
    }

    @Test func eachPayloadIsIncluded() {
        let report = DiagnosticsReport(
            version: "1.0", system: "iOS", accounts: [], problems: [],
            payloads: [Data("{\"first\":1}".utf8), Data("{\"second\":2}".utf8)], log: []).text
        #expect(report.contains("{\"first\":1}"))
        #expect(report.contains("{\"second\":2}"))
    }

    @Test func aReplacementIsNotReplacedAgain() {
        let account = Account(
            id: AccountID(), displayName: "Anna", email: "anna@example.org", colorIndex: 0,
            imap: MailEndpoint(host: "imap.example.org", port: 993, security: "tls"),
            smtp: MailEndpoint(host: "smtp.example.org", port: 465, security: "tls"), user: "count",
            signature: "", sortOrder: 0)
        let report = DiagnosticsReport(
            version: "1.0", system: "iOS", accounts: [account], problems: [], payloads: [],
            log: ["login anna@example.org as count"]).text
        #expect(report.contains("login account 1 as account 1"))
        #expect(!report.contains("acaccount"))
    }
}
