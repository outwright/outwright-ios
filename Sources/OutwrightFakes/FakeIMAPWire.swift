// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// Wire formats the fake writes and reads.
extension FakeIMAPServer {
    /// One command, its literals read in; `longest` is raised to its longest line (literals not counted).
    static func readCommand(_ connection: FakeConnection, longest: inout Int) async -> [UInt8]? {
        guard var line = await connection.readLine() else {
            return nil
        }
        var command: [UInt8] = []
        for _ in 0..<64 {
            longest = max(longest, line.count)
            command += line
            guard let (length, synchronizing) = literal(atEndOf: line) else {
                return command
            }
            if synchronizing {
                connection.send(Self.line("+ Ready for literal data"))
            }
            guard let bytes = await connection.read(exactly: length), let next = await connection.readLine() else {
                return nil
            }
            command += Array("\r\n".utf8) + bytes
            line = next
        }
        return nil
    }

    static func literal(atEndOf line: Data) -> (Int, Bool)? {
        guard line.last == UInt8(ascii: "}"), let open = line.lastIndex(of: UInt8(ascii: "{")) else {
            return nil
        }
        var digits = fakeText(line[(open + 1)...].dropLast())
        let plus = digits.hasSuffix("+")
        if plus {
            digits.removeLast()
        }
        guard let length = Int(digits), length >= 0, length <= 64 << 20 else {
            return nil
        }
        return (length, !plus)
    }

    static func line(_ text: String) -> Data {
        Data((text + "\r\n").utf8)
    }

    static func key(_ path: String) -> String {
        path.uppercased() == "INBOX" ? "INBOX" : path
    }

    static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func literal(_ name: String, _ data: Data) -> Data {
        Data("\(name) {\(data.count)}\r\n".utf8) + data
    }

    /// The header block (with its blank line) and the text after it.
    static func split(_ data: Data) -> (Data, Data) {
        let bytes = Array(data)
        for index in bytes.indices {
            if bytes[index...].starts(with: [13, 10, 13, 10]) {
                return (Data(bytes[..<(index + 4)]), Data(bytes[(index + 4)...]))
            }
            if bytes[index...].starts(with: [10, 10]) {
                return (Data(bytes[..<(index + 2)]), Data(bytes[(index + 2)...]))
            }
        }
        return (data, Data())
    }

    /// Messages a sequence set (`1:3,7`, `5:*`) names, with their sequence numbers.
    static func matching(_ set: String, in folder: Folder, byUID: Bool) -> [(Int, Stored)] {
        let highest = byUID ? (folder.messages.last?.uid ?? 0) : UInt32(folder.messages.count)
        let ranges: [ClosedRange<UInt32>] = set.split(separator: ",").compactMap { part in
            let ends = part.split(separator: ":").map { $0 == "*" ? highest : UInt32($0) }
            guard let first = ends.first ?? nil, let last = ends.last ?? nil else {
                return nil
            }
            return min(first, last)...max(first, last)
        }
        return folder.messages.enumerated().compactMap { position, message in
            let number = byUID ? message.uid : UInt32(position + 1)
            return ranges.contains { $0.contains(number) } ? (position + 1, message) : nil
        }
    }

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }

    static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    static func internalDate(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        func two(_ value: Int?) -> String {
            let text = String(value ?? 0)
            return text.count < 2 ? "0" + text : text
        }
        let month = months[max(0, min(11, (parts.month ?? 1) - 1))]
        let time = "\(two(parts.hour)):\(two(parts.minute)):\(two(parts.second))"
        return "\(two(parts.day))-\(month)-\(parts.year ?? 1970) \(time) +0000"
    }

    /// The start of a `6-Nov-2026` day in UTC.
    static func day(_ text: String) -> Date? {
        let parts = text.split(separator: "-")
        guard parts.count == 3, let day = Int(parts[0]), let year = Int(parts[2]),
              let month = months.firstIndex(where: { $0.lowercased() == parts[1].lowercased() })
        else {
            return nil
        }
        return calendar.date(from: DateComponents(year: year, month: month + 1, day: day))
    }
}

/// The fake's reading of a command line: atoms, strings and lists.
enum Token {
    case atom(String)
    case string(Data)
    case list([Token])

    var text: String? {
        switch self {
        case let .atom(atom): atom
        case let .string(data): fakeText(data)
        case .list: nil
        }
    }

    static func parse(_ bytes: [UInt8]) -> [Token]? {
        var reader = TokenReader(bytes: bytes)
        return reader.tokens(depth: 0)
    }
}

private struct TokenReader {
    let bytes: [UInt8]
    var position = 0

    mutating func tokens(depth: Int) -> [Token]? {
        guard depth < 16 else {
            return nil
        }
        var out: [Token] = []
        while position < bytes.count {
            switch bytes[position] {
            case UInt8(ascii: " "):
                position += 1
            case UInt8(ascii: ")"):
                position += 1
                return depth > 0 ? out : nil
            case UInt8(ascii: "("):
                position += 1
                guard let inner = tokens(depth: depth + 1) else {
                    return nil
                }
                out.append(.list(inner))
            case UInt8(ascii: "\""):
                out.append(.string(quoted()))
            case UInt8(ascii: "{"):
                guard let data = literal() else {
                    return nil
                }
                out.append(.string(data))
            default:
                out.append(.atom(atom()))
            }
        }
        return depth == 0 ? out : nil
    }

    private mutating func quoted() -> Data {
        position += 1
        var text: [UInt8] = []
        while position < bytes.count, bytes[position] != UInt8(ascii: "\"") {
            if bytes[position] == UInt8(ascii: "\\"), position + 1 < bytes.count {
                position += 1
            }
            text.append(bytes[position])
            position += 1
        }
        position += 1
        return Data(text)
    }

    private mutating func literal() -> Data? {
        guard let close = bytes[position...].firstIndex(of: UInt8(ascii: "}")),
              let length = Int(fakeText(bytes[(position + 1)..<close]).replacingOccurrences(of: "+", with: "")),
              length >= 0, close + 3 + length <= bytes.count
        else {
            return nil
        }
        let begin = close + 3
        position = begin + length
        return Data(bytes[begin..<position])
    }

    private mutating func atom() -> String {
        let begin = position
        var brackets = 0
        while position < bytes.count {
            let current = bytes[position]
            if current == UInt8(ascii: "[") { brackets += 1 }
            if current == UInt8(ascii: "]") { brackets -= 1 }
            let ends = current == UInt8(ascii: " ") || current == UInt8(ascii: "(") || current == UInt8(ascii: ")")
            if brackets == 0, ends {
                break
            }
            position += 1
        }
        return fakeText(bytes[begin..<position])
    }
}
