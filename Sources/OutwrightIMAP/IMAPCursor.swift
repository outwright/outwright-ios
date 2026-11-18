// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// A walk over the bytes of one response.
struct Cursor {
    let bytes: [UInt8]
    var position = 0

    private static let space = UInt8(ascii: " ")

    var atEnd: Bool { position >= bytes.count }

    var current: UInt8? { position < bytes.count ? bytes[position] : nil }

    @discardableResult
    mutating func skipSpace() -> Bool {
        var skipped = false
        while current == Self.space {
            position += 1
            skipped = true
        }
        return skipped
    }

    /// Bytes up to the next space.
    mutating func word() -> String {
        let begin = position
        while let byte = current, byte != Self.space {
            position += 1
        }
        return lossyText(bytes[begin..<position])
    }

    mutating func rest() -> String {
        let begin = min(position, bytes.count)
        position = bytes.count
        return lossyText(bytes[begin...])
    }

    /// `[...]` at the cursor, without its brackets.
    mutating func bracketed() -> String? {
        guard current == UInt8(ascii: "["), let close = bytes[position...].firstIndex(of: UInt8(ascii: "]")) else {
            return nil
        }
        let code = lossyText(bytes[(position + 1)..<close])
        position = close + 1
        return code
    }

    /// Values up to the end, or up to the `)` that closes the list at `depth`.
    mutating func values(depth: Int) throws(IMAPError) -> [IMAPValue] {
        guard depth <= IMAPParser.maxDepth else {
            throw .protocolViolation
        }
        var out: [IMAPValue] = []
        while true {
            skipSpace()
            guard let byte = current else {
                if depth > 0 {
                    throw .protocolViolation
                }
                return out
            }
            switch byte {
            case UInt8(ascii: ")"):
                guard depth > 0 else {
                    throw .protocolViolation
                }
                position += 1
                return out
            case UInt8(ascii: "("):
                position += 1
                out.append(.list(try nested(depth: depth + 1)))
            case UInt8(ascii: "\""):
                out.append(.string(try quoted()))
            case UInt8(ascii: "{"):
                out.append(.string(try literal()))
            default:
                out.append(.atom(try atom()))
            }
        }
    }

    /// The list whose `(` was just read. Deeper than the limit (a mail can nest its parts as deep
    /// as it likes) it is read past and kept empty, so the rest of the response still counts.
    private mutating func nested(depth: Int) throws(IMAPError) -> [IMAPValue] {
        guard depth <= IMAPParser.maxDepth else {
            try skipList()
            return []
        }
        return try values(depth: depth)
    }

    /// Past the rest of a list whose `(` was just read, nested lists included, without recursion.
    private mutating func skipList() throws(IMAPError) {
        var open = 1
        while open > 0 {
            skipSpace()
            guard let byte = current else {
                throw .protocolViolation
            }
            switch byte {
            case UInt8(ascii: "("):
                position += 1
                open += 1
            case UInt8(ascii: ")"):
                position += 1
                open -= 1
            case UInt8(ascii: "\""):
                _ = try quoted()
            case UInt8(ascii: "{"):
                _ = try literal()
            default:
                _ = try atom()
            }
        }
    }

    private mutating func quoted() throws(IMAPError) -> Data {
        position += 1
        var out: [UInt8] = []
        while let byte = current {
            position += 1
            switch byte {
            case UInt8(ascii: "\""):
                return Data(out)
            case UInt8(ascii: "\\"):
                guard let escaped = current else {
                    throw .protocolViolation
                }
                position += 1
                out.append(escaped)
            case UInt8(ascii: "\r"), UInt8(ascii: "\n"):
                throw .protocolViolation
            default:
                out.append(byte)
            }
        }
        throw .protocolViolation
    }

    private mutating func literal() throws(IMAPError) -> Data {
        guard let close = bytes[position...].firstIndex(of: UInt8(ascii: "}")) else {
            throw .protocolViolation
        }
        guard let length = try IMAPParser.literalLength(atEndOf: Data(bytes[position...close])) else {
            throw .protocolViolation
        }
        var begin = close + 1
        guard bytes[begin...].starts(with: [UInt8(ascii: "\r"), UInt8(ascii: "\n")]) else {
            throw .protocolViolation
        }
        begin += 2
        let (end, overflow) = begin.addingReportingOverflow(length)
        guard !overflow, end <= bytes.count else {
            throw .protocolViolation
        }
        position = end
        return Data(bytes[begin..<end])
    }

    private static func endsAtom(_ byte: UInt8) -> Bool {
        byte == space || byte == UInt8(ascii: "(") || byte == UInt8(ascii: ")") || byte == UInt8(ascii: "\"")
            || byte == UInt8(ascii: "{") || byte < 0x20 || byte == 0x7F
    }

    /// An atom; a `[...]` inside it (a section such as `BODY[HEADER.FIELDS (A B)]`) is kept
    /// whole, spaces and parentheses included.
    private mutating func atom() throws(IMAPError) -> String {
        let begin = position
        var brackets = 0
        while let byte = current {
            if brackets > 0 {
                if byte == UInt8(ascii: "[") {
                    brackets += 1
                } else if byte == UInt8(ascii: "]") {
                    brackets -= 1
                } else if byte == UInt8(ascii: "\r") || byte == UInt8(ascii: "\n") {
                    throw .protocolViolation
                }
                guard brackets <= IMAPParser.maxDepth else {
                    throw .protocolViolation
                }
                position += 1
                continue
            }
            if Self.endsAtom(byte) {
                break
            }
            if byte == UInt8(ascii: "[") {
                brackets += 1
            }
            position += 1
        }
        guard position > begin, brackets == 0 else {
            throw .protocolViolation
        }
        return lossyText(bytes[begin..<position])
    }
}
