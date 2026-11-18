// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
public import OutwrightSync
public import OutwrightModel

/// The text of a diagnostics report, which the owner reads before sending it. Its own lines name an
/// account only by number, fingerprint and provider kind; in what came from outside (log lines,
/// MetricKit's payloads) every account's address, user, name and server is replaced by `account N`.
public struct DiagnosticsReport: Sendable {
    /// The most log lines a report holds: the newest.
    static let logLines = 500
    /// The most journal lines a report holds: the newest.
    static let journalLines = 2_000
    /// Identifiers shorter than this are not personal enough to replace, and would mangle the text.
    private static let shortest = 3

    public var version: String
    public var system: String
    public var accounts: [Account]
    public var problems: [AccountProblem]
    public var payloads: [Data]
    public var log: [String]
    /// The diagnostics journal, oldest first: the summary is made from it and its lines are listed.
    public var journal: [JournalEntry]
    /// Each account's push subscription fingerprint, where push is on.
    public var pushFingerprints: [AccountID: String]

    public init(
        version: String, system: String, accounts: [Account], problems: [AccountProblem], payloads: [Data],
        log: [String], journal: [JournalEntry] = [], pushFingerprints: [AccountID: String] = [:]
    ) {
        self.journal = journal
        self.pushFingerprints = pushFingerprints
        self.version = version
        self.system = system
        self.accounts = accounts
        self.problems = problems
        self.payloads = payloads
        self.log = log
    }

    public var text: String {
        let numbers = Dictionary(
            accounts.enumerated().map { ($0.element.id, $0.offset + 1) }, uniquingKeysWith: { first, _ in first })
        var lines = [
            "Outwright diagnostics", "Version: \(version)", "System: \(system)", "Accounts: \(accounts.count)", "",
            "Sync problems:"
        ]
        lines += problems.map { "account \(numbers[$0.account.id] ?? 0): \($0.problem)" }
        if problems.isEmpty { lines.append("none") }
        lines += ["", "Summary:"]
        lines += DiagnosticsSummary.lines(accounts: accounts, entries: journal, pushFingerprints: pushFingerprints)
        // What came from outside (MetricKit's payloads, old log lines) may hold an account's
        // identifiers and is scrubbed; the report's own lines are built from codes, numbers and
        // fingerprints only, and are left as they are (a scrub would mangle "account N" there).
        var crashes = ["", "MetricKit payloads: \(payloads.count)"]
        crashes += payloads.map { String(bytes: $0, encoding: .utf8) ?? "(not UTF-8: \($0.count) bytes)" }
        var journalLines = ["", "Journal:"]
        journalLines += journal.suffix(Self.journalLines).map { DiagnosticsSummary.line($0, numbers: numbers) }
        var log = ["", "Log:"]
        log += self.log.suffix(Self.logLines)
        return [
            lines.joined(separator: "\n"), Self.scrub(crashes.joined(separator: "\n"), accounts: accounts),
            journalLines.joined(separator: "\n"), Self.scrub(log.joined(separator: "\n"), accounts: accounts)
        ].joined(separator: "\n")
    }

    /// Replaces each account's identifiers by `account N` in one pass, longest first, so a host is
    /// replaced before the user name inside it and no replacement is replaced again.
    private static func scrub(_ text: String, accounts: [Account]) -> String {
        var names: [String: String] = [:]
        for (index, account) in accounts.enumerated() {
            let hosts = [account.calDAV, account.calDAVUnconfirmed, account.cardDAV, account.cardDAVUnconfirmed]
                .compactMap { $0.flatMap { URL(string: $0)?.host() } }
            for identifier in [account.email, account.user, account.displayName, account.imap.host, account.smtp.host]
                + hosts
            where identifier.count >= Self.shortest && names[identifier.lowercased()] == nil {
                names[identifier.lowercased()] = "account \(index + 1)"
            }
        }
        let pattern = names.keys.sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern).joined(
            separator: "|")
        guard !names.isEmpty, let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        else { return text }
        var result = ""
        var rest = text.startIndex
        for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text), range.lowerBound >= rest else { continue }
            result += text[rest..<range.lowerBound]
            result += names[text[range].lowercased()] ?? "account"
            rest = range.upperBound
        }
        return result + text[rest...]
    }
}
