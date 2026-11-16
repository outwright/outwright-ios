// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation

/// Reads Internet messages. Everything read is hostile: bounded by `MIMELimits`, never trapping.
public enum MIMEParser {
    public static func parse(_ data: Data, limits: MIMELimits = .default) throws(MIMEError) -> MIMEMessage {
        try read(data, limits: limits, headersOnly: false)
    }

    /// Reads the header fields only; the bodies and attachments stay empty.
    public static func parseHeaders(_ data: Data, limits: MIMELimits = .default) throws(MIMEError) -> MIMEMessage {
        try read(data, limits: limits, headersOnly: true)
    }

    private static func read(_ data: Data, limits: MIMELimits, headersOnly: Bool) throws(MIMEError) -> MIMEMessage {
        guard !data.isEmpty else { throw .notAMessage }
        guard data.count <= limits.messageBytes else { throw .tooLarge }
        let buf = [UInt8](data)
        let block = try HeaderBlock.parse(buf, start: 0, end: buf.count, limit: limits.headerBytes)
        guard !block.fields.isEmpty else { throw .notAMessage }
        let headers = Headers(block.fields)
        var message = MessageHeaders.read(headers)
        message.rawHeaders = block.fields
        if headersOnly {
            let type = StructuredHeader.parse(headers["content-type"] ?? "")
            message.isInvitation = PartWalker.isInvitationType(type)
            return message
        }
        var walker = PartWalker(buf: buf, limits: limits)
        try walker.walkBody(headers, body: block.bodyStart..<buf.count, depth: 0)
        message.textBody = walker.text
        message.isTextShortened = walker.textShortened
        message.htmlBody = walker.html
        message.attachments = walker.attachments
        message.calendar = walker.calendar
        message.isInvitation = walker.calendar?.isInvitation ?? false
        return message
    }
}

enum MessageHeaders {
    static func read(_ headers: Headers) -> MIMEMessage {
        var message = MIMEMessage()
        message.from = AddressScanner.parseList(headers["from"] ?? "")
        message.to = AddressScanner.parseList(headers["to"] ?? "")
        message.cc = AddressScanner.parseList(headers["cc"] ?? "")
        message.bcc = AddressScanner.parseList(headers["bcc"] ?? "")
        message.replyTo = AddressScanner.parseList(headers["reply-to"] ?? "")
        message.subject = EncodedWord.decode(headers["subject"] ?? "")
        message.date = headers["date"].flatMap(InternetDate.parse)
        message.messageID = ids(headers["message-id"] ?? "").first
        message.inReplyTo = ids(headers["in-reply-to"] ?? "")
        message.references = ids(headers["references"] ?? "")
        message.isBulk = isBulk(headers)
        return message
    }

    /// Message ids without their angle brackets; bare tokens when a sender left the brackets out.
    static func ids(_ value: String, maxCount: Int = 1_000) -> [String] {
        var result: [String] = []
        var current = ""
        var inside = false
        for char in value {
            if char == "<" {
                inside = true
                current = ""
            } else if char == ">" && inside {
                inside = false
                if !current.isEmpty { result.append(current) }
            } else if inside {
                current.append(char)
            }
            if result.count >= maxCount { return result }
        }
        if result.isEmpty {
            return value.split { $0.isWhitespace }.prefix(maxCount).map(String.init)
        }
        return result
    }

    private static func isBulk(_ headers: Headers) -> Bool {
        if headers["list-unsubscribe"] != nil || headers["list-id"] != nil { return true }
        let precedence = headers["precedence"]?.trimmingCharacters(in: .whitespaces).lowercased()
        return ["bulk", "list", "junk"].contains(precedence ?? "")
    }
}
