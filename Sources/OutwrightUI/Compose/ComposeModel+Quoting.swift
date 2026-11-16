// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightMIME
import OutwrightModel

/// The quoted original, subject prefixes and Message-IDs.
extension ComposeModel {
    /// The original under a line and a short header, as Outlook quotes.
    func quoted(_ row: MessageRow, _ parsed: MIMEMessage?) -> String {
        let date = row.date.formatted(Date.FormatStyle(date: .complete, time: .shortened).locale(locale))
        let names = { (list: [Address]) in list.map(Self.display).joined(separator: "; ") }
        var lines = [
            "", "________________________________",
            "\(L10n.string("From:", locale: locale)) \(Self.display(row.from))",
            "\(L10n.string("Sent:", locale: locale)) \(date)",
            "\(L10n.string("To:", locale: locale)) \(names(parsed?.to ?? row.to))"
        ]
        let copies = parsed?.cc ?? row.cc
        if !copies.isEmpty { lines.append("\(L10n.string("Cc:", locale: locale)) \(names(copies))") }
        lines.append("\(L10n.string("Subject:", locale: locale)) \(row.subject)")
        let fallback = row.isProtected ? "" : row.preview
        let text = parsed?.textBody ?? parsed?.htmlBody.map(RichText.plain(fromHTML:)) ?? fallback
        return lines.joined(separator: "\n") + "\n\n" + String(text.prefix(200_000))
    }

    static func display(_ address: Address) -> String {
        guard let name = address.name, !name.isEmpty else { return address.email }
        return "\(name) <\(address.email)>"
    }

    /// `Re: Subject`, without piling prefixes on (`Re: Sv: AW: Subject` becomes `Re: Subject`).
    static func prefixed(_ subject: String, _ prefix: String) -> String {
        let known = ["re:", "sv:", "aw:", "fw:", "fwd:", "vb:", "vs:", "wg:", "tr:"]
        var rest = Substring(subject)
        for _ in 0..<10 {
            let trimmed = rest.drop { $0.isWhitespace }
            guard let found = known.first(where: { trimmed.lowercased().hasPrefix($0) }) else {
                rest = trimmed
                break
            }
            rest = trimmed.dropFirst(found.count)
        }
        return "\(prefix) \(rest.drop { $0.isWhitespace })"
    }

    static func preview(_ text: String) -> String {
        String(text.split(whereSeparator: \.isNewline).joined(separator: " ").prefix(200))
    }

    static func mintMessageID(for email: String?) -> String {
        let domain = email?.split(separator: "@").last.map(String.init) ?? "outwright.invalid"
        return "\(UUID().uuidString)@\(domain)"
    }
}
