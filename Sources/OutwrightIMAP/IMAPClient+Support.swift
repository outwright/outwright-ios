// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// IDLE's two halves, and the pieces commands are built from.
extension IMAPClient {
    static func failure(_ kind: StatusKind, _ text: String, code: String? = nil) -> IMAPError {
        if kind == .bad {
            return .bad(text)
        }
        let name = code?.split(separator: " ").first?.uppercased()
        // In use (RFC 5530): another session holds it; worth asking again later.
        return name == "UNAVAILABLE" || name == "SERVERBUG" || name == "INUSE" ? .unavailable(text) : .no(text)
    }

    /// Throws for NO and BAD; a NO that says the folder is missing is `.folderMissing`.
    static func check(_ completion: Completion, folder: String) throws(IMAPError) {
        guard completion.kind != .ok else {
            return
        }
        let code = completion.code?.split(separator: " ").first?.uppercased()
        if completion.kind == .no, code == "TRYCREATE" || code == "NONEXISTENT" {
            throw .folderMissing(folder)
        }
        throw failure(completion.kind, completion.text, code: completion.code)
    }

    /// FETCH responses by message, the parts of one message merged.
    static func fetched(_ responses: [IMAPResponse]) -> [FetchItems] {
        var bySequence: [UInt32: FetchItems] = [:]
        var order: [UInt32] = []
        for case let .data(number?, "FETCH", values) in responses {
            let items = FetchItems(values)
            if bySequence[number] == nil {
                order.append(number)
                bySequence[number] = items
            } else {
                bySequence[number]?.merge(items)
            }
        }
        return order.compactMap { bySequence[$0] }
    }

    /// A response that says the selected folder changed; VANISHED is QRESYNC's EXPUNGE.
    static func isChange(_ response: IMAPResponse) -> Bool {
        switch response {
        case let .data(_?, keyword, _):
            ["EXISTS", "EXPUNGE", "FETCH", "RECENT"].contains(keyword)
        case .data(nil, "VANISHED", _):
            true
        default:
            false
        }
    }

    /// A flag: `\` and an atom, or a keyword atom.
    static func isFlag(_ flag: String) -> Bool {
        let body = flag.hasPrefix("\\") ? flag.dropFirst() : Substring(flag)
        let special = Set("(){ %*\"\\]".unicodeScalars)
        return !body.isEmpty && body.utf8.count <= 100 && body.unicodeScalars.allSatisfy { scalar in
            scalar.value > 0x20 && scalar.value < 0x7F && !special.contains(scalar)
        }
    }

    static func stripped(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { $0 != "\r" && $0 != "\n" && $0 != "\0" }))
    }

    static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func chunks(_ uids: [UInt32], size: Int) -> [[UInt32]] {
        let unique = Array(Set(uids)).sorted()
        return stride(from: 0, to: unique.count, by: size).map { Array(unique[$0..<min($0 + size, unique.count)]) }
    }

    /// `1:3,7` for 1, 2, 3 and 7. `uids` sorted.
    static func set(_ uids: [UInt32]) -> String {
        var ranges: [String] = []
        var index = 0
        while index < uids.count {
            let first = uids[index]
            var last = first
            while index + 1 < uids.count, uids[index + 1] == last &+ 1 {
                index += 1
                last = uids[index]
            }
            ranges.append(first == last ? String(first) : "\(first):\(last)")
            index += 1
        }
        return ranges.joined(separator: ",")
    }
}

extension String {
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: "0", count: width - count) + self
    }
}
