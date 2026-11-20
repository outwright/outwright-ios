// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// Pieces of the writer: header cleaning and folding, quoted-printable, base64, addresses and
/// parameters. No header line passes RFC 5322's 998 octets.
enum WriterSupport {
    /// RFC 5322's longest line, without its CRLF.
    static let maxLine = 998
    /// Longest word (or id) written as it is; a longer one cannot be folded within `maxLine`.
    static let maxWord = 900
    /// Where folding aims to end a line (RFC 5322's recommended 78).
    static let foldAt = 78
    /// Longest address SMTP takes (RFC 5321's path, less its brackets).
    static let maxAddress = 254

    /// Removes CR, LF and NUL, which could end a header or smuggle another; other controls become spaces.
    static func clean(_ value: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x0D, 0x0A, 0x00: continue
            case 0x01..<0x20 where scalar.value != 0x09, 0x7F: out.append(" ")
            default: out.append(scalar)
            }
        }
        return String(out)
    }

    static func isASCII(_ value: String) -> Bool { value.unicodeScalars.allSatisfy { $0.isASCII } }

    /// ASCII that reads as written: no encoded-word opener, and no word or run of spaces too long
    /// to fold.
    static func isPlain(_ text: String) -> Bool {
        isASCII(text) && !text.contains("=?") && longestSpaceRun(text) <= maxWord
            && !text.split(whereSeparator: { $0 == " " }).contains { $0.utf8.count > maxWord }
    }

    /// The longest run of spaces in `text`, which folding cannot break.
    static func longestSpaceRun(_ text: String) -> Int {
        var longest = 0
        var run = 0
        for byte in text.utf8 {
            run = byte == 0x20 ? run + 1 : 0
            longest = max(longest, run)
        }
        return longest
    }

    /// Header text that is either plain ASCII folded at its spaces, or encoded words a line each.
    /// `used` is how much of the first line the header's name takes.
    static func unstructured(_ value: String, used: Int = 9) -> String {
        let text = clean(value)
        if isPlain(text) { return foldAtSpaces(text, used: used) }
        return EncodedWord.encode(text).joined(separator: "\r\n ")
    }

    /// Breaks before a run of spaces wherever a line would pass `foldAt`, never where only spaces
    /// would follow, so no line is white space alone; unfolding gives `text` back.
    static func foldAtSpaces(_ text: String, used: Int) -> String {
        var out = ""
        var line = used
        var segment = ""
        var segmentHasWord = false
        func flush() {
            guard !segment.isEmpty else { return }
            if !out.isEmpty, segmentHasWord, segment.hasPrefix(" "), line + segment.utf8.count > foldAt {
                out += "\r\n"
                line = 0
            }
            out += segment
            line += segment.utf8.count
            segment = ""
            segmentHasWord = false
        }
        for character in text {
            // A segment is a run of spaces and the word after it.
            if character == " ", segmentHasWord { flush() }
            if character != " " { segmentHasWord = true }
            segment.append(character)
        }
        flush()
        return out
    }

    /// Room a display name leaves on its line for ` <address>` at its longest.
    static let addressRoom = maxAddress + 3

    static func displayName(_ name: String) -> String {
        let text = clean(name).trimmingCharacters(in: .whitespaces)
        let plainSet = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " !#$%&'*+-/=?^_`{|}~"))
        var written = text
        if !text.unicodeScalars.allSatisfy({ plainSet.contains($0) }) {
            let escaped = text.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            written = "\"\(escaped)\""
        }
        // As written, escapes and quotes counted, no run may leave too little room for the address.
        let longestRun = written.split(separator: " ").map(\.utf8.count).max() ?? 0
        guard isASCII(text), !text.contains("=?"), max(longestRun, longestSpaceRun(written)) <= maxWord - addressRoom
        else {
            return EncodedWord.encode(text).joined(separator: "\r\n ")
        }
        return foldAtSpaces(written, used: 6)
    }

    /// An address as written in a header and a path: an addr-spec without white space, brackets or
    /// commas outside its quoted local part, and its domain in A-labels (left as it is when it has
    /// no ASCII form; sending refuses it).
    static func address(_ email: String) -> String {
        let kept = MailAddress.addrSpec(clean(email), alsoDrop: ["<", ">", ","])
        return MailAddress.ascii(kept) ?? kept
    }

    /// `Name <address>`; empty for an address that is blank or longer than SMTP takes.
    static func mailbox(_ address: Address) -> String {
        let email = Self.address(address.email)
        guard !email.isEmpty, email.utf8.count <= maxAddress else { return "" }
        guard let name = address.name, !clean(name).trimmingCharacters(in: .whitespaces).isEmpty else { return email }
        let written = displayName(name)
        // The address goes on a line of its own when the name's last line has no room for it.
        let last = written.components(separatedBy: "\r\n").last ?? written
        let gap = last.utf8.count + email.utf8.count + 3 > foldAt ? "\r\n " : " "
        return "\(written)\(gap)<\(email)>"
    }

    /// "Name: item, item" folded at the commas so no line passes 78 columns where it can be helped.
    static func addressHeader(_ name: String, _ addresses: [Address]) -> String? {
        let items = addresses.map(mailbox).filter { !$0.isEmpty }
        guard !items.isEmpty else { return nil }
        return fold(name, items, separator: ",")
    }

    /// Items after "Name: ", a new line before any that would pass 78 columns. An item folded
    /// already (a long display name) leaves the line at its own last line.
    static func fold(_ name: String, _ items: [String], separator: String) -> String {
        var out = "\(name): "
        var lineLength = out.utf8.count
        for (position, item) in items.enumerated() {
            let lines = item.components(separatedBy: "\r\n")
            let first = lines.first ?? item
            if position > 0 {
                if lineLength + first.utf8.count + separator.utf8.count + 1 > foldAt - 2 {
                    out += "\(separator)\r\n "
                    lineLength = 1
                } else {
                    out += "\(separator) "
                    lineLength += separator.utf8.count + 1
                }
            }
            out += item
            if lines.count > 1, let last = lines.last {
                lineLength = last.utf8.count
            } else {
                lineLength += item.utf8.count
            }
        }
        return out
    }

    /// `<id>`; nil for an id that is empty or too long for a line of its own.
    static func messageID(_ value: String) -> String? {
        let id = String(clean(value).unicodeScalars.filter { !$0.properties.isWhitespace && $0 != "<" && $0 != ">" })
        guard !id.isEmpty, id.utf8.count <= maxWord else { return nil }
        return "<\(id)>"
    }

    static func token(_ value: String, fallback: String) -> String {
        let text = String(clean(value).unicodeScalars.filter {
            $0.isASCII && !$0.properties.isWhitespace && $0 != ";" && $0 != "\"" && $0 != "(" && $0 != ")"
        })
        // A media type is at most 127 characters, a slash and 127 more (RFC 6838 section 4.2).
        return text.contains("/") && text.utf8.count <= 255 ? text : fallback
    }

    /// `filename="..."` for ASCII names; otherwise a plain fallback beside RFC 2231's `filename*`,
    /// written in continuations (`filename*0*`, `filename*1*`, …) short enough for a line each.
    static func filenameParameters(_ filename: String) -> String {
        let name = String(String.UnicodeScalarView(clean(filename).unicodeScalars.prefix(120)))
        let fallback = String(name.unicodeScalars.map { scalar -> Character in
            scalar.isASCII && scalar != "\"" && scalar != "\\" ? Character(scalar) : "_"
        })
        guard !isASCII(name) else { return "filename=\"\(fallback)\"" }
        var pieces: [String] = []
        var piece = "UTF-8''"
        for unit in percentEncodedUnits(name) {
            if piece.utf8.count + unit.utf8.count > 60 {
                pieces.append(piece)
                piece = ""
            }
            piece += unit
        }
        pieces.append(piece)
        let continued = pieces.enumerated().map { "filename*\($0.offset)*=\($0.element)" }
        return (["filename=\"\(fallback)\""] + continued).joined(separator: ";\r\n ")
    }

    /// The text's bytes percent-encoded, one unit per byte (`a`, `%C3`), so a unit is never split.
    private static func percentEncodedUnits(_ text: String) -> [String] {
        let safe = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!#$&+-.^_`|~".utf8)
        return text.utf8.map { byte in
            safe.contains(byte) ? String(Unicode.Scalar(byte)) : "%" + hex(byte >> 4) + hex(byte & 0x0F)
        }
    }

    private static let hexDigits = Array("0123456789ABCDEF".utf8)

    private static func hexByte(_ value: UInt8) -> UInt8 { hexDigits[Int(value & 0x0F)] }

    private static func hex(_ value: UInt8) -> String { String(Unicode.Scalar(hexByte(value))) }

    /// Quoted-printable with CRLF hard breaks, lines of at most 76 characters. An `F` that starts a
    /// line `From ` is encoded (RFC 3156 §3), so a mail store that marks such lines can't break a
    /// signature.
    static func quotedPrintable(_ text: String) -> [UInt8] {
        let input = Array(text.utf8)
        var out: [UInt8] = []
        var lineLength = 0
        var idx = 0
        while idx < input.count {
            let byte = input[idx]
            let next = idx + 1 < input.count ? input[idx + 1] : nil
            idx += 1
            if byte == 0x0D, next == 0x0A { continue }
            if byte == 0x0D || byte == 0x0A {
                out += [0x0D, 0x0A]
                lineLength = 0
                continue
            }
            let atLineEnd = next == nil || next == 0x0D || next == 0x0A
            let fromLine = byte == 0x46 && lineLength == 0 && input[idx...].starts(with: Array("rom ".utf8))
            let printable = byte >= 0x21 && byte <= 0x7E && byte != 0x3D && !fromLine
            let literal = printable || ((byte == 0x20 || byte == 0x09) && !atLineEnd)
            let piece: [UInt8] = literal ? [byte] : [0x3D, hexByte(byte >> 4), hexByte(byte & 0x0F)]
            if lineLength + piece.count > 75 {
                out += [0x3D, 0x0D, 0x0A]
                lineLength = 0
            }
            out += piece
            lineLength += piece.count
        }
        return out
    }

    /// Base64 in lines of 76 characters, separated by CRLF.
    static func base64Lines(_ data: Data) -> [UInt8] {
        let encoded = Array(data.base64EncodedString().utf8)
        var out: [UInt8] = []
        out.reserveCapacity(encoded.count + encoded.count / 38 + 2)
        var start = 0
        while start < encoded.count {
            let end = min(start + 76, encoded.count)
            if start > 0 { out += [0x0D, 0x0A] }
            out += encoded[start..<end]
            start = end
        }
        return out
    }
}
