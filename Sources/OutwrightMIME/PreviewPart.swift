// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// The text part a preview is made from, found in a body that may be cut off anywhere.
struct PreviewPart {
    var bytes: [UInt8]
    var isHTML: Bool
    var charset: String?
    var encoding: String?

    static func find(in body: [UInt8], headers: Headers) -> PreviewPart? {
        var finder = Finder(walker: PartWalker(buf: body, limits: .default))
        finder.visit(headers, range: 0..<body.count, depth: 0)
        return finder.plain ?? finder.html
    }

    /// The text, with the transfer encoding undone and an incomplete final sequence left out.
    func decoded() -> String {
        var input = bytes
        let kind = encoding?.trimmingCharacters(in: .whitespaces).lowercased()
        if kind == "quoted-printable", let equals = input.lastIndex(of: 0x3D), input.count - equals <= 2 {
            input.removeSubrange(equals...)
        }
        var raw = TransferEncoding.decode(input, encoding: kind)
        let isUTF8 = charset == nil || Charset.encoding(for: charset) == .utf8
        if isUTF8 { raw = Self.trimmingIncompleteUTF8(raw) }
        return Charset.decode(Data(raw), label: charset)
    }

    static func trimmingIncompleteUTF8(_ input: [UInt8]) -> [UInt8] {
        for back in 1...max(1, min(3, input.count)) where back <= input.count {
            let start = input.count - back
            let lead = input[start]
            if lead < 0x80 { return input }
            if lead < 0xC0 { continue }
            let needed = lead >= 0xF0 ? 4 : (lead >= 0xE0 ? 3 : 2)
            return back < needed ? Array(input[..<start]) : input
        }
        return input
    }

    private struct Finder {
        var walker: PartWalker
        var plain: PreviewPart?
        var html: PreviewPart?
        var visited = 0

        mutating func visit(_ headers: Headers, range: Range<Int>, depth: Int) {
            guard depth <= 8, visited < 200, plain == nil else { return }
            visited += 1
            let type = StructuredHeader.parse(headers["content-type"] ?? "text/plain")
            let mime = type.value.lowercased()
            let boundary = type.params["boundary"] ?? ""
            if mime.hasPrefix("multipart/"), !boundary.isEmpty {
                guard let children = try? walker.split(range, boundary: boundary) else { return }
                for child in children {
                    guard let block = try? HeaderBlock.parse(walker.buf, start: child.lowerBound,
                                                             end: child.upperBound, limit: 1 << 16) else { continue }
                    let start = min(block.bodyStart, child.upperBound)
                    visit(Headers(block.fields), range: start..<child.upperBound, depth: depth + 1)
                }
            } else if PartWalker.isTextBody(
                mime: mime, disposition: StructuredHeader.parse(headers["content-disposition"] ?? ""), type: type) {
                // A text file attached (by disposition or by its name) is no part of what the message says.
                let slice = walker.buf[range.clamped(to: walker.buf.indices)]
                let part = PreviewPart(bytes: Array(slice), isHTML: mime == "text/html",
                                       charset: type.params["charset"], encoding: headers["content-transfer-encoding"])
                if part.isHTML { html = html ?? part } else { plain = part }
            }
        }
    }
}
