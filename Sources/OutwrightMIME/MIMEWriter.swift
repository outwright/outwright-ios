// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation

/// Writes outgoing messages: RFC 2047 headers, quoted-printable text, base64 attachments, CRLF line ends.
public enum MIMEWriter {
    private static let crlf: [UInt8] = [0x0D, 0x0A]

    public static func write(_ message: OutgoingMessage, includeBcc: Bool) throws(MIMEError) -> Data {
        let limits = MIMELimits.default
        guard !WriterSupport.mailbox(message.from).isEmpty else { throw .notAMessage }
        // An address too long for SMTP is refused, not left out of the header while it is sent to.
        let addresses = message.to + message.cc + message.bcc
        guard !addresses.contains(where: { WriterSupport.address($0.email).utf8.count > WriterSupport.maxAddress })
        else { throw .notAMessage }
        guard message.attachments.count < limits.parts else { throw .tooManyParts }
        var size = message.textBody.utf8.count + (message.calendar?.data.count ?? message.htmlBody?.utf8.count ?? 0)
        guard size <= limits.messageBytes / 2 else { throw .tooLarge }
        guard let ownID = WriterSupport.messageID(message.messageID) else { throw .notAMessage }
        for attachment in message.attachments {
            let (sum, overflow) = size.addingReportingOverflow(attachment.data.count)
            guard !overflow, sum <= limits.messageBytes / 2 else { throw .tooLarge }
            size = sum
        }
        var headers = topHeaders(message, ownID: ownID, includeBcc: includeBcc)
        let (typeHeaders, body) = structure(message)
        headers += typeHeaders
        var out = Array(headers.joined(separator: "\r\n").utf8)
        out += crlf + crlf
        out += body
        return Data(out)
    }

    /// Whether `messageID` can be written as a message's own (not blank, not too long for a line).
    public static func canWrite(messageID: String) -> Bool {
        WriterSupport.messageID(messageID) != nil
    }

    private static func topHeaders(_ message: OutgoingMessage, ownID: String, includeBcc: Bool) -> [String] {
        var headers = ["Date: " + InternetDate.format(message.date)]
        headers.append(WriterSupport.fold("From", [WriterSupport.mailbox(message.from)], separator: ","))
        let lists = [("To", message.to), ("Cc", message.cc), ("Bcc", includeBcc ? message.bcc : [])]
        for (name, list) in lists {
            if let line = WriterSupport.addressHeader(name, list) { headers.append(line) }
        }
        headers.append("Subject: " + WriterSupport.unstructured(message.subject))
        headers.append("Message-ID: " + ownID)
        // An id that cannot be written is left out: the reply still goes, less well threaded.
        if let parent = message.inReplyTo.flatMap(WriterSupport.messageID) {
            headers.append("In-Reply-To: " + parent)
        }
        let ids = message.references.compactMap(WriterSupport.messageID)
        if !ids.isEmpty {
            headers.append(WriterSupport.fold("References", ids, separator: ""))
        }
        headers.append("MIME-Version: 1.0")
        for extra in message.extraHeaders {
            let name = String(extra.name.unicodeScalars.filter { (0x21..<0x7F).contains($0.value) && $0 != ":" })
            guard !name.isEmpty else { continue }
            headers.append(name + ": " + WriterSupport.unstructured(extra.value, used: name.utf8.count + 2))
        }
        return headers
    }

    private static let textHeaders = ["Content-Transfer-Encoding: quoted-printable"]

    private static func textPart(_ type: String, _ content: String) -> [UInt8] {
        part(["Content-Type: \(type); charset=utf-8"] + textHeaders, WriterSupport.quotedPrintable(content) + crlf)
    }

    /// The Content-* headers of the whole message and its body bytes (ending in CRLF).
    private static func structure(_ message: OutgoingMessage) -> ([String], [UInt8]) {
        var headers = ["Content-Type: text/plain; charset=utf-8"] + textHeaders
        var body = WriterSupport.quotedPrintable(message.textBody) + crlf
        if let calendar = message.calendar {
            let boundary = makeBoundary()
            headers = ["Content-Type: multipart/alternative; boundary=\"\(boundary)\""]
            body = multipart(boundary, [textPart("text/plain", message.textBody), calendarPart(calendar)])
        } else if let html = message.htmlBody {
            let boundary = makeBoundary()
            headers = ["Content-Type: multipart/alternative; boundary=\"\(boundary)\""]
            body = multipart(boundary, [textPart("text/plain", message.textBody), textPart("text/html", html)])
        }
        // Pictures the HTML shows by Content-ID go with it in multipart/related (RFC 2387).
        let isShown = { (attachment: Attachment) in
            attachment.isInline && attachment.contentID.flatMap(WriterSupport.messageID) != nil
        }
        let shown = message.htmlBody == nil || message.calendar != nil ? [] : message.attachments.filter(isShown)
        let files = shown.isEmpty ? message.attachments : message.attachments.filter { !isShown($0) }
        if !shown.isEmpty {
            let boundary = makeBoundary()
            body = multipart(boundary, [part(headers, body)] + shown.map(attachmentPart))
            headers = ["Content-Type: multipart/related; boundary=\"\(boundary)\"; type=\"multipart/alternative\""]
        }
        guard !files.isEmpty else { return (headers, body) }
        let boundary = makeBoundary()
        let parts = [part(headers, body)] + files.map(attachmentPart)
        return (["Content-Type: multipart/mixed; boundary=\"\(boundary)\""], multipart(boundary, parts))
    }

    /// The calendar as an alternative to the text, in base64 so its bytes arrive as they are.
    private static func calendarPart(_ calendar: CalendarPart) -> [UInt8] {
        let method = PartWalker.methodToken(WriterSupport.clean(calendar.method))
        let type = "Content-Type: text/calendar; charset=utf-8" + (method.isEmpty ? "" : "; method=\(method)")
        return part([type, "Content-Transfer-Encoding: base64"], WriterSupport.base64Lines(calendar.data) + crlf)
    }

    private static func attachmentPart(_ attachment: Attachment) -> [UInt8] {
        let type = WriterSupport.token(attachment.mimeType, fallback: "application/octet-stream")
        // A text part without a charset is read as US-ASCII (RFC 2046 4.1.2): UTF-8 text says so.
        let isUTF8Text = type.lowercased().hasPrefix("text/") && String(bytes: attachment.data, encoding: .utf8) != nil
        let charset = isUTF8Text ? "; charset=utf-8" : ""
        var headers = ["Content-Type: \(type)\(charset)", "Content-Transfer-Encoding: base64"]
        let disposition = attachment.isInline ? "inline" : "attachment"
        let parameters = WriterSupport.filenameParameters(attachment.filename)
        headers.append("Content-Disposition: \(disposition);\r\n \(parameters)")
        if let contentID = attachment.contentID.flatMap(WriterSupport.messageID) {
            headers.append("Content-ID: " + contentID)
        }
        return part(headers, WriterSupport.base64Lines(attachment.data) + crlf)
    }

    private static func part(_ headers: [String], _ body: [UInt8]) -> [UInt8] {
        Array(headers.joined(separator: "\r\n").utf8) + crlf + crlf + body
    }

    private static func multipart(_ boundary: String, _ parts: [[UInt8]]) -> [UInt8] {
        var out: [UInt8] = []
        for item in parts {
            out += Array("--\(boundary)\r\n".utf8) + item + crlf
        }
        out += Array("--\(boundary)--\r\n".utf8)
        return out
    }

    private static func makeBoundary() -> String { "=_Outwright_" + UUID().uuidString }
}
