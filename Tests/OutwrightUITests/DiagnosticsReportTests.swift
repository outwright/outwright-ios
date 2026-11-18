// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightModel
import OutwrightSync
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

    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func at(_ minutes: Double, _ event: JournalEvent) -> JournalEntry {
        JournalEntry(date: start.addingTimeInterval(minutes * 60), event: event)
    }

    @Test func theSummaryShowsEachProtocolsHealth() {
        let account = anna()
        let failing = [
            at(0, .sync(account: account.id, kind: .mail, code: nil)),
            at(1, .sync(account: account.id, kind: .mail, code: "imap.net.timeout")),
            at(2, .sync(account: account.id, kind: .mail, code: "imap.net.timeout")),
            at(3, .send(account: account.id, code: "smtp.authenticationFailed")),
        ]
        let text = DiagnosticsReport(
            version: "1", system: "iOS", accounts: [account], problems: [], payloads: [], log: [], journal: failing).text
        #expect(text.contains("mail: last ok 2027-01-15T08:00:00Z, last error imap.net.timeout, 2 in a row"))
        #expect(text.contains("send: never ok, last error smtp.authenticationFailed, 1 in a row"))
        let healed = failing + [at(4, .sync(account: account.id, kind: .mail, code: nil))]
        let after = DiagnosticsReport(
            version: "1", system: "iOS", accounts: [account], problems: [], payloads: [], log: [], journal: healed).text
        #expect(after.contains("mail: ok 2027-01-15T08:04:00Z"))
    }

    @Test func theSummaryNamesAnAccountOnlyByFingerprintAndKind() {
        let account = anna()
        let text = DiagnosticsReport(
            version: "1", system: "iOS", accounts: [account], problems: [], payloads: [], log: [], journal: [],
            pushFingerprints: [account.id: "f60bc0f3"]).text
        let fingerprint = PushNoticeLog.fingerprint(account.id.raw.uuidString)
        #expect(text.contains("account 1 \(fingerprint) own-server push f60bc0f3"))
    }

    @Test func aRemovedAccountIsLeftOutOfTheSummary() {
        let gone = AccountID()
        let text = DiagnosticsReport(
            version: "1", system: "iOS", accounts: [], problems: [], payloads: [], log: [],
            journal: [at(0, .sync(account: gone, kind: .mail, code: nil))]).text
        #expect(!text.contains("mail: ok"))
        #expect(text.contains("sync \(PushNoticeLog.fingerprint(gone.raw.uuidString)) mail ok"))
    }

    /// Every kind of event, with accounts that have real-looking addresses and hosts: none of them
    /// reaches the report.
    @Test func noAddressOrHostAppears() {
        let account = anna()
        let journal = [
            at(0, .launch(version: "0.1.6", build: "0.1.6")),
            at(1, .sync(account: account.id, kind: .calendar, code: "dav.status.401")),
            at(2, .send(account: account.id, code: nil)),
            at(3, .push(subscription: "f60bc0f3", why: .found, count: 1, shown: .details, milliseconds: 812,
                        availableKB: 9_876)),
            at(4, .store(bytes: 1_000, messages: 10)),
            at(5, .migration(names: ["v1"], milliseconds: 3)),
        ]
        let text = DiagnosticsReport(
            version: "1", system: "iOS", accounts: [account], problems: [], payloads: [], log: [], journal: journal)
            .text.lowercased()
        for leaked in ["anna@example.org", "imap.example.org", "smtp.example.org", "calendar.example.org", "andersson"] {
            #expect(!text.contains(leaked), "\(leaked) is in the report")
        }
        #expect(text.contains("push f60bc0f3 found count=1 shown=details 812ms 9876kb free"))
        #expect(text.contains("store 1000 bytes 10 messages"))
    }

    /// The summary first, then MetricKit's crash and hang reports, then the journal.
    @Test func theReportReadsInTheDesignsOrder() throws {
        let text = DiagnosticsReport(
            version: "1", system: "iOS", accounts: [anna()], problems: [], payloads: [Data("{}".utf8)], log: ["old"],
            journal: [at(0, .store(bytes: 1, messages: 1))]).text
        let summary = try #require(text.range(of: "Summary:")).lowerBound
        let crashes = try #require(text.range(of: "MetricKit payloads:")).lowerBound
        let journal = try #require(text.range(of: "Journal:")).lowerBound
        #expect(summary < crashes && crashes < journal)
    }
}

