// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// Makes an original's HTML safe to quote in a reply or forward: the inner HTML of its body, without
/// anything that runs or fetches on its own (`script`, `iframe`, `object`, `embed`, `form`, `base`,
/// `meta`, `link`, styles and the head), without `on…` attributes, with addresses only of the kinds a
/// mail may hold (`QuoteAttributes`), and with every tag written again by us and closed where it was
/// opened, so the original never closes the quote it is put in. The HTML was written by anyone: it
/// is data, and it is read in one pass, bounded, with no recursion.
enum QuoteCleaner {
    /// The most of an original that is read, in characters.
    static let maxCharacters = 2_000_000
    /// The most elements open at once; a deeper one loses its tag (what it holds stays).
    static let maxDepth = 256
    /// Elements dropped with all they hold.
    static let droppedWithContent: Set<String> = [
        "script", "style", "head", "title", "iframe", "frameset", "object", "applet", "noscript",
        "template", "svg", "math", "noembed", "noframes"
    ]
    /// Tags dropped while what they hold stays (read on as HTML, so `plaintext`, `xmp` and `listing`
    /// never turn the rest of the message into their text).
    static let droppedTags: Set<String> = [
        "html", "body", "form", "base", "meta", "link", "input", "button", "select", "textarea", "option",
        "plaintext", "xmp", "listing", "embed", "frame", "image", "isindex", "animate", "set",
        "animatemotion", "animatetransform"
    ]
    /// Foreign elements a slash really closes (in HTML only these honour it among those dropped).
    static let selfClosingForeign: Set<String> = ["svg", "math"]
    /// Elements that hold nothing and are never closed.
    static let empty: Set<String> = [
        "br", "img", "hr", "wbr", "area", "col", "source", "track", "param", "keygen"
    ]

    /// The original's HTML, cleaned (see the type). An `<img>` showing `cid:` one of `dropped` (a
    /// Content-ID, exactly) goes too.
    static func clean(_ html: String, droppingPictures dropped: Set<String> = []) -> String {
        let dropped = Set(dropped.map { $0.lowercased() })
        let text = String(html.prefix(maxCharacters)).replacingOccurrences(of: "\u{0}", with: "")
        var rest = bodyContent(text)
        var out = ""
        var open: [String] = []
        // Every round takes at least one character, so this many always reach the end.
        for _ in 0...rest.count {
            guard let start = rest.firstIndex(of: "<") else {
                out += escapeText(rest)
                break
            }
            out += escapeText(rest[..<start])
            let after = rest[rest.index(after: start)...]
            if after.hasPrefix("!--") {
                rest = after.range(of: "-->").map { after[$0.upperBound...] } ?? ""
                continue
            }
            guard let first = after.first, first.isASCII, first.isLetter || first == "/" || first == "!" || first == "?"
            else {
                out += "&lt;"
                rest = after
                continue
            }
            // A tag that never closes takes what follows with it.
            guard let close = after.firstIndex(of: ">") else { break }
            let inside = after[..<close]
            rest = after[after.index(after: close)...]
            guard first != "!", first != "?", let tag = QuoteTag(inside) else { continue }
            take(tag, into: &out, rest: &rest, open: &open, dropped: dropped)
        }
        // What the original left open is closed here, inside the quote.
        out += open.reversed().map { "</\($0)>" }.joined()
        return out
    }

    /// Writes a tag again, or drops it (with what it holds, for `droppedWithContent`). A closing tag
    /// is written only for an element open here, closing those opened inside it too. A slash closes
    /// only a void element: a browser opens any other (`<b/>`), so it is opened here and closed later.
    private static func take(
        _ tag: QuoteTag, into out: inout String, rest: inout Substring, open: inout [String], dropped: Set<String>
    ) {
        if droppedTags.contains(tag.name) { return }
        if tag.isClosing {
            guard let index = open.lastIndex(of: tag.name) else { return }
            out += open[index...].reversed().map { "</\($0)>" }.joined()
            open.removeSubrange(index...)
        } else if droppedWithContent.contains(tag.name) {
            // A self-closed foreign element (`<svg/>`) holds nothing; any other runs to its end tag.
            if !(tag.closesItself && selfClosingForeign.contains(tag.name)) { rest = skipping(tag.name, in: rest) }
        } else if empty.contains(tag.name) {
            guard let shown = tag.without(dropped) else { return }
            out += shown.written(closingItself: true)
        } else if open.count < maxDepth {
            open.append(tag.name)
            out += (tag.without(dropped) ?? tag).written(closingItself: false)
        }
    }

    /// What is inside `<body>`, or the whole when there is none.
    private static func bodyContent(_ html: String) -> Substring {
        guard let start = html.range(of: "<body", options: .caseInsensitive),
            let open = html[start.upperBound...].firstIndex(of: ">")
        else { return html[...] }
        let inner = html[html.index(after: open)...]
        guard let end = inner.range(of: "</body", options: [.caseInsensitive, .backwards]) else { return inner }
        return inner[..<end.lowerBound]
    }

    /// What follows an element's closing tag; nothing when it never closes.
    private static func skipping(_ name: String, in text: Substring) -> Substring {
        guard let end = text.range(of: "</" + name, options: .caseInsensitive),
            let close = text[end.upperBound...].firstIndex(of: ">")
        else { return "" }
        return text[text.index(after: close)...]
    }

    private static func escapeText(_ text: Substring) -> String {
        text.replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// A tag as read: its name (lower-case), whether it closes an element, and the attributes kept.
struct QuoteTag {
    let name: String
    let isClosing: Bool
    let closesItself: Bool
    var attributes: [(name: String, value: String?)] = []

    init?(_ inside: Substring) {
        var text = inside
        isClosing = text.first == "/"
        if isClosing { text = text.dropFirst() }
        let name = text.prefix { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ":") }
        guard let first = name.first, first.isLetter, name.count <= 32 else { return nil }
        self.name = name.lowercased()
        closesItself = inside.last == "/"
        guard !isClosing else { return }
        attributes = Self.attributes(text.dropFirst(name.count))
    }

    /// The tag without the pictures `dropped` (Content-IDs, lower-case): nil for an `<img>` whose src
    /// is one of them; else a picture attribute showing one is emptied, a srcset loses that candidate,
    /// and a style showing one with `url(cid:…)` goes.
    func without(_ dropped: Set<String>) -> QuoteTag? {
        guard !dropped.isEmpty else { return self }
        let isDropped = { (value: Substring) in QuoteAttributes.contentID(of: value).map(dropped.contains) ?? false }
        var tag = self
        if name == "img", let source = attributes.first(where: { $0.name == "src" })?.value, isDropped(source[...]) {
            return nil
        }
        tag.attributes = attributes.compactMap { attribute in
            if attribute.name == "style", let value = attribute.value {
                // A style showing a dropped picture goes whole: its declarations are not taken apart.
                return QuoteAttributes.styleContentIDs(value[...]).contains(where: dropped.contains) ? nil : attribute
            }
            guard let value = attribute.value, QuoteAttributes.pictures.contains(attribute.name) else {
                return attribute
            }
            guard attribute.name == "srcset" else { return isDropped(value[...]) ? (attribute.name, "") : attribute }
            let candidates = value.split(separator: ",").filter { candidate in
                !isDropped(candidate.split(whereSeparator: \.isWhitespace).first ?? "")
            }
            return candidates.isEmpty ? nil : (attribute.name, candidates.joined(separator: ","))
        }
        return tag
    }

    func written(closingItself: Bool) -> String {
        var out = "<" + name
        for attribute in attributes {
            out += " " + attribute.name
            if let value = attribute.value {
                let escaped = value.replacingOccurrences(of: "\"", with: "&quot;")
                    .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
                out += "=\"" + escaped + "\""
            }
        }
        return out + (closingItself ? " />" : ">")
    }

    /// The attributes worth keeping, at most 64 read.
    private static func attributes(_ source: Substring) -> [(name: String, value: String?)] {
        var kept: [(name: String, value: String?)] = []
        var text = source
        for _ in 0..<64 {
            text = text.drop { $0.isWhitespace || $0 == "/" }
            guard !text.isEmpty else { break }
            let name = text.prefix { !$0.isWhitespace && $0 != "=" && $0 != "/" }
            text = text.dropFirst(name.count).drop { $0.isWhitespace }
            var value: Substring?
            if text.first == "=" {
                text = text.dropFirst().drop { $0.isWhitespace }
                if let quote = text.first, quote == "\"" || quote == "'" {
                    let quoted = text.dropFirst()
                    let end = quoted.firstIndex(of: quote) ?? quoted.endIndex
                    value = quoted[..<end]
                    text = end < quoted.endIndex ? quoted[quoted.index(after: end)...] : ""
                } else {
                    let bare = text.prefix { !$0.isWhitespace }
                    value = bare
                    text = text.dropFirst(bare.count)
                }
            }
            if let attribute = QuoteAttributes.kept(name, value) { kept.append(attribute) }
        }
        return kept
    }
}
