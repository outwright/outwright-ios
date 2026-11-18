// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// Which attributes of a quoted original are kept. A value is judged as a browser reads it: its
/// character references decoded the HTML5 way (any number of digits, the semicolon optional),
/// whitespace and control characters gone. An address may only be web, mail, `cid:`, a picture in
/// `data:image/`, or relative; anything else (`javascript:`, `vbscript:`, …) loses its attribute.
enum QuoteAttributes {
    /// The longest value read; a longer one is dropped rather than judged in part.
    static let maxValue = 4_096
    /// Attributes dropped whatever their value.
    static let dropped: Set<String> = ["srcdoc", "formaction", "action", "xmlns"]
    /// Attributes that hold an address.
    static let addresses: Set<String> = [
        "href", "src", "background", "poster", "cite", "data", "xlink:href", "longdesc", "lowsrc",
        "dynsrc", "usemap", "codebase", "manifest", "icon", "ping"
    ]
    static let schemes: Set<String> = ["http", "https", "mailto", "cid"]
    /// Attributes that show a picture, where `data:image/` may be one (never SVG, which can run).
    static let pictures: Set<String> = ["src", "srcset", "background", "poster", "lowsrc", "dynsrc"]

    /// The attribute as it is written again, or nil when it goes.
    static func kept(_ rawName: Substring, _ value: Substring?) -> (name: String, value: String?)? {
        let name = rawName.lowercased()
        guard !name.isEmpty, name.count <= 64,
            name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ":") }),
            !name.hasPrefix("on"), !dropped.contains(name)
        else { return nil }
        guard let value else { return (name, nil) }
        guard value.count <= maxValue else { return nil }
        let read = decoded(value)
        let squeezed = squeeze(read)
        let picture = pictures.contains(name)
        if addresses.contains(name) {
            guard isAllowed(squeezed, picture: picture) else { return nil }
        } else if name == "srcset" {
            // Each candidate whole, its descriptor with it: whitespace inside can't hide a scheme.
            let candidates = read.split(separator: ",").map { squeeze(String($0)) }
            guard candidates.allSatisfy({ isAllowed($0, picture: true) }) else { return nil }
        } else {
            // A style is read as CSS reads it too: `java\73 cript:` is `javascript:`.
            let text = name == "style" ? squeeze(cssDecoded(read)) : squeezed
            let banned = ["javascript:", "vbscript:", "livescript:", "expression(", "behavior:", "-moz-binding"]
            if banned.contains(where: text.contains) { return nil }
        }
        return (name, String(value))
    }

    /// Lower-case, without whitespace and control characters, as a browser reads an address.
    private static func squeeze(_ text: String) -> String {
        String(text.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0)
        }).lowercased()
    }

    /// Web, mail, `cid:`, relative (no scheme before a `/`, `?` or `#`), or, where a `picture` goes,
    /// a `data:image/` that isn't SVG.
    static func isAllowed(_ address: String, picture: Bool) -> Bool {
        let head = address.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        guard let colon = head.firstIndex(of: ":") else { return true }
        let scheme = String(head[..<colon])
        if scheme == "data" {
            return picture && address.hasPrefix("data:image/") && !address.hasPrefix("data:image/svg")
        }
        return schemes.contains(scheme)
    }

    /// The Content-ID an address names, as a browser reads it: references read, whitespace around
    /// it gone, `cid:` and percent escapes read (RFC 2392), lower-case; nil when it is no `cid:` or
    /// an escape is broken.
    static func contentID(of value: Substring) -> String? {
        let address = decoded(value).trimmingCharacters(in: .whitespacesAndNewlines)
        guard address.lowercased().hasPrefix("cid:") else { return nil }
        var bytes: [UInt8] = []
        var rest = address.utf8.dropFirst(4).prefix(maxValue)
        while let byte = rest.first {
            rest = rest.dropFirst()
            guard byte == UInt8(ascii: "%") else {
                bytes.append(byte)
                continue
            }
            let hex = rest.prefix(2)
            // Two hex digits exactly: `UInt8(_:radix:)` alone would take a sign (`%+1`).
            guard hex.count == 2, let digits = String(bytes: hex, encoding: .ascii),
                digits.allSatisfy(\.isHexDigit), let number = UInt8(digits, radix: 16)
            else {
                return nil
            }
            bytes.append(number)
            rest = rest.dropFirst(2)
        }
        return String(validating: bytes, as: UTF8.self)?.lowercased()
    }

    /// The Content-IDs a style shows, with `url(cid:…)` or as a bare string in an `image-set(…)` or
    /// `-webkit-image-set(…)`, read as CSS reads it (escapes, quotes and whitespace), at most 64.
    static func styleContentIDs(_ value: Substring) -> [String] {
        let css = cssDecoded(decoded(value))
        return Array((urlContentIDs(css) + imageSetContentIDs(css)).prefix(64))
    }

    /// The Content-IDs of a style's `url(…)`s, at most 64.
    private static func urlContentIDs(_ css: String) -> [String] {
        var found: [String] = []
        var rest = css[...]
        for _ in 0..<64 {
            guard let open = rest.range(of: "url(", options: .caseInsensitive) else { break }
            let after = rest[open.upperBound...]
            let end = after.firstIndex(of: ")") ?? after.endIndex
            let inside = after[..<end].trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(["\"", "'"]))
            if let id = contentID(of: inside[...]) { found.append(id) }
            rest = after[end...]
        }
        return found
    }

    /// The Content-IDs `image-set(…)`s and `-webkit-image-set(…)`s name as bare strings, at most 64.
    private static func imageSetContentIDs(_ css: String) -> [String] {
        var found: [String] = []
        var rest = css[...]
        for _ in 0..<64 {
            guard let open = rest.range(of: "image-set(", options: .caseInsensitive) else { break }
            let set = bareStrings(in: rest[open.upperBound...])
            found += set.strings.compactMap { contentID(of: $0) }
            rest = rest[set.end...]
        }
        return Array(found.prefix(64))
    }

    /// The bare strings of the set that starts `text` (just after its `(`), and where the set ends.
    /// Each candidate is a string or a function (its `url(…)` is read by `urlContentIDs`), then its
    /// descriptors, up to a comma; the set ends at its own `)`. Each step moves forward.
    private static func bareStrings(in text: Substring) -> (strings: [Substring], end: Substring.Index) {
        var strings: [Substring] = []
        var index = text.startIndex
        var depth = 0
        var atCandidate = true
        while index < text.endIndex {
            let character = text[index]
            if atCandidate, character == "\"" || character == "'" {
                let body = text[text.index(after: index)...]
                let close = body.firstIndex(of: character) ?? body.endIndex
                strings.append(body[..<close])
                atCandidate = false
                index = close < text.endIndex ? text.index(after: close) : close
                continue
            }
            if character == ")" {
                if depth == 0 { break }
                depth -= 1
            } else if character == "(" {
                depth += 1
            }
            atCandidate = character == "," && depth == 0 || atCandidate && character.isWhitespace
            index = text.index(after: index)
        }
        return (strings, index)
    }

    /// CSS text with its escapes read: a backslash and 1 to 6 hex digits (and one whitespace after)
    /// is that character; a backslash and any other character is that character. Bounded by the text.
    static func cssDecoded(_ text: String) -> String {
        var out = ""
        var rest = text[...]
        for _ in 0...rest.count {
            guard let slash = rest.firstIndex(of: "\\") else {
                out += rest
                break
            }
            out += rest[..<slash]
            let after = rest[rest.index(after: slash)...]
            let hex = after.prefix(6).prefix { $0.isHexDigit }
            if !hex.isEmpty {
                let scalar = UInt32(hex, radix: 16).flatMap { $0 == 0 ? nil : Unicode.Scalar($0) } ?? "\u{FFFD}"
                out.unicodeScalars.append(scalar)
                var next = after.dropFirst(hex.count)
                if next.first?.isWhitespace == true { next = next.dropFirst() }
                rest = next
            } else if let character = after.first {
                if !character.isNewline { out.append(character) }
                rest = after.dropFirst()
            } else {
                break
            }
        }
        return out
    }

    /// A value with its character references read: `&#106;`, `&#106`, `&#x6A`, `&#0000106;`,
    /// `&colon;`. A number past Unicode, or a surrogate, reads as U+FFFD. Bounded by the value.
    static func decoded(_ value: Substring) -> String {
        var out = ""
        var rest = value
        for _ in 0...rest.count {
            guard let amp = rest.firstIndex(of: "&") else {
                out += rest
                break
            }
            out += rest[..<amp]
            let after = rest[rest.index(after: amp)...]
            if let (scalar, remaining) = reference(after) {
                out.unicodeScalars.append(scalar)
                rest = remaining
            } else {
                out += "&"
                rest = after
            }
        }
        return out
    }

    /// The reference at the start of `text` (just after `&`) and what follows it.
    private static func reference(_ text: Substring) -> (Unicode.Scalar, Substring)? {
        if text.first == "#" {
            var digits = text.dropFirst()
            let isHex = digits.first == "x" || digits.first == "X"
            if isHex { digits = digits.dropFirst() }
            let number = digits.prefix { isHex ? $0.isHexDigit : ($0.isASCII && $0.isNumber) }
            guard !number.isEmpty else { return nil }
            var after = digits.dropFirst(number.count)
            if after.first == ";" { after = after.dropFirst() }
            // Leading zeros count for nothing; past Unicode is clamped to U+FFFD.
            let significant = number.drop { $0 == "0" }
            let value = significant.count > 8 ? nil : UInt32(significant, radix: isHex ? 16 : 10)
            let scalar = value.flatMap { $0 == 0 ? nil : Unicode.Scalar($0) } ?? "\u{FFFD}"
            return (scalar, after)
        }
        let named: [(String, Unicode.Scalar)] = [
            ("colon", ":"), ("tab", "\t"), ("newline", "\n"), ("nbsp", " "), ("lpar", "("), ("rpar", ")"),
            ("sol", "/"), ("period", "."), ("amp", "&"), ("quot", "\""), ("lt", "<"), ("gt", ">"), ("apos", "'")
        ]
        let word = text.prefix(8).prefix { $0.isASCII && $0.isLetter }.lowercased()
        guard let (name, scalar) = named.first(where: { word.hasPrefix($0.0) }) else { return nil }
        var after = text.dropFirst(name.count)
        if after.first == ";" { after = after.dropFirst() }
        return (scalar, after)
    }
}
