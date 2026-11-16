// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightMIME
import SwiftUI

/// The formatting the composer offers (bold, italic, underline, links) as HTML and back.
/// Bold and italic are kept as `inlinePresentationIntent`, underline as `underlineStyle`.
enum RichText {
    /// HTML for a body with any formatting; nil for plain text (sent as text alone).
    static func html(_ text: AttributedString) -> String? {
        let formatted = text.runs.contains { run in
            run.inlinePresentationIntent != nil || run.underlineStyle != nil || run.link != nil
        }
        guard formatted else { return nil }
        var out = "<div>"
        for run in text.runs {
            // Repeated spaces would be collapsed by a reader; every second one is a no-break space.
            var piece = escape(String(text[run.range].characters))
                .replacingOccurrences(of: "  ", with: " &nbsp;")
                .replacingOccurrences(of: "\n", with: "<br>")
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.stronglyEmphasized) { piece = "<b>\(piece)</b>" }
                if intent.contains(.emphasized) { piece = "<i>\(piece)</i>" }
            }
            if run.underlineStyle != nil { piece = "<u>\(piece)</u>" }
            if let link = run.link, ["http", "https", "mailto"].contains(link.scheme?.lowercased() ?? "") {
                piece = "<a href=\"\(escape(link.absoluteString))\">\(piece)</a>"
            }
            out += piece
        }
        return out + "</div>"
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Text of HTML: tags dropped, line breaks kept, the common entities read. Bounded.
    static func plain(fromHTML html: String) -> String {
        var out = ""
        var tag = ""
        var inTag = false
        for char in HTMLText.removingHiddenElements(String(html.prefix(1_000_000))) {
            if inTag {
                if char == ">" {
                    inTag = false
                    let name = tag.lowercased().split(whereSeparator: { $0 == " " || $0 == "/" }).first ?? ""
                    if ["br", "p", "div", "tr", "li", "h1", "h2", "h3"].contains(String(name)) { out.append("\n") }
                    tag = ""
                } else if tag.count < 64 {
                    tag.append(char)
                }
            } else if char == "<" {
                inTag = true
            } else {
                out.append(char)
            }
        }
        return out.replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// A draft's HTML back as text with its bold, italic and underline (what `html` wrote).
    static func attributed(fromHTML html: String) -> AttributedString {
        var result = AttributedString()
        var style = Style()
        var rest = Substring(html.prefix(1_000_000))
        while !rest.isEmpty {
            guard let open = rest.firstIndex(of: "<") else {
                result += style.piece(rest)
                break
            }
            result += style.piece(rest[..<open])
            guard let close = rest[open...].firstIndex(of: ">") else { break }
            if style.apply(String(rest[rest.index(after: open)..<close])) {
                result += AttributedString("\n")
            }
            rest = rest[rest.index(after: close)...]
        }
        // The outer <div> adds a closing line break the draft did not have.
        if result.characters.last == "\n" {
            result.removeSubrange(result.index(beforeCharacter: result.endIndex)..<result.endIndex)
        }
        return result
    }

    /// How deep in bold, italic and underline the reading is.
    private struct Style {
        var bold = 0
        var italic = 0
        var underline = 0
        var link: URL?

        /// Takes a tag in; true when it breaks the line.
        mutating func apply(_ raw: String) -> Bool {
            let tag = raw.lowercased()
            if tag.hasPrefix("a ") {
                link = Self.href(raw)
                return false
            }
            switch tag {
            case "b", "strong": bold += 1
            case "/b", "/strong": bold = max(0, bold - 1)
            case "i", "em": italic += 1
            case "/i", "/em": italic = max(0, italic - 1)
            case "/a": link = nil
            case "u": underline += 1
            case "/u": underline = max(0, underline - 1)
            case "br", "br/", "br /", "/p", "/div": return true
            default: break
            }
            return false
        }

        func piece(_ text: Substring) -> AttributedString {
            var piece = AttributedString(RichText.plain(fromHTML: String(text)))
            var intent: InlinePresentationIntent = []
            if bold > 0 { intent.insert(.stronglyEmphasized) }
            if italic > 0 { intent.insert(.emphasized) }
            if !intent.isEmpty { piece.inlinePresentationIntent = intent }
            if underline > 0 { piece.underlineStyle = .single }
            if let link { piece.link = link }
            return piece
        }

        /// The `href` of an `<a>` tag, when it is http, https or mailto.
        static func href(_ tag: String) -> URL? {
            guard let start = tag.range(of: "href=\"", options: .caseInsensitive) else { return nil }
            let rest = tag[start.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { return nil }
            let value = RichText.plain(fromHTML: String(rest[..<end]))
            guard let url = URL(string: value), ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "")
            else { return nil }
            return url
        }
    }
}
