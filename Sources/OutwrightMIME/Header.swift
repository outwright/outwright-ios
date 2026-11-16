// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

typealias RawHeader = (name: String, value: String)

enum Lines {
    /// The line starting at `start`: where its text ends (before CR LF) and where the next begins.
    static func next(_ buf: [UInt8], from start: Int, end: Int) -> (contentEnd: Int, next: Int) {
        let stop = min(end, buf.count)
        var idx = max(start, 0)
        let origin = idx
        while idx < stop {
            if buf[idx] == 0x0A {
                let hasCR = idx > origin && buf[idx - 1] == 0x0D
                return (hasCR ? idx - 1 : idx, idx + 1)
            }
            idx += 1
        }
        return (stop, stop)
    }

    static func text(_ bytes: ArraySlice<UInt8>) -> String {
        String(bytes: bytes, encoding: .utf8) ?? String(bytes: bytes, encoding: .isoLatin1) ?? ""
    }
}

/// The header fields of a message or part, with the first field of each name found by lowercase name.
struct Headers {
    let fields: [RawHeader]
    private let index: [String: String]

    init(_ fields: [RawHeader]) {
        self.fields = fields
        var index: [String: String] = [:]
        for field in fields where index[field.name.lowercased()] == nil {
            index[field.name.lowercased()] = field.value
        }
        self.index = index
    }

    subscript(name: String) -> String? { index[name] }
}

struct HeaderBlock {
    var fields: [RawHeader]
    var bodyStart: Int

    /// Reads header fields from `start` up to the first blank line (or `end`), unfolding them.
    static func parse(_ buf: [UInt8], start: Int, end: Int, limit: Int) throws(MIMEError) -> HeaderBlock {
        let stop = min(end, buf.count)
        let origin = max(start, 0)
        var cursor = origin
        var fields: [RawHeader] = []
        var current: [UInt8] = []
        var bodyStart = stop
        var headerEnd = stop
        while cursor < stop {
            if cursor - origin > limit { throw .tooLarge }
            let line = Lines.next(buf, from: cursor, end: stop)
            if line.contentEnd == cursor {
                bodyStart = line.next
                headerEnd = cursor
                break
            }
            let first = buf[cursor]
            if (first == 0x20 || first == 0x09) && !current.isEmpty {
                current.append(contentsOf: buf[cursor..<line.contentEnd])
            } else {
                flush(&current, into: &fields)
                current = Array(buf[cursor..<line.contentEnd])
            }
            cursor = line.next
        }
        flush(&current, into: &fields)
        if headerEnd - origin > limit { throw .tooLarge }
        return HeaderBlock(fields: fields, bodyStart: bodyStart)
    }

    private static func flush(_ bytes: inout [UInt8], into fields: inout [RawHeader]) {
        defer { bytes.removeAll(keepingCapacity: true) }
        guard let colon = bytes.firstIndex(of: 0x3A), colon > 0 else { return }
        let name = Lines.text(bytes[0..<colon]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let value = Lines.text(bytes[(colon + 1)...]).trimmingCharacters(in: .whitespaces)
        fields.append((name: name, value: value))
    }
}
