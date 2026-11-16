// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// Walks the parts of a message, filling in bodies and attachments within the limits.
struct PartWalker {
    let buf: [UInt8]
    let limits: MIMELimits
    var partCount = 1
    var text: String?
    var html: String?
    var attachments: [Attachment] = []
    /// The first calendar part within `limits.calendarPartBytes`.
    var calendar: CalendarPart?
    /// The plain text was cut at `limits.textBytes`.
    var textShortened = false

    /// Where each line that starts with `--` starts, in order: found once for the message, on the
    /// first multipart, so a nested one looks only at these instead of reading its parent's bytes
    /// again. (32 bits: a message is far smaller than 2 GiB.)
    var dashLines: [Int32]?

    init(buf: [UInt8], limits: MIMELimits) {
        self.buf = buf
        self.limits = limits
    }

    private static func dashLineStarts(_ buf: [UInt8]) -> [Int32] {
        var starts: [Int32] = []
        var lineStart = true
        for (index, byte) in buf.enumerated() {
            if lineStart, byte == 0x2D, index + 1 < buf.count, buf[index + 1] == 0x2D,
               let position = Int32(exactly: index) {
                starts.append(position)
            }
            lineStart = byte == 0x0A
        }
        return starts
    }

    /// Whether a message's own Content-Type is a calendar whose `method` makes it an invitation message.
    static func isInvitationType(_ type: StructuredHeader) -> Bool {
        type.value.lowercased() == "text/calendar"
            && CalendarPart.invitationMethods.contains(methodToken(type.params["method"] ?? ""))
    }

    /// The longest METHOD kept; iTIP's are a word.
    private static let maxMethod = 64

    /// A METHOD as a token: upper-cased letters, digits and `-` only, at most `maxMethod` of them.
    static func methodToken(_ value: String) -> String {
        let kept = value.trimmingCharacters(in: .whitespaces).uppercased().unicodeScalars.prefix(maxMethod)
            .filter { ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
        return String(String.UnicodeScalarView(kept))
    }

    /// The METHOD of a calendar part: the Content-Type's `method`, else the body's `METHOD:` line.
    static func calendarMethod(_ type: StructuredHeader, body: [UInt8]) -> String {
        if let parameter = type.params["method"], !methodToken(parameter).isEmpty { return methodToken(parameter) }
        let text = Charset.decode(Data(body), label: type.params["charset"])
        for line in text.split(whereSeparator: \.isNewline) where line.uppercased().hasPrefix("METHOD:") {
            return methodToken(String(line.dropFirst("METHOD:".count)))
        }
        return ""
    }

    /// `depth` counts the multipart containers around this part.
    mutating func walkBody(_ headers: Headers, body: Range<Int>, depth: Int) throws(MIMEError) {
        let type = StructuredHeader.parse(headers["content-type"] ?? "text/plain")
        let boundary = type.params["boundary"] ?? ""
        if type.value.lowercased().hasPrefix("multipart/"), !boundary.isEmpty {
            guard depth + 1 <= limits.depth else { throw .tooDeep }
            for child in try split(body, boundary: boundary) {
                partCount += 1
                guard partCount <= limits.parts else { throw .tooManyParts }
                let block = try HeaderBlock.parse(buf, start: child.lowerBound, end: child.upperBound,
                                                  limit: limits.headerBytes)
                let start = min(block.bodyStart, child.upperBound)
                try walkBody(Headers(block.fields), body: start..<child.upperBound, depth: depth + 1)
            }
        } else {
            leaf(headers, type: type, body: body)
        }
    }

    /// The byte ranges between the delimiter lines of a multipart body. Only the body's first line
    /// and the lines starting with `--` within it can be delimiters.
    mutating func split(_ body: Range<Int>, boundary: String) throws(MIMEError) -> [Range<Int>] {
        let delimiter = Array("--\(boundary)".utf8)
        let stop = min(body.upperBound, buf.count)
        let begin = max(body.lowerBound, 0)
        let lines = dashLines ?? Self.dashLineStarts(buf)
        dashLines = lines
        var ranges: [Range<Int>] = []
        var partStart: Int?
        let after = firstDashLine(after: begin, in: lines)
        let rest = lines[after...].lazy.map(Int.init).prefix { $0 < stop }
        for cursor in [begin] + rest where cursor < stop {
            let line = Lines.next(buf, from: cursor, end: stop)
            switch delimiterKind(at: cursor, lineEnd: line.contentEnd, delimiter: delimiter) {
            case .close:
                if let start = partStart { ranges.append(start..<trimmedEnd(before: cursor, floor: start)) }
                return ranges
            case .open:
                if let start = partStart { ranges.append(start..<trimmedEnd(before: cursor, floor: start)) }
                partStart = line.next
                if ranges.count >= limits.parts { throw .tooManyParts }
            case .none:
                break
            }
        }
        if let start = partStart { ranges.append(start..<max(stop, start)) }
        return ranges
    }

    /// The index in `lines` of the first line start after `position`.
    private func firstDashLine(after position: Int, in lines: [Int32]) -> Int {
        var low = 0
        var high = lines.count
        while low < high {
            let middle = low + (high - low) / 2
            if Int(lines[middle]) <= position { low = middle + 1 } else { high = middle }
        }
        return low
    }

    private enum DelimiterKind { case open, close, none }

    private func delimiterKind(at start: Int, lineEnd: Int, delimiter: [UInt8]) -> DelimiterKind {
        guard lineEnd - start >= delimiter.count, buf[start..<(start + delimiter.count)].elementsEqual(delimiter)
        else { return .none }
        var rest = buf[(start + delimiter.count)..<lineEnd]
        var isClose = false
        if rest.starts(with: [0x2D, 0x2D]) {
            isClose = true
            rest = rest.dropFirst(2)
        }
        guard rest.allSatisfy({ $0 == 0x20 || $0 == 0x09 }) else { return .none }
        return isClose ? .close : .open
    }

    /// The end of a part: the line break before its closing delimiter belongs to the delimiter.
    private func trimmedEnd(before delimiterStart: Int, floor: Int) -> Int {
        var end = delimiterStart
        if end > floor, buf[end - 1] == 0x0A { end -= 1 }
        if end > floor, buf[end - 1] == 0x0D { end -= 1 }
        return end
    }

    private mutating func leaf(_ headers: Headers, type: StructuredHeader, body: Range<Int>) {
        let mime = type.value.lowercased()
        let disposition = StructuredHeader.parse(headers["content-disposition"] ?? "")
        let range = body.clamped(to: buf.indices)
        let filename = Self.filename(disposition: disposition, type: type)
        let isAttachment = disposition.value.lowercased() == "attachment"
        let isTextBody = Self.isTextBody(mime: mime, disposition: disposition, type: type)
        var bytes = TransferEncoding.decode(Array(buf[range]), encoding: headers["content-transfer-encoding"])
        // The plain text is cut once decoded (whatever its transfer encoding), on a whole character
        // of its charset, before it is made into a string.
        if mime == "text/plain", isTextBody, text == nil, let limit = limits.textBytes, bytes.count > max(0, limit) {
            bytes = Self.wholeCharacters(Array(bytes.prefix(max(0, limit))), charset: type.params["charset"])
            textShortened = true
        }
        if isTextBody, let decoded = Self.decodeText(bytes, charset: type.params["charset"]) {
            if mime == "text/html", html == nil {
                html = decoded
                return
            }
            if mime == "text/plain", text == nil {
                text = decoded
                return
            }
        }
        // A calendar part too large is never read as one: it stays only an attachment.
        if mime == "text/calendar", calendar == nil, bytes.count <= limits.calendarPartBytes {
            calendar = CalendarPart(method: Self.calendarMethod(type, body: bytes), data: Data(bytes))
        }
        let contentID = headers["content-id"].map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t"))
        }.flatMap { $0.isEmpty ? nil : $0 }
        let isInline = !isAttachment && (disposition.value.lowercased() == "inline" || contentID != nil)
        attachments.append(Attachment(
            filename: filename ?? Self.defaultName(mime), mimeType: mime.isEmpty ? "application/octet-stream" : mime,
            contentID: contentID, isInline: isInline, data: Data(bytes)))
    }

    private static func defaultName(_ mime: String) -> String {
        switch mime {
        case "text/plain": "attachment.txt"
        case "text/html": "attachment.html"
        case "text/calendar": "invite.ics"
        case "message/rfc822": "message.eml"
        default: "attachment"
        }
    }

    /// Text of a body part with line breaks as \n and its closing line break removed.
    private static func decodeText(_ bytes: [UInt8], charset: String?) -> String? {
        var text = Charset.decode(Data(bytes), label: charset).replacingOccurrences(of: "\r\n", with: "\n")
        if text.hasSuffix("\n") { text.removeLast() }
        return text
    }

    /// Whether a text part is the message's own text: text/plain or text/html, not an attachment
    /// and without a file name (as the preview judges it too).
    static func isTextBody(mime: String, disposition: StructuredHeader, type: StructuredHeader) -> Bool {
        (mime == "text/plain" || mime == "text/html") && disposition.value.lowercased() != "attachment"
            && filename(disposition: disposition, type: type) == nil
    }

    /// `bytes` without an incomplete character at the end: by UTF-8's own rules for UTF-8 (or no
    /// label), else by dropping up to three bytes until the charset reads them.
    static func wholeCharacters(_ bytes: [UInt8], charset: String?) -> [UInt8] {
        guard let encoding = Charset.encoding(for: charset), encoding != .utf8 else {
            return PreviewPart.trimmingIncompleteUTF8(bytes)
        }
        for drop in 0...min(3, bytes.count) where String(data: Data(bytes.dropLast(drop)), encoding: encoding) != nil {
            return Array(bytes.dropLast(drop))
        }
        return bytes
    }

    private static func filename(disposition: StructuredHeader, type: StructuredHeader) -> String? {
        guard let raw = disposition.params["filename"] ?? type.params["name"] else { return nil }
        let decoded = EncodedWord.decode(raw)
        let name = decoded.split { $0 == "/" || $0 == "\\" }.last.map(String.init) ?? ""
        let clean = String(name.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F })
        return clean.isEmpty ? nil : clean
    }
}
