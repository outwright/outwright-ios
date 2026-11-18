// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightMIME
import OutwrightModel

/// The quoted original, subject prefixes and Message-IDs.
extension ComposeModel {
    /// The original with a short header, as Outlook quotes: its text, its body HTML cleaned, and
    /// the inline pictures that HTML shows.
    func quote(_ row: MessageRow, _ parsed: MIMEMessage?) -> QuotedOriginal {
        let date = row.date.formatted(Date.FormatStyle(date: .complete, time: .shortened).locale(locale))
        let names = { (list: [Address]) in list.map(Self.display).joined(separator: "; ") }
        var header = [
            "\(L10n.string("From:", locale: locale)) \(Self.display(row.from))",
            "\(L10n.string("Sent:", locale: locale)) \(date)",
            "\(L10n.string("To:", locale: locale)) \(names(parsed?.to ?? row.to))"
        ]
        let copies = parsed?.cc ?? row.cc
        if !copies.isEmpty { header.append("\(L10n.string("Cc:", locale: locale)) \(names(copies))") }
        header.append("\(L10n.string("Subject:", locale: locale)) \(row.subject)")
        let fallback = row.isProtected ? "" : row.preview
        let text = parsed?.textBody ?? parsed?.htmlBody.map(RichText.plain(fromHTML:)) ?? fallback
        let html = parsed?.htmlBody.map { QuoteCleaner.clean($0) }
        return QuotedOriginal(
            header: header, text: String(text.prefix(200_000)), html: html,
            inline: html.map { QuotedOriginal.shown(by: $0, of: parsed?.attachments ?? []) } ?? [])
    }

    /// What didn't fit, once: the sheet says it, and it is not said again.
    func takeLeftOut() -> AttachFailures {
        defer { leftOut = AttachFailures() }
        return leftOut
    }

    /// The quote with only the inline pictures that fit the room the attachments leave; each one left
    /// out goes from its HTML too, and is counted in `leftOut`.
    func fitted(_ quote: QuotedOriginal) -> QuotedOriginal {
        var fitted = quote
        var room = attachmentLimit - attachments.reduce(0) { $0 + $1.data.count }
        var dropped: Set<String> = []
        fitted.inline = []
        for part in quote.inline {
            if part.data.count <= room {
                fitted.inline.append(part)
                room -= part.data.count
            } else {
                leftOut.tooLarge += 1
                if let id = part.contentID { dropped.insert(id) }
            }
        }
        if !dropped.isEmpty { fitted.html = fitted.html.map { QuoteCleaner.clean($0, droppingPictures: dropped) } }
        return fitted
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
