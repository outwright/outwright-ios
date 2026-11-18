// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightMIME
import SwiftUI

/// The formatting the composer offers (bold, italic, underline, links) as HTML and back.
/// Bold and italic are kept as `inlinePresentationIntent`, underline as `underlineStyle`.
enum RichText {
    /// HTML for a body with any formatting (bulleted and numbered lines as `<ul>` and `<ol>`); nil
    /// for plain text (sent as text alone) unless `always`.
    static func html(_ text: AttributedString, always: Bool = false) -> String? {
        let lines = lineRanges(text)
        let formatted = text.runs.contains { run in
            run.inlinePresentationIntent != nil || run.underlineStyle != nil || run.link != nil
        } || lines.contains { ListEditing.marker(of: String(text[$0].characters)) != nil }
        guard formatted || always else { return nil }
        var out = "<div>"
        var list: ListEditing.Kind?
        var afterLine = false
        for range in lines {
            let line = text[range]
            if let mark = ListEditing.marker(of: String(line.characters)) {
                if list != mark.kind {
                    out += list.map(closing) ?? ""
                    out += mark.kind == .bullet ? "<ul>" : mark.number == 1 ? "<ol>" : "<ol start=\"\(mark.number)\">"
                    list = mark.kind
                }
                let chars = line.characters
                let start =
                    chars.index(chars.startIndex, offsetBy: mark.length, limitedBy: chars.endIndex) ?? chars.endIndex
                out += "<li>" + inline(AttributedString(line[start...])) + "</li>"
                afterLine = false
            } else {
                if let open = list {
                    out += closing(open)
                    list = nil
                } else if afterLine {
                    out += "<br>"
                }
                out += inline(AttributedString(line))
                afterLine = true
            }
        }
        return out + (list.map(closing) ?? "") + "</div>"
    }

    private static func closing(_ kind: ListEditing.Kind) -> String {
        kind == .bullet ? "</ul>" : "</ol>"
    }

    /// The ranges of the text's lines, without their line breaks (at least one, maybe empty).
    private static func lineRanges(_ text: AttributedString) -> [Range<AttributedString.Index>] {
        var ranges: [Range<AttributedString.Index>] = []
        var start = text.startIndex
        var index = text.startIndex
        let chars = text.characters
        while index < chars.endIndex {
            if chars[index] == "\n" {
                ranges.append(start..<index)
                start = chars.index(after: index)
            }
            index = chars.index(after: index)
        }
        ranges.append(start..<text.endIndex)
        return ranges
    }

    /// One line's runs as HTML: bold, italic, underline and links.
    private static func inline(_ text: AttributedString) -> String {
        var out = ""
        for run in text.runs {
            // Repeated spaces would be collapsed by a reader; every second one is a no-break space.
            var piece = escape(String(text[run.range].characters)).replacingOccurrences(of: "  ", with: " &nbsp;")
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
        return out
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
        // After a list a line break is owed, given only when text follows.
        var owesBreak = false
        func add(_ piece: AttributedString) {
            guard !piece.characters.isEmpty else { return }
            if owesBreak { result += AttributedString("\n") }
            owesBreak = false
            result += piece
        }
        while !rest.isEmpty {
            guard let open = rest.firstIndex(of: "<") else {
                add(style.piece(rest))
                break
            }
            add(style.piece(rest[..<open]))
            guard let close = rest[open...].firstIndex(of: ">") else { break }
            switch style.apply(String(rest[rest.index(after: open)..<close])) {
            case .none:
                break
            case .lineBreak:
                result += AttributedString("\n")
                owesBreak = false
            case .item(let mark):
                if let last = result.characters.last, last != "\n" { result += AttributedString("\n") }
                owesBreak = false
                result += AttributedString(mark)
            case .listEnd:
                owesBreak = true
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
        /// The lists open, innermost last: numbered ones with their next number. At most 8 deep.
        var lists: [Int?] = []

        /// Takes a tag in, and says what it adds to the text.
        mutating func apply(_ raw: String) -> TagEffect {
            let tag = raw.lowercased()
            if tag.hasPrefix("a ") {
                link = Self.href(raw)
                return .none
            }
            if tag == "ul" || tag == "ol" || tag.hasPrefix("ol ") {
                guard lists.count < 8 else { return .none }
                lists.append(tag == "ul" ? nil : Self.start(tag))
                return .none
            }
            if tag == "/ul" || tag == "/ol" {
                return lists.popLast() == nil ? .none : .listEnd
            }
            if tag == "li" || tag.hasPrefix("li ") {
                guard let last = lists.indices.last else { return .item(ListEditing.bullet) }
                guard let number = lists[last] else { return .item(ListEditing.bullet) }
                lists[last] = number + 1
                return .item("\(number). ")
            }
            return plain(tag) ? .lineBreak : .none
        }

        /// The number an `<ol>` starts at.
        static func start(_ tag: String) -> Int {
            guard let found = tag.range(of: "start=\"") else { return 1 }
            let digits = tag[found.upperBound...].prefix { $0.isASCII && $0.isNumber }.prefix(3)
            return Int(digits) ?? 1
        }

        /// Takes a formatting tag in; true when it breaks the line.
        private mutating func plain(_ tag: String) -> Bool {
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

/// What a tag read back from a draft's HTML adds to the text.
private enum TagEffect {
    case none, lineBreak, item(String), listEnd
}
