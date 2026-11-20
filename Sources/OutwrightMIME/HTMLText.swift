// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// What of a message's HTML is never text for a reader.
extension HTMLText {
    /// Elements whose content is not text: style sheets, scripts and the head (with its title).
    static let hidden = ["head", "style", "script"]

    /// The HTML without its `head`, `style` and `script` elements and their content (case does
    /// not matter; an element left open runs to the end). Bounded: at most 1,000 elements go. One
    /// pass over its bytes: lowercased once, ASCII only so every index fits the original, and
    /// each name's next opening found from where the last search left off.
    public static func removingHiddenElements(_ html: String) -> String {
        let bytes = Array(html.utf8)
        let low = bytes.map { $0 >= 0x41 && $0 <= 0x5A ? $0 + 0x20 : $0 }
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var position = 0
        var next: [String: Int?] = [:]
        for _ in 0..<1_000 {
            var open: (start: Int, name: String)?
            for name in hidden {
                var found: Int?
                if let cached = next[name], cached.map({ $0 >= position }) ?? true {
                    found = cached
                } else {
                    found = nextOpening(bytes, low, name, from: position)
                    next[name] = .some(found)
                }
                if let start = found, open.map({ start < $0.start }) ?? true { open = (start, name) }
            }
            guard let (start, name) = open else { break }
            out += bytes[position..<start]
            position = bytes.count
            if let close = find(low, Array("</\(name)".utf8), from: start),
               let end = bytes[close...].firstIndex(of: UInt8(ascii: ">")) {
                position = end + 1
            }
        }
        out += bytes[position...]
        // Cut only at ASCII `<` and after `>`, so the bytes are UTF-8 still.
        return String(bytes: out, encoding: .utf8) ?? ""
    }

    /// Where the first `<name` at or after `start` opens an element of that name: followed by
    /// `>`, `/`, ASCII white space or the end.
    private static func nextOpening(_ bytes: [UInt8], _ low: [UInt8], _ name: String, from start: Int) -> Int? {
        let pattern = Array("<\(name)".utf8)
        var from = start
        while let found = find(low, pattern, from: from) {
            let after = found + pattern.count
            guard after < bytes.count else { return found }
            if [0x3E, 0x2F, 0x20, 0x09, 0x0A, 0x0D, 0x0C].contains(bytes[after]) { return found }
            from = after
        }
        return nil
    }

    /// The first index at or after `start` where `pattern` begins in `bytes`.
    private static func find(_ bytes: [UInt8], _ pattern: [UInt8], from start: Int) -> Int? {
        guard let first = pattern.first, start >= 0 else { return nil }
        var index = start
        while index + pattern.count <= bytes.count {
            guard let candidate = bytes[index...].firstIndex(of: first) else { return nil }
            guard candidate + pattern.count <= bytes.count else { return nil }
            if bytes[candidate..<(candidate + pattern.count)].elementsEqual(pattern) { return candidate }
            index = candidate + 1
        }
        return nil
    }
}
