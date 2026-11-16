// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// A header such as Content-Type: a value and its parameters (RFC 2045, with RFC 2231 extensions).
struct StructuredHeader {
    var value: String
    var params: [String: String]

    static func parse(_ input: String) -> StructuredHeader {
        let segments = split(input)
        guard let head = segments.first else { return StructuredHeader(value: "", params: [:]) }
        var collector = ParamCollector()
        for segment in segments.dropFirst().prefix(128) { collector.add(segment) }
        return StructuredHeader(
            value: head.trimmingCharacters(in: .whitespacesAndNewlines), params: collector.resolve())
    }

    private static func split(_ input: String) -> [String] {
        var segments: [String] = []
        var current = ""
        var inQuote = false
        var escaped = false
        for char in input {
            if escaped {
                escaped = false
            } else if inQuote && char == "\\" {
                escaped = true
            } else if char == "\"" {
                inQuote.toggle()
            } else if char == ";" && !inQuote {
                segments.append(current)
                current = ""
                continue
            }
            current.append(char)
        }
        segments.append(current)
        return segments
    }
}

private struct ParamCollector {
    struct Piece {
        var index: Int
        var isExtended: Bool
        var text: String
    }

    var plain: [String: String] = [:]
    var pieces: [String: [Piece]] = [:]

    mutating func add(_ segment: String) {
        guard let equals = segment.firstIndex(of: "=") else { return }
        var key = String(segment[..<equals]).trimmingCharacters(in: .whitespaces).lowercased()
        let value = Self.unquote(String(segment[segment.index(after: equals)...]))
        var isExtended = false
        if key.hasSuffix("*") {
            isExtended = true
            key.removeLast()
        }
        if let star = key.lastIndex(of: "*"), let number = Int(key[key.index(after: star)...]),
           (0..<64).contains(number) {
            let base = String(key[..<star])
            pieces[base, default: []].append(Piece(index: number, isExtended: isExtended, text: value))
        } else if isExtended {
            pieces[key, default: []].append(Piece(index: 0, isExtended: true, text: value))
        } else if plain[key] == nil {
            plain[key] = value
        }
    }

    static func unquote(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("\"") else { return trimmed }
        var out = ""
        var escaped = false
        for char in trimmed.dropFirst() {
            if escaped {
                out.append(char)
                escaped = false
            } else if char == "\\" {
                escaped = true
            } else if char == "\"" {
                break
            } else {
                out.append(char)
            }
        }
        return out
    }

    func resolve() -> [String: String] {
        var result = plain
        for (name, list) in pieces {
            result[name] = Self.join(list.sorted { $0.index < $1.index })
        }
        return result
    }

    private static func join(_ list: [Piece]) -> String {
        var bytes: [UInt8] = []
        var label: String?
        for (position, piece) in list.enumerated() {
            guard piece.isExtended else {
                bytes += Array(piece.text.utf8)
                continue
            }
            var text = piece.text
            if position == 0 {
                let parts = text.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
                if parts.count == 3 {
                    label = String(parts[0])
                    text = String(parts[2])
                }
            }
            bytes += percentDecode(text)
        }
        return Charset.decode(Data(bytes), label: label)
    }

    private static func percentDecode(_ text: String) -> [UInt8] {
        let input = Array(text.utf8)
        var out: [UInt8] = []
        var idx = 0
        while idx < input.count {
            if input[idx] == 0x25, idx + 2 < input.count,
               let high = hex(input[idx + 1]), let low = hex(input[idx + 2]) {
                out.append(high << 4 | low)
                idx += 3
            } else {
                out.append(input[idx])
                idx += 1
            }
        }
        return out
    }

    private static func hex(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: byte - 0x30
        case 0x41...0x46: byte - 0x41 + 10
        case 0x61...0x66: byte - 0x61 + 10
        default: nil
        }
    }
}
