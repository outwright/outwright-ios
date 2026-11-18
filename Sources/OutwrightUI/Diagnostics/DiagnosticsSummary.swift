// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightModel
import OutwrightSync

/// The diagnostics report's summary and journal lines, made only of what the journal holds:
/// codes, counts, times, sizes and fingerprints. An account is its number in the report, its
/// fingerprint and its provider kind, never its address, name or servers.
enum DiagnosticsSummary {
    /// Per account: who it is, then for each of mail, calendar, contacts and send it has events
    /// for, whether the last one worked, when it last did, its last error and how many failed in
    /// a row. An account no longer on the phone is left out.
    static func lines(accounts: [Account], entries: [JournalEntry], pushFingerprints: [AccountID: String]) -> [String] {
        var lines: [String] = []
        for (index, account) in accounts.enumerated() {
            var head = "account \(index + 1) \(fingerprint(account.id)) \(account.provider.raw)"
            if let push = pushFingerprints[account.id] { head += " push \(push)" }
            lines.append(head)
            for (name, outcomes) in outcomes(of: account.id, in: entries) where !outcomes.isEmpty {
                lines.append("  \(name): \(health(outcomes))")
            }
        }
        return lines.isEmpty ? ["none"] : lines
    }

    /// One journal entry as a report line; `numbers` names the accounts still on the phone.
    static func line(_ entry: JournalEntry, numbers: [AccountID: Int]) -> String {
        let date = entry.date.ISO8601Format()
        func who(_ id: AccountID) -> String { numbers[id].map { "account \($0)" } ?? fingerprint(id) }
        switch entry.event {
        case let .launch(version, build):
            return "\(date) launch \(version) (\(build))"
        case let .sync(account, kind, code):
            return "\(date) sync \(who(account)) \(kind.rawValue) \(code ?? "ok")"
        case let .send(account, code):
            return "\(date) send \(who(account)) \(code ?? "ok")"
        case let .push(subscription, why, count, shown, milliseconds, availableKB):
            var line = "\(date) push \(subscription) \(why.rawValue)"
            if let count { line += " count=\(count)" }
            if let shown { line += " shown=\(shown.rawValue)" }
            if let milliseconds { line += " \(milliseconds)ms" }
            if let availableKB { line += " \(availableKB)KB free" }
            return line
        case let .store(bytes, messages):
            return "\(date) store \(bytes) bytes \(messages) messages"
        case let .migration(names, milliseconds):
            return "\(date) migration \(names.joined(separator: ",")) \(milliseconds)ms"
        }
    }

    /// The first 8 hex digits of the account id's SHA-256, as push subscriptions are told apart.
    static func fingerprint(_ id: AccountID) -> String {
        PushNoticeLog.fingerprint(id.raw.uuidString)
    }

    /// Each kind's outcomes for the account, oldest first: the date and the code (nil: it worked).
    private static func outcomes(
        of id: AccountID, in entries: [JournalEntry]
    ) -> [(String, [(Date, String?)])] {
        var mail: [(Date, String?)] = [], calendar: [(Date, String?)] = []
        var contacts: [(Date, String?)] = [], send: [(Date, String?)] = []
        for entry in entries {
            switch entry.event {
            case let .sync(account, kind, code) where account == id:
                switch kind {
                case .mail: mail.append((entry.date, code))
                case .calendar: calendar.append((entry.date, code))
                case .contacts: contacts.append((entry.date, code))
                }
            case let .send(account, code) where account == id:
                send.append((entry.date, code))
            default:
                break
            }
        }
        return [("mail", mail), ("calendar", calendar), ("contacts", contacts), ("send", send)]
    }

    private static func health(_ outcomes: [(Date, String?)]) -> String {
        let lastOK = outcomes.last { $0.1 == nil }?.0
        guard let last = outcomes.last, let code = last.1 else {
            return "ok \(lastOK?.ISO8601Format() ?? "")"
        }
        let inARow = outcomes.reversed().prefix { $0.1 != nil }.count
        let since = lastOK.map { "last ok \($0.ISO8601Format())" } ?? "never ok"
        return "\(since), last error \(code), \(inARow) in a row"
    }
}
