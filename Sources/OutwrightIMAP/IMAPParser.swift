// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// One value of a server response: an atom (numbers, flags, NIL and section names such as
/// `BODY[TEXT]<0>` included), a string (quoted or literal) or a parenthesised list.
enum IMAPValue: Sendable, Equatable {
    case atom(String)
    case string(Data)
    case list([IMAPValue])

    var text: String? {
        switch self {
        case let .atom(atom): atom.uppercased() == "NIL" ? nil : atom
        case let .string(data): lossyText(data)
        case .list: nil
        }
    }

    var data: Data? {
        switch self {
        case let .atom(atom): atom.uppercased() == "NIL" ? nil : Data(atom.utf8)
        case let .string(data): data
        case .list: nil
        }
    }

    var number: UInt32? {
        guard case let .atom(atom) = self, atom.utf8.count <= 10 else {
            return nil
        }
        return UInt32(atom)
    }
}

enum StatusKind: Sendable, Equatable {
    // swiftlint:disable:next identifier_name
    case ok, no, bad, bye, preauth
}

/// One server response, literals included.
enum IMAPResponse: Sendable, Equatable {
    case continuation(String)
    /// A status; `tag` is nil for an untagged one. `code` is the text between brackets.
    case status(tag: String?, kind: StatusKind, code: String?, text: String)
    /// Untagged data: `* 3 EXISTS` has number 3; `* LIST ...` has none.
    case data(number: UInt32?, keyword: String, values: [IMAPValue])
}

/// Reads server responses (RFC 3501 §7, §9) with every size bounded.
enum IMAPParser {
    static let maxLiteral = 64 << 20
    static let maxDepth = 32

    /// The length of the literal a response line ends with (`{12}` or `{12+}`), nil when it
    /// ends with none. A literal larger than 64 MiB is a protocol violation.
    static func literalLength(atEndOf line: Data) throws(IMAPError) -> Int? {
        let bytes = Array(line)
        guard bytes.last == UInt8(ascii: "}"), let open = bytes.lastIndex(of: UInt8(ascii: "{")) else {
            return nil
        }
        var digits = bytes[(open + 1)..<(bytes.count - 1)]
        if digits.last == UInt8(ascii: "+") {
            digits = digits.dropLast()
        }
        guard !digits.isEmpty, digits.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }) else {
            return nil
        }
        guard digits.count <= 10, let length = Int(lossyText(digits)), length <= maxLiteral else {
            throw .protocolViolation
        }
        return length
    }

    /// Whether a response that starts with `line` may carry literals: data responses may, a
    /// status (OK, NO, BAD, BYE, PREAUTH) or a `+` may not, whatever its text ends with.
    static func allowsLiterals(firstLine line: Data) -> Bool {
        let words = line.split(separator: UInt8(ascii: " "), maxSplits: 2, omittingEmptySubsequences: false)
        guard let tag = words.first, tag != Data("+".utf8) else {
            return false
        }
        guard words.count > 1 else {
            return true
        }
        return statusKind(lossyText(words[1])) == nil
    }

    static func parse(_ data: Data) throws(IMAPError) -> IMAPResponse {
        var cursor = Cursor(bytes: Array(data))
        let tag = cursor.word()
        guard !tag.isEmpty else {
            throw .protocolViolation
        }
        if tag == "+" {
            cursor.skipSpace()
            return .continuation(cursor.rest())
        }
        guard cursor.skipSpace() else {
            throw .protocolViolation
        }
        let word = cursor.word()
        if let kind = statusKind(word) {
            return status(tag: tag == "*" ? nil : tag, kind: kind, cursor: &cursor)
        }
        guard tag == "*", !word.isEmpty else {
            throw .protocolViolation
        }
        if word.utf8.count <= 10, let number = UInt32(word) {
            guard cursor.skipSpace() else {
                throw .protocolViolation
            }
            let keyword = cursor.word().uppercased()
            guard !keyword.isEmpty else {
                throw .protocolViolation
            }
            return .data(number: number, keyword: keyword, values: try cursor.values(depth: 0))
        }
        return .data(number: nil, keyword: word.uppercased(), values: try cursor.values(depth: 0))
    }

    private static func statusKind(_ word: String) -> StatusKind? {
        switch word.uppercased() {
        case "OK": .ok
        case "NO": .no
        case "BAD": .bad
        case "BYE": .bye
        case "PREAUTH": .preauth
        default: nil
        }
    }

    private static func status(tag: String?, kind: StatusKind, cursor: inout Cursor) -> IMAPResponse {
        cursor.skipSpace()
        let code = cursor.bracketed()
        cursor.skipSpace()
        return .status(tag: tag, kind: kind, code: code, text: cursor.rest())
    }

    /// A folder from a `LIST` response, nil for anything else.
    static func folder(from response: IMAPResponse) -> IMAPFolder? {
        guard case let .data(nil, "LIST", values) = response, values.count == 3,
              case let .list(attributeValues) = values[0],
              let path = values[2].text, !path.isEmpty
        else {
            return nil
        }
        let attributes = Set(attributeValues.compactMap(\.text).map { $0.uppercased() })
        let delimiter = values[1].text.flatMap { $0.isEmpty ? nil : $0 }
        let parts = delimiter.map { path.components(separatedBy: $0) } ?? [path]
        let last = parts.last ?? path
        let name = ModifiedUTF7.decode(last) ?? last
        let selectable = !attributes.contains("\\NOSELECT") && !attributes.contains("\\NONEXISTENT")
        // A name tells the role only at the top or right under the Inbox, never deeper in a tree.
        let nameCounts = parts.count == 1 || (parts.count == 2 && parts.first?.uppercased() == "INBOX")
        let role = role(path: path, name: nameCounts ? name : nil, attributes: attributes)
        return IMAPFolder(path: path, name: name, role: role, selectable: selectable, delimiter: delimiter)
    }

    /// Longest namespace prefix taken.
    static let maxNamespacePrefix = 255

    /// The personal namespace of a `NAMESPACE` response (RFC 2342), nil for anything else. A prefix
    /// is taken only when a folder can be made under it: short, printable ASCII, no wildcards,
    /// with a one-character delimiter, and ended by it.
    static func namespace(from response: IMAPResponse) -> IMAPNamespace? {
        guard case let .data(nil, keyword, values) = response, keyword.uppercased() == "NAMESPACE",
              case let .list(personal)? = values.first, case let .list(first)? = personal.first,
              first.count >= 2, var prefix = first.first?.text
        else {
            return nil
        }
        let delimiter = first[1].text
        let plain: (String) -> Bool = { text in
            text.unicodeScalars.allSatisfy { (0x20...0x7E).contains($0.value) && $0 != "*" && $0 != "%" }
        }
        guard prefix.utf8.count <= maxNamespacePrefix, plain(prefix) else {
            return nil
        }
        if let delimiter {
            guard delimiter.unicodeScalars.count == 1, plain(delimiter) else {
                return nil
            }
            if !prefix.isEmpty, !prefix.hasSuffix(delimiter) {
                prefix += delimiter
            }
        }
        return IMAPNamespace(prefix: prefix, delimiter: delimiter)
    }

    private static let namedRoles: [String: FolderRole] = [
        "sent": .sent, "sent items": .sent, "sent messages": .sent, "skickat": .sent, "skickade": .sent,
        "drafts": .drafts, "utkast": .drafts,
        "trash": .trash, "deleted items": .trash, "deleted messages": .trash, "borttaget": .trash,
        "junk": .junk, "spam": .junk, "skräppost": .junk, "junk e-mail": .junk,
        "archive": .archive, "arkiv": .archive
    ]

    private static func role(path: String, name: String?, attributes: Set<String>) -> FolderRole {
        if path.uppercased() == "INBOX" {
            return .inbox
        }
        let special: [(String, FolderRole)] = [
            ("\\SENT", .sent), ("\\DRAFTS", .drafts), ("\\TRASH", .trash), ("\\JUNK", .junk), ("\\ARCHIVE", .archive)
        ]
        if let match = special.first(where: { attributes.contains($0.0) }) {
            return match.1
        }
        return name.flatMap { namedRoles[$0.lowercased()] } ?? .other
    }
}

/// Bytes from a server as text, any invalid UTF-8 replaced: a hostile answer never fails here.
func lossyText(_ bytes: some Collection<UInt8>) -> String {
    // swiftlint:disable:next optional_data_string_conversion
    String(decoding: bytes, as: UTF8.self)
}
