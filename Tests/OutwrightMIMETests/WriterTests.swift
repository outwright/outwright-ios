// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Testing
@testable import OutwrightMIME

@Suite struct WriterTests {
    func outgoing(subject: String = "Räkning åäö") -> OutgoingMessage {
        OutgoingMessage(
            from: Address(name: "Jörgen", email: "j@example.org"),
            to: [Address(name: "Bo", email: "bo@example.org")],
            cc: [Address(name: nil, email: "cc@example.org")],
            bcc: [Address(name: nil, email: "hidden@example.org")],
            subject: subject,
            textBody: "Hej Bo!\nÅäö är bra. " + String(repeating: "lång rad ", count: 30),
            htmlBody: "<p>Hej <b>Bo</b> åäö</p>",
            attachments: [Attachment(filename: "räkning.pdf", mimeType: "application/pdf",
                                     contentID: nil, isInline: false, data: Data((0..<200).map { UInt8($0) }))],
            inReplyTo: "p1@example.org",
            references: ["r1@example.org", "p1@example.org"],
            date: Date(timeIntervalSince1970: 1_800_000_000),
            messageID: "out1@example.org")
    }

    /// A text attachment says its charset, so its UTF-8 arrives as written (RFC 2046 4.1.2).
    @Test func aUTF8TextAttachmentSaysItsCharset() throws {
        var message = outgoing()
        message.attachments = [
            Attachment(filename: "report.txt", mimeType: "text/plain", contentID: nil, isInline: false,
                       data: Data("Räkning åäö".utf8))
        ]
        let written = String(bytes: try MIMEWriter.write(message, includeBcc: false), encoding: .utf8) ?? ""
        let part = try #require(written.range(of: "Content-Disposition: attachment"))
        let headers = written[..<part.lowerBound]
        #expect(headers.hasSuffix("\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n"))
        let read = try MIMEParser.parse(try MIMEWriter.write(message, includeBcc: false))
        #expect(read.attachments.first?.mimeType == "text/plain")
    }

    /// A line starting "From " is written with its F encoded (RFC 3156 §3), so a mail store that
    /// marks such lines never changes the message; it reads back as written.
    @Test func aLineStartingFromIsNeverWrittenAsIs() throws {
        var message = outgoing()
        message.textBody = "From the meeting:\nFrom here on\nnot From here"
        message.htmlBody = nil
        message.attachments = []
        let data = try MIMEWriter.write(message, includeBcc: false)
        let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n")
        #expect(!lines.contains { $0.hasPrefix("From ") })
        #expect(try MIMEParser.parse(data).textBody == message.textBody)
    }

    @Test func roundTripsThroughParser() throws {
        let src = outgoing()
        let data = try MIMEWriter.write(src, includeBcc: false)
        let m = try MIMEParser.parse(data)
        #expect(m.subject == src.subject)
        #expect(m.from == [src.from])
        #expect(m.to == src.to)
        #expect(m.cc == src.cc)
        #expect(m.to.first?.name == "Bo")
        #expect(m.from.first?.name == "Jörgen")
        #expect(m.textBody == src.textBody)
        #expect(m.htmlBody == src.htmlBody)
        #expect(m.attachments.count == 1)
        #expect(m.attachments.first?.filename == "räkning.pdf")
        #expect(m.attachments.first?.data == src.attachments.first?.data)
        #expect(m.messageID == "out1@example.org")
        #expect(m.inReplyTo == ["p1@example.org"])
        #expect(m.references == ["r1@example.org", "p1@example.org"])
        #expect(m.date == src.date)
    }

    @Test func stripsCrLfNulFromHeaders() throws {
        let data = try MIMEWriter.write(outgoing(subject: "a\r\nBcc: x@example.org\0"), includeBcc: false)
        let text = String(decoding: data, as: UTF8.self)
        let head = text.components(separatedBy: "\r\n\r\n")[0]
        let lines = head.components(separatedBy: "\r\n")
        #expect(lines.filter { $0.hasPrefix("Subject:") }.count == 1)
        #expect(!lines.contains { $0.hasPrefix("Bcc:") })
        #expect(!data.contains(0))
    }

    @Test func omitsBccUnlessAsked() throws {
        let without = String(decoding: try MIMEWriter.write(outgoing(), includeBcc: false), as: UTF8.self)
        #expect(!without.contains("Bcc:"))
        let with = String(decoding: try MIMEWriter.write(outgoing(), includeBcc: true), as: UTF8.self)
        #expect(with.contains("Bcc: hidden@example.org"))
    }

    @Test func usesCrlfAndShortLines() throws {
        let data = try MIMEWriter.write(outgoing(), includeBcc: false)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
        for line in text.components(separatedBy: "\r\n") { #expect(line.utf8.count <= 998) }
    }

    @Test func plainMessageHasNoMultipart() throws {
        var m = outgoing()
        m.htmlBody = nil
        m.attachments = []
        let data = try MIMEWriter.write(m, includeBcc: false)
        #expect(!String(decoding: data, as: UTF8.self).contains("multipart"))
        #expect(try MIMEParser.parse(data).textBody == m.textBody)
    }

    /// The lines of the header block.
    func headLines(_ data: Data) -> [String] {
        String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n\r\n")[0].components(separatedBy: "\r\n")
    }

    /// #5: no line of any header passes RFC 5322's 998 octets, however long the names and ids,
    /// and what was written still reads back.
    @Test func noHeaderLinePassesTheLimitAndItAllReadsBack() throws {
        let longName = String(repeating: "😀", count: 110) + ".pdf"
        var m = outgoing()
        m.from = Address(name: String(repeating: "Anna Lind ", count: 200), email: "j@example.org")
        m.to = [Address(name: String(repeating: "Ärlig ", count: 300), email: "bo@example.org")]
        m.attachments = [Attachment(filename: longName, mimeType: "application/pdf", contentID: nil, isInline: false,
                                    data: Data([1, 2, 3]))]
        let data = try MIMEWriter.write(m, includeBcc: false)
        for line in String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n") {
            #expect(line.utf8.count <= 998)
        }
        let read = try MIMEParser.parse(data)
        #expect(read.attachments.first?.filename == longName)
        #expect(read.from.first?.name == m.from.name?.trimmingCharacters(in: .whitespaces))
        #expect(read.to.first?.name == m.to.first?.name?.trimmingCharacters(in: .whitespaces))
    }

    /// #5: an id too long for a line of its own is left out of In-Reply-To, References and
    /// Content-ID rather than written past the limit.
    @Test func anIDTooLongForALineIsLeftOut() throws {
        let huge = String(repeating: "x", count: 1_200) + "@example.org"
        var m = outgoing()
        m.inReplyTo = huge
        m.references = ["r1@example.org", huge]
        m.attachments = [Attachment(filename: "a.png", mimeType: "image/png", contentID: huge, isInline: true,
                                    data: Data([1]))]
        let data = try MIMEWriter.write(m, includeBcc: false)
        for line in String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n") {
            #expect(line.utf8.count <= 998)
        }
        #expect(try MIMEParser.parse(data).references == ["r1@example.org"])
    }

    /// #5: a message whose own Message-ID cannot be written is refused.
    @Test func anOwnMessageIDTooLongIsRefused() {
        var m = outgoing()
        m.messageID = String(repeating: "x", count: 1_200) + "@example.org"
        #expect(throws: MIMEError.notAMessage) { try MIMEWriter.write(m, includeBcc: false) }
    }

    /// #5: arbitrary names, subjects and file names never give a line past the limit.
    @Test func arbitraryHeaderTextStaysWithinTheLimit() throws {
        var generator = SplitMix64(state: 0x00C0_FFEE)
        let pieces = ["a", " ", "ö", "😀", "\"", "=?", "x", "\\", "\t", ";", ","]
        func noise() -> String {
            let count = Int.random(in: 0..<1_500, using: &generator)
            return (0..<count).map { _ in pieces[Int.random(in: 0..<pieces.count, using: &generator)] }.joined()
        }
        for _ in 0..<60 {
            var m = outgoing(subject: noise())
            m.from = Address(name: noise(), email: "j@example.org")
            m.to = [Address(name: noise(), email: "bo@example.org")]
            m.attachments = [Attachment(filename: noise(), mimeType: "text/plain", contentID: nil, isInline: false,
                                        data: Data([1]))]
            let data = try MIMEWriter.write(m, includeBcc: false)
            for line in String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n") {
                #expect(line.utf8.count <= 998)
            }
        }
    }

    /// #16: a long plain subject is folded at its spaces, not encoded.
    @Test func aLongPlainSubjectIsFoldedNotEncoded() throws {
        let subject = String(repeating: "Minutes of the planning meeting ", count: 6).trimmingCharacters(in: .whitespaces)
        let data = try MIMEWriter.write(outgoing(subject: subject), includeBcc: false)
        let lines = headLines(data)
        let start = try #require(lines.firstIndex { $0.hasPrefix("Subject:") })
        let folded = lines[start...].prefix { $0.hasPrefix("Subject:") || $0.hasPrefix(" ") }
        #expect(folded.count > 1)
        #expect(!folded.contains { $0.contains("=?") })
        #expect(folded.allSatisfy { $0.utf8.count <= 78 })
        #expect(try MIMEParser.parse(data).subject == subject)
    }

    /// #17: a sender whose address is only white space is no sender.
    @Test func aBlankSenderAddressIsRefused() {
        var m = outgoing()
        m.from = Address(name: "Jörgen", email: "  \t ")
        #expect(throws: MIMEError.notAMessage) { try MIMEWriter.write(m, includeBcc: false) }
    }

    /// #17: a recipient whose address is only white space is not written as `Name <>`.
    @Test func aBlankRecipientAddressIsLeftOut() throws {
        var m = outgoing()
        m.to = [Address(name: "Nobody", email: " "), Address(name: "Bo", email: "bo@example.org")]
        let data = try MIMEWriter.write(m, includeBcc: false)
        #expect(!String(decoding: data, as: UTF8.self).contains("<>"))
        #expect(try MIMEParser.parse(data).to.map(\.email) == ["bo@example.org"])
    }

    /// #22: a body past the size the writer allows is refused, attachments or not.
    @Test func aBodyTooLargeIsRefusedWithoutAttachments() {
        var m = outgoing()
        m.htmlBody = nil
        m.attachments = []
        m.textBody = String(repeating: "a", count: MIMELimits.default.messageBytes / 2 + 1)
        #expect(throws: MIMEError.tooLarge) { try MIMEWriter.write(m, includeBcc: false) }
    }

    /// #5: a display name with no space to fold at, however escaped and with the longest address
    /// beside it, stays within the limit.
    @Test(arguments: [String(repeating: "x", count: 900), String(repeating: "\"", count: 900),
                      String(repeating: "\\", count: 800)])
    func aDisplayNameWithoutSpacesStaysWithinTheLimit(name: String) throws {
        var m = outgoing()
        let address = String(repeating: "a", count: 240) + "@example.org"
        m.from = Address(name: name, email: address)
        m.to = [Address(name: name, email: address)]
        let data = try MIMEWriter.write(m, includeBcc: false)
        for line in String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n") {
            #expect(line.utf8.count <= 998)
        }
        let read = try MIMEParser.parse(data)
        #expect(read.from.first?.name == name)
        #expect(read.from.first?.email == address)
    }

    /// Folding never leaves a header line that is only white space (RFC 5322's FWS has one CRLF).
    @Test func noHeaderLineIsOnlyWhiteSpace() throws {
        var generator = SplitMix64(state: 0x5EED_F01D)
        let pieces = ["a", "bb", " ", "  ", "   "]
        for _ in 0..<80 {
            let count = Int.random(in: 0..<300, using: &generator)
            let text = (0..<count).map { _ in pieces[Int.random(in: 0..<pieces.count, using: &generator)] }.joined()
            var m = outgoing(subject: text)
            m.from = Address(name: text, email: "j@example.org")
            let lines = headLines(try MIMEWriter.write(m, includeBcc: false))
            #expect(!lines.contains { !$0.isEmpty && $0.allSatisfy { $0 == " " || $0 == "\t" } })
        }
        let edge = String(repeating: "a", count: 70) + "  " + String(repeating: "b", count: 100)
        let lines = headLines(try MIMEWriter.write(outgoing(subject: edge), includeBcc: false))
        #expect(!lines.contains { !$0.isEmpty && $0.allSatisfy { $0 == " " } })
    }

    /// An address longer than SMTP takes is refused, not left out of the header while it is sent.
    @Test func anAddressLongerThanSMTPTakesIsRefused() {
        var m = outgoing()
        m.cc = [Address(name: nil, email: String(repeating: "a", count: 250) + "@example.org")]
        #expect(throws: MIMEError.notAMessage) { try MIMEWriter.write(m, includeBcc: false) }
    }

    @Test func tellsWhichMessageIDsCanBeWritten() {
        #expect(MIMEWriter.canWrite(messageID: "a@example.org"))
        #expect(!MIMEWriter.canWrite(messageID: " "))
        #expect(!MIMEWriter.canWrite(messageID: String(repeating: "x", count: 1_000) + "@example.org"))
    }

    /// #21: a date before 1970 (an old message forwarded, a birthday) is written and read as it is.
    @Test func datesBefore1970RoundTrip() throws {
        for seconds in [-1.0, -86_400.0, -86_401.0, -1_000_000_000.0, -2_208_988_800.0] {
            let date = Date(timeIntervalSince1970: seconds)
            let text = InternetDate.format(date)
            #expect(InternetDate.parse(text) == date, "\(text)")
        }
        #expect(InternetDate.format(Date(timeIntervalSince1970: -1)) == "Wed, 31 Dec 1969 23:59:59 +0000")
        #expect(InternetDate.parse("Sun, 20 Jul 1969 20:17:40 +0000") == Date(timeIntervalSince1970: -14_182_940))
    }

    /// RFC 5322 has no year before 1900: an earlier date is written as the first moment of 1900.
    @Test func aDateBefore1900IsWrittenAs1900() {
        let text = InternetDate.format(Date(timeIntervalSince1970: -3_000_000_000))
        #expect(text == "Mon, 01 Jan 1900 00:00:00 +0000")
    }
}

/// The calendar part of an outgoing message.
extension WriterTests {
    static let replyICS = Data(
        "BEGIN:VCALENDAR\r\nMETHOD:REPLY\r\nBEGIN:VEVENT\r\nUID:u1@example.org\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n".utf8)

    func reply(method: String = "REPLY") -> OutgoingMessage {
        var m = outgoing(subject: "Accepted: Planning")
        m.textBody = "Jörgen has accepted."
        m.attachments = []
        m.calendar = CalendarPart(method: method, data: Self.replyICS)
        return m
    }

    @Test func calendarReplyRoundTrips() throws {
        let data = try MIMEWriter.write(reply(), includeBcc: false)
        let m = try MIMEParser.parse(data)
        #expect(m.calendar?.method == "REPLY")
        #expect(m.calendar?.data == Self.replyICS)
        #expect(m.textBody == "Jörgen has accepted.")
        #expect(m.htmlBody == nil)
        #expect(m.isInvitation)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("multipart/alternative"))
        let typeLine = text.components(separatedBy: "\r\n").first { $0.hasPrefix("Content-Type: text/calendar") }
        #expect(typeLine?.contains("method=REPLY") == true)
        #expect(typeLine?.contains("charset=utf-8") == true)
    }

    @Test func calendarWithAttachmentsKeepsBoth() throws {
        var src = reply()
        src.attachments = outgoing().attachments
        let m = try MIMEParser.parse(try MIMEWriter.write(src, includeBcc: false))
        #expect(m.calendar?.data == Self.replyICS)
        #expect(m.attachments.contains { $0.filename == "räkning.pdf" })
    }

    @Test func calendarHeaderValuesAreStripped() throws {
        let data = try MIMEWriter.write(reply(method: "REPLY\r\nBcc: x@example.org\0"), includeBcc: false)
        let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n")
        #expect(!data.contains(0))
        #expect(!lines.contains { $0.hasPrefix("Bcc:") })
        #expect(lines.filter { $0.hasPrefix("Content-Type: text/calendar") }.count == 1)
        let m = try MIMEParser.parse(data)
        #expect(m.calendar?.data == Self.replyICS)
    }
}
