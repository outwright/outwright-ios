// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// A parameter of a content line: `NAME=v1,v2`.
public struct ContentParameter: Sendable, Equatable {
    /// Upper-cased.
    public var name: String
    public var values: [String]

    public init(name: String, values: [String]) {
        self.name = name
        self.values = values
    }
}

/// vCard's name for the shared parameter type.
public typealias VCardParameter = ContentParameter

/// What the line reader does with a line past the line cap.
enum Oversize {
    case refuse
    case drop
    case keep
}

/// A parsed `group.NAME;PARAM=v:value` line; the value is still bytes and still escaped.
struct ParsedLine {
    var group: String?
    /// Upper-cased.
    var name: String
    var parameters: [ContentParameter]
    var value: [UInt8]
}

/// The line syntax vCard (RFC 6350) and iCalendar (RFC 5545) share: folding, parameters,
/// text escapes. The input is hostile; nothing is indexed unchecked.
enum ContentLine {
    static let semicolon: UInt8 = 0x3B
    static let colon: UInt8 = 0x3A
    static let comma: UInt8 = 0x2C
    static let quote: UInt8 = 0x22
    static let equals: UInt8 = 0x3D

    struct TooLarge: Error {}

    // MARK: - Unfolding

    /// Splits on LF (dropping a CR before it) and joins continuation lines. A line longer than
    /// `limit` is handed to `oversize`.
    static func unfold(
        _ bytes: [UInt8], limit: Int, oversize: ([UInt8]) -> Oversize = { _ in .refuse }
    ) throws(TooLarge) -> [[UInt8]] {
        var lines: [[UInt8]] = []
        var current: [UInt8] = []
        func flush() throws(TooLarge) {
            defer { current.removeAll(keepingCapacity: true) }
            guard !current.isEmpty else { return }
            if current.count > limit {
                switch oversize(current) {
                case .refuse: throw TooLarge()
                case .drop: return
                case .keep: break
                }
            }
            lines.append(current)
        }
        var start = bytes.startIndex
        while start < bytes.endIndex {
            let end = bytes[start...].firstIndex(of: 0x0A) ?? bytes.endIndex
            var lineEnd = end
            if lineEnd > start, bytes[lineEnd - 1] == 0x0D { lineEnd -= 1 }
            if let first = bytes[start..<lineEnd].first, first == 0x20 || first == 0x09 {
                current.append(contentsOf: bytes[(start + 1)..<lineEnd])
            } else {
                try flush()
                current.append(contentsOf: bytes[start..<lineEnd])
            }
            start = end < bytes.endIndex ? end + 1 : end
        }
        try flush()
        return lines
    }

    // MARK: - Parsing

    static func isNameByte(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
            || byte == 0x2D || byte == 0x5F
    }

    private static func text(_ bytes: ArraySlice<UInt8>) -> String { decode(Array(bytes)) }

    /// `group.NAME;PARAM=v,v:value`; nil for a line that is not a property.
    static func parse(_ line: [UInt8], bareParametersAreTypes: Bool = true) -> ParsedLine? {
        var index = 0
        while index < line.count, line[index] != colon, line[index] != semicolon { index += 1 }
        var group: String?
        var nameBytes = line[0..<index]
        if let dot = nameBytes.lastIndex(of: 0x2E) {
            group = text(nameBytes[..<dot])
            nameBytes = nameBytes[(dot + 1)...]
        }
        let groupIsValid = group.map { !$0.isEmpty && $0.utf8.allSatisfy(isNameByte) } ?? true
        guard !nameBytes.isEmpty, nameBytes.allSatisfy(isNameByte), groupIsValid else { return nil }
        let name = text(nameBytes).uppercased()
        guard let parameters = parseParameters(line, &index, bareAsType: bareParametersAreTypes) else { return nil }
        guard index < line.count, line[index] == colon else { return nil }
        return ParsedLine(
            group: group, name: name, parameters: parameters, value: Array(line[(index + 1)...]))
    }

    /// Reads `;NAME=v,"v"` runs starting at `index`; nil when a quote is left open.
    private static func parseParameters(_ line: [UInt8], _ index: inout Int, bareAsType: Bool) -> [ContentParameter]? {
        var parameters: [ContentParameter] = []
        while index < line.count, line[index] == semicolon {
            index += 1
            let nameStart = index
            while index < line.count, line[index] != equals, line[index] != semicolon, line[index] != colon {
                index += 1
            }
            let paramName = text(line[nameStart..<index]).uppercased()
            guard index < line.count, line[index] == equals else {
                // vCard 2.1 style bare parameter: `TEL;CELL:` means TYPE=CELL.
                if !paramName.isEmpty {
                    parameters.append(
                        bareAsType
                            ? ContentParameter(name: "TYPE", values: [paramName])
                            : ContentParameter(name: paramName, values: []))
                }
                continue
            }
            index += 1
            var values: [String] = []
            repeat {
                guard let value = parseParameterValue(line, &index) else { return nil }
                values.append(caretDecode(value))
                if index < line.count, line[index] == comma {
                    index += 1
                    continue
                }
                break
            } while true
            if !paramName.isEmpty { parameters.append(ContentParameter(name: paramName, values: values)) }
        }
        return parameters
    }

    private static func parseParameterValue(_ line: [UInt8], _ index: inout Int) -> String? {
        let start: Int
        if index < line.count, line[index] == quote {
            index += 1
            start = index
            while index < line.count, line[index] != quote { index += 1 }
            guard index < line.count else { return nil }
            index += 1
            return text(line[start..<(index - 1)])
        }
        start = index
        while index < line.count, line[index] != comma, line[index] != semicolon, line[index] != colon {
            index += 1
        }
        return text(line[start..<index])
    }

    /// RFC 6868: `^n` newline, `^^` caret, `^'` double quote.
    static func caretDecode(_ text: String) -> String {
        guard text.unicodeScalars.contains("^") else { return text }
        var out = String.UnicodeScalarView()
        var iterator = text.unicodeScalars.makeIterator()
        while let scalar = iterator.next() {
            guard scalar == "^" else {
                out.append(scalar)
                continue
            }
            guard let next = iterator.next() else {
                out.append(scalar)
                break
            }
            switch next {
            case "n": out.append("\n")
            case "^": out.append("^")
            case "'": out.append("\"")
            default:
                out.append(scalar)
                out.append(next)
            }
        }
        return String(out)
    }

    /// UTF-8, else ISO-8859-1.
    static func decode(_ bytes: [UInt8]) -> String {
        String(bytes: bytes, encoding: .utf8) ?? latin1(bytes)
    }

    static func latin1(_ bytes: [UInt8]) -> String {
        String(String.UnicodeScalarView(bytes.map { Unicode.Scalar($0) }))
    }

    // MARK: - Text escapes

    static func unescape(_ text: String) -> String {
        guard text.unicodeScalars.contains("\\") else { return text }
        var out = String.UnicodeScalarView()
        var iterator = text.unicodeScalars.makeIterator()
        while let scalar = iterator.next() {
            guard scalar == "\\" else {
                out.append(scalar)
                continue
            }
            guard let next = iterator.next() else {
                out.append(scalar)
                break
            }
            switch next {
            case "n", "N": out.append("\n")
            case "\\", ",", ";", ":": out.append(next)
            default:
                out.append(scalar)
                out.append(next)
            }
        }
        return String(out)
    }

    /// Line breaks become LF, NUL is dropped.
    static func clean(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var previousWasCR = false
        for scalar in text.unicodeScalars {
            if scalar == "\r" {
                out.append("\n")
                previousWasCR = true
                continue
            }
            defer { previousWasCR = false }
            if scalar == "\0" || (scalar == "\n" && previousWasCR) { continue }
            out.append(scalar)
        }
        return String(out)
    }

    static func escape(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in clean(text).unicodeScalars {
            switch scalar {
            case "\\": out.append(contentsOf: "\\\\".unicodeScalars)
            case "\n": out.append(contentsOf: "\\n".unicodeScalars)
            case ",": out.append(contentsOf: "\\,".unicodeScalars)
            case ";": out.append(contentsOf: "\\;".unicodeScalars)
            default: out.append(scalar)
            }
        }
        return String(out)
    }

    // MARK: - Writing

    /// Appends `text` and CRLF, folded at 75 octets on character boundaries.
    static func appendLine(_ text: String, to out: inout [UInt8]) {
        var width = 0
        var limit = 75
        for scalar in text.unicodeScalars {
            let bytes = Array(String(scalar).utf8)
            if width + bytes.count > limit {
                out.append(contentsOf: [0x0D, 0x0A, 0x20])
                width = 0
                limit = 74
            }
            out.append(contentsOf: bytes)
            width += bytes.count
        }
        out.append(contentsOf: [0x0D, 0x0A])
    }

    /// Only name characters survive.
    static func token(_ text: String) -> String {
        String(text.unicodeScalars.filter {
            ($0.value >= 0x30 && $0.value <= 0x39) || ($0.value >= 0x41 && $0.value <= 0x5A)
                || ($0.value >= 0x61 && $0.value <= 0x7A) || $0 == "-" || $0 == "_"
        })
    }

    /// RFC 6868 caret escapes, and quotes when the value holds a delimiter.
    static func parameterValue(_ value: String) -> String {
        var out = ""
        for scalar in clean(value).unicodeScalars {
            switch scalar {
            case "^": out += "^^"
            case "\n": out += "^n"
            case "\"": out += "^'"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out.contains(where: { ";:,".contains($0) }) ? "\"" + out + "\"" : out
    }

    /// `;NAME=v,v` for each parameter that has a usable name and a value.
    static func parameterText(_ parameters: [ContentParameter], bareWhenEmpty: Bool = false) -> String {
        var text = ""
        for parameter in parameters {
            let name = token(parameter.name)
            guard !name.isEmpty else { continue }
            if parameter.values.isEmpty {
                if bareWhenEmpty { text += ";" + name }
                continue
            }
            text += ";" + name + "=" + parameter.values.map(parameterValue).joined(separator: ",")
        }
        return text
    }
}
