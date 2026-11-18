// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import OutwrightMIME
import SwiftUI

/// The message a reply or forward answers, kept under what the owner writes: shown read-only (as
/// text: compose has no web view) and sent after the owner's own text, its HTML cleaned and quoted
/// in `<blockquote type="cite">`, its inline pictures with their Content-IDs.
public struct QuotedOriginal: Sendable {
    /// "From: …", "Sent: …", "To: …", "Cc: …", "Subject: …", in the interface's language.
    public var header: [String]
    /// The original's text.
    public var text: String
    /// The original's body HTML, cleaned (`QuoteCleaner`); nil when it had only text.
    public var html: String?
    /// The pictures the HTML shows by `cid:`, sent along as inline parts.
    public var inline: [Attachment]

    /// Marks where the quote starts in the HTML sent, so a draft opened again finds it.
    static let marker = "<div id=\"outwright-quote\">"
    private static let cite = "<blockquote type=\"cite\">"
    static let line = "________________________________"

    /// What is shown under the editor.
    var shown: String {
        header.joined(separator: "\n") + "\n\n" + text
    }

    /// The text part: under a line, the header, and the original in "> " lines.
    var plain: String {
        let quoted = text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.isEmpty ? ">" : "> " + $0 }
        return "\n\n" + Self.line + "\n" + header.joined(separator: "\n") + "\n\n" + quoted.joined(separator: "\n")
    }

    /// The HTML part's quote, after the owner's own HTML.
    var htmlQuote: String {
        let content = html ?? RichText.escape(text).replacingOccurrences(of: "\n", with: "<br>")
        let lines = header.map(RichText.escape).joined(separator: "<br>")
        return Self.marker + "<hr>" + lines + Self.cite + content + "</blockquote></div>"
    }

    /// Of a draft's HTML, what the owner wrote and the quote written by `htmlQuote`; nil when the
    /// draft has no quote. `parts` are the draft's attachments: the inline ones the quote shows go with it.
    static func split(draftHTML: String, parts: [Attachment]) -> (own: String, quote: QuotedOriginal)? {
        guard let start = draftHTML.range(of: marker) else { return nil }
        let quote = draftHTML[start.upperBound...]
        guard let cite = quote.range(of: cite) else { return nil }
        let headerHTML = quote[..<cite.lowerBound].replacingOccurrences(of: "<hr>", with: "")
        let after = quote[cite.upperBound...]
        let content = after.range(of: "</blockquote>", options: .backwards).map { after[..<$0.lowerBound] } ?? after
        let cleaned = QuoteCleaner.clean(String(content))
        let header = RichText.plain(fromHTML: headerHTML).split(separator: "\n").map(String.init)
        return (
            String(draftHTML[..<start.lowerBound]),
            QuotedOriginal(
                header: header, text: RichText.plain(fromHTML: cleaned), html: cleaned,
                inline: shown(by: cleaned, of: parts))
        )
    }

    /// The parts whose Content-ID, exactly (ignoring case), a picture attribute of the cleaned HTML
    /// (src, srcset, background, poster, lowsrc, dynsrc) shows as `cid:`, or a style shows
    /// (`QuoteAttributes.styleContentIDs`). A `cid:` in any other attribute (an alt text) shows
    /// nothing, so its part is not sent.
    static func shown(by html: String, of parts: [Attachment]) -> [Attachment] {
        // The cleaner writes every attribute again as ` name="value"`, names in lower case.
        let shown = Set(html.matches(of: #/ ([a-z0-9:_-]+)="([^"]*)"/#).flatMap { match -> [String] in
            let name = String(match.output.1)
            // A style shows the pictures the cleaner drops from it (a background).
            if name == "style" { return QuoteAttributes.styleContentIDs(match.output.2) }
            guard QuoteAttributes.pictures.contains(name) else { return [] }
            // A srcset names several, each before its descriptor.
            return match.output.2.split(separator: ",").compactMap { candidate in
                QuoteAttributes.contentID(of: candidate.split(whereSeparator: \.isWhitespace).first ?? candidate)
            }
        })
        return parts.filter { part in
            guard let id = part.contentID, !id.isEmpty else { return false }
            return shown.contains(id.lowercased())
        }
    }
}

/// The quoted original under the editor: folded to one line, opened to read it.
struct QuotedOriginalView: View {
    let quote: QuotedOriginal
    @State private var isOpen = false
    @ScaledMetric(relativeTo: .body) private var openHeight: CGFloat = 220

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            Button {
                withAnimation(.snappy) { isOpen.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isOpen ? Icons.unfolded : Icons.folded)
                        .font(.footnote.weight(.semibold))
                    Text(ui: isOpen ? "Hide the original" : "Show the original")
                        .font(.subheadline)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Theme.secondaryText)
                .padding(.horizontal, 20)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("compose.original")
            if isOpen {
                ScrollView {
                    Text(verbatim: String(quote.shown.prefix(200_000)))
                        .font(.callout)
                        .foregroundStyle(Theme.secondaryText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 12)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(Theme.separator).frame(width: 3)
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)
                }
                .frame(maxHeight: openHeight)
            }
        }
    }
}
