// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation

/// A one-line summary of the start of a body, for a message list. Lenient: it never throws.
public enum Preview {
    private static let sampleBytes = 256 << 10

    /// `data` is the start of the raw body as the server sends it (still transfer-encoded, possibly cut
    /// anywhere, possibly a multipart); `headers` is the message's header block.
    public static func text(fromPartial data: Data, headers: Data, maxCharacters: Int = 200) -> String {
        let limit = max(0, min(maxCharacters, 10_000))
        guard limit > 0 else { return "" }
        let head = Array(headers.prefix(sampleBytes))
        let fields = (try? HeaderBlock.parse(head, start: 0, end: head.count, limit: sampleBytes))?.fields ?? []
        guard let part = PreviewPart.find(in: Array(data.prefix(sampleBytes)), headers: Headers(fields)) else {
            return ""
        }
        var text = part.decoded()
        if part.isHTML { text = HTMLText.visible(text) }
        return squeezed(text, limit: limit)
    }

    /// The preview of a message already read (a decrypted one): its text, else its HTML's.
    public static func text(of message: MIMEMessage, maxCharacters: Int = 200) -> String {
        let limit = max(0, min(maxCharacters, 10_000))
        guard limit > 0 else { return "" }
        let sample = 1 << 16
        if let text = message.textBody { return squeezed(String(text.prefix(sample)), limit: limit) }
        guard let html = message.htmlBody else { return "" }
        return squeezed(HTMLText.visible(String(html.prefix(sample))), limit: limit)
    }

    private static func squeezed(_ text: String, limit: Int) -> String {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .filter { !$0.drop { $0 == " " || $0 == "\t" }.hasPrefix(">") }
        let squeezed = lines.joined(separator: " ").split { $0.isWhitespace }.joined(separator: " ")
        return String(squeezed.prefix(limit))
    }
}

/// The text of an HTML fragment: tags, scripts, styles, comments and quoted replies left out.
public enum HTMLText {
    private struct Tag {
        var name: String
        var isClosing: Bool
        var next: Int
    }

    static func visible(_ html: String) -> String {
        let scalars = Array(html.unicodeScalars)
        var out = String.UnicodeScalarView()
        var quoteDepth = 0
        var skipping: String?
        var idx = 0
        while idx < scalars.count {
            guard scalars[idx] == "<", let tag = readTag(scalars, at: idx) else {
                if skipping == nil, quoteDepth == 0 { out.append(scalars[idx]) }
                idx += 1
                continue
            }
            idx = tag.next
            if let name = skipping {
                if tag.isClosing && tag.name == name { skipping = nil }
                continue
            }
            switch (tag.name, tag.isClosing) {
            case ("script", false), ("style", false): skipping = tag.name
            case ("blockquote", false): quoteDepth += 1
            case ("blockquote", true): quoteDepth = max(0, quoteDepth - 1)
            default: break
            }
            out.append(" ")
        }
        return decodeEntities(String(out))
    }

    private static func readTag(_ scalars: [Unicode.Scalar], at start: Int) -> Tag? {
        guard let first = scalars.indices.contains(start + 1) ? scalars[start + 1] : nil else { return nil }
        if first == "!" {
            let end = commentEnd(scalars, from: start + 2)
            return Tag(name: "", isClosing: false, next: end)
        }
        let isClosing = first == "/"
        let nameStart = isClosing ? start + 2 : start + 1
        var idx = nameStart
        var name = ""
        while idx < scalars.count, isNameScalar(scalars[idx], first: idx == nameStart) {
            name.unicodeScalars.append(scalars[idx])
            idx += 1
        }
        guard !name.isEmpty else { return nil }
        while idx < scalars.count, scalars[idx] != ">" { idx += 1 }
        return Tag(name: name.lowercased(), isClosing: isClosing, next: min(idx + 1, scalars.count))
    }

    private static func isNameScalar(_ scalar: Unicode.Scalar, first: Bool) -> Bool {
        scalar.properties.isAlphabetic || (!first && scalar.properties.numericType != nil)
    }

    private static func commentEnd(_ scalars: [Unicode.Scalar], from start: Int) -> Int {
        var idx = start
        while idx < scalars.count {
            if scalars[idx] == ">" { return idx + 1 }
            idx += 1
        }
        return scalars.count
    }

    /// The named references mail commonly uses; any other is left as written.
    private static let named: [Substring: String] = [
        "nbsp": " ", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "amp": "&",
        "auml": "ä", "Auml": "Ä", "aring": "å", "Aring": "Å", "ouml": "ö", "Ouml": "Ö",
        "uuml": "ü", "Uuml": "Ü", "eacute": "é", "Eacute": "É", "egrave": "è", "aelig": "æ", "AElig": "Æ",
        "oslash": "ø", "Oslash": "Ø", "szlig": "ß", "ccedil": "ç", "ntilde": "ñ",
        "euro": "€", "pound": "£", "copy": "©", "reg": "®", "trade": "™", "deg": "°", "middot": "·",
        "hellip": "…", "ndash": "–", "mdash": "—", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”",
        "laquo": "«", "raquo": "»", "bull": "•", "shy": "", "zwnj": "", "zwj": ""
    ]
    /// The longest reference read, `&` and `;` excluded.
    private static let maxReference = 10

    /// Reads `&name;`, `&#123;` and `&#x1F;` in one pass, so `&amp;lt;` gives `&lt;`.
    private static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = ""
        out.reserveCapacity(text.utf8.count)
        var rest = text[...]
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            let after = rest.index(after: amp)
            let window = rest[after...].prefix(maxReference + 1)
            if let semi = window.firstIndex(of: ";"), let plain = reference(rest[after..<semi]) {
                out += plain
                rest = rest[rest.index(after: semi)...]
            } else {
                out += "&"
                rest = rest[after...]
            }
        }
        out += rest
        return out
    }

    /// The text of one reference's body (between `&` and `;`), or nil when it isn't one.
    private static func reference(_ body: Substring) -> String? {
        guard body.first == "#" else { return named[body] }
        var digits = body.dropFirst()
        var radix = 10
        if digits.first == "x" || digits.first == "X" {
            digits = digits.dropFirst()
            radix = 16
        }
        guard !digits.isEmpty, let value = UInt32(digits, radix: radix), value != 0,
              let scalar = Unicode.Scalar(value)
        else { return nil }
        return String(Character(scalar))
    }
}
