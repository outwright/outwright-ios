// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Testing
@testable import OutwrightMIME

@Suite struct ParserTests {
    @Test func decodesEncodedWordsInSubjectAndNames() throws {
        let m = try MIMEParser.parse(Fixtures.alternative)
        #expect(m.subject == "Ärende")
        #expect(m.from.first?.name == "Jörgen")
        #expect(m.from.first?.email.lowercased() == "j@example.org")
        #expect(m.to.count == 2)
        #expect(m.to.last?.name == "Bo B")
        #expect(m.messageID == "m1@example.org")
        #expect(m.date != nil)
    }

    @Test func readsBccOfADraft() throws {
        let raw = Fixtures.data("""
        From: a@example.org
        To: b@example.org
        Bcc: Cy <c@example.org>, d@example.org
        Subject: draft

        text
        """)
        let m = try MIMEParser.parse(raw)
        #expect(m.bcc.map(\.email) == ["c@example.org", "d@example.org"])
        #expect(try MIMEParser.parse(Fixtures.alternative).bcc.isEmpty)
    }

    @Test func picksTextAndHtmlFromAlternative() throws {
        let m = try MIMEParser.parse(Fixtures.alternative)
        #expect(m.textBody?.contains("Hello plain") == true)
        #expect(m.htmlBody?.contains("Hello html") == true)
    }

    @Test func decodesLatin1AndWindows1252Bodies() throws {
        let raw = Fixtures.data("""
        From: a@example.org
        Content-Type: text/plain; charset=windows-1252
        Content-Transfer-Encoding: quoted-printable

        =E5=E4=F6
        """)
        let m = try MIMEParser.parse(raw)
        #expect(m.textBody == "åäö")
        let latin = Fixtures.data("""
        From: a@example.org
        Content-Type: text/plain; charset=ISO-8859-1
        Content-Transfer-Encoding: quoted-printable

        =C5=E4=F6 =E9
        """)
        #expect(try MIMEParser.parse(latin).textBody == "Åäö é")
        var binary = Fixtures.data("From: a@example.org\nContent-Type: text/plain; charset=iso-8859-1\n\n")
        binary.append(contentsOf: [0xE5, 0xE4, 0xF6])
        #expect(try MIMEParser.parse(binary).textBody == "åäö")
    }

    @Test func unknownCharsetFallsBack() throws {
        let raw = Fixtures.data("""
        From: a@example.org
        Content-Type: text/plain; charset=x-nonsense

        Plain words
        """)
        let m = try MIMEParser.parse(raw)
        #expect(m.textBody?.isEmpty == false)
    }

    @Test func collectsAttachmentsAndInlineCid() throws {
        let m = try MIMEParser.parse(Fixtures.mixed)
        let pdf = m.attachments.first { $0.mimeType == "application/pdf" }
        #expect(pdf?.filename == "räkning.pdf")
        #expect(pdf?.isInline == false)
        #expect(pdf?.data == Data([0x25, 0x50, 0x44, 0x46, 0x2D]))
        let img = m.attachments.first { $0.mimeType == "image/png" }
        #expect(img?.contentID == "logo@example.org")
        #expect(img?.isInline == true)
        #expect(m.htmlBody?.contains("cid:") == true)
    }

    @Test func flagsBulkAndInvitation() throws {
        let m = try MIMEParser.parse(Fixtures.mixed)
        #expect(m.isBulk)
        #expect(m.isInvitation)
        let plain = try MIMEParser.parse(Fixtures.alternative)
        #expect(!plain.isBulk)
        #expect(!plain.isInvitation)
        let prec = Fixtures.data("From: a@example.org\nPrecedence: bulk\n\nx")
        #expect(try MIMEParser.parse(prec).isBulk)
    }

    @Test func readsThreadingHeaders() throws {
        let m = try MIMEParser.parse(Fixtures.mixed)
        #expect(m.inReplyTo == ["p1@example.org"])
        #expect(m.references == ["r1@example.org", "r2@example.org"])
    }

    @Test func headersOnlyLeavesBodiesNil() throws {
        let m = try MIMEParser.parseHeaders(Fixtures.alternative)
        #expect(m.subject == "Ärende")
        #expect(m.textBody == nil)
        #expect(m.htmlBody == nil)
        #expect(m.attachments.isEmpty)
    }

    @Test func foldedHeadersAreUnfolded() throws {
        let raw = Fixtures.data("From: a@example.org\nSubject: one\n two\n\nx")
        #expect(try MIMEParser.parse(raw).subject == "one two")
    }

    @Test func limitsAreEnforced() {
        let small = MIMELimits(messageBytes: 10, headerBytes: 1 << 20, depth: 32, parts: 1_000)
        #expect(throws: MIMEError.tooLarge) { try MIMEParser.parse(Fixtures.alternative, limits: small) }
        let shallow = MIMELimits(messageBytes: 1 << 20, headerBytes: 1 << 20, depth: 1, parts: 1_000)
        #expect(throws: MIMEError.tooDeep) { try MIMEParser.parse(Fixtures.mixed, limits: shallow) }
        let few = MIMELimits(messageBytes: 1 << 20, headerBytes: 1 << 20, depth: 32, parts: 2)
        #expect(throws: MIMEError.tooManyParts) { try MIMEParser.parse(Fixtures.mixed, limits: few) }
        #expect(throws: MIMEError.notAMessage) { try MIMEParser.parse(Data()) }
    }

    @Test func aHeaderOverItsLimitIsRefused() throws {
        let raw = Fixtures.data("From: a@example.org\nSubject: " + String(repeating: "x", count: 2_000) + "\n\nbody")
        let tight = MIMELimits(headerBytes: 1_000)
        #expect(throws: MIMEError.tooLarge) { try MIMEParser.parse(raw, limits: tight) }
        #expect(try MIMEParser.parse(raw, limits: MIMELimits(headerBytes: 4_000)).textBody == "body")
    }

    /// Numeric references and the common named ones are read, each once; an unknown or broken
    /// one, and one past Unicode, stays as written.
    @Test func previewReadsCharacterReferences() {
        let head = Data("Content-Type: text/html; charset=us-ascii\r\n\r\n".utf8)
        func preview(_ html: String) -> String { Preview.text(fromPartial: Data(html.utf8), headers: head) }
        #expect(preview("<p>TIDSBEGR&#196;NSAT tr&#xE4;ckern</p>") == "TIDSBEGRÄNSAT träckern")
        #expect(preview("<p>&auml;r &Ouml;stra &aring; &eacute; &euro;5 &hellip;</p>") == "är Östra å é €5 …")
        #expect(preview("<p>&amp;lt; is &lt;</p>") == "&lt; is <")
        #expect(preview("<p>&#99999999999; &#xD800; &bogus; & x</p>") == "&#99999999999; &#xD800; &bogus; & x")
    }

    @Test func previewSkipsQuotesAndTags() {
        let head = Data("Content-Type: text/html; charset=utf-8\r\n\r\n".utf8)
        let html = Data("<p>Hej</p><blockquote>old</blockquote>".utf8)
        #expect(Preview.text(fromPartial: html, headers: head) == "Hej")
        let plain = Data("Content-Type: text/plain\r\n\r\n".utf8)
        let text = Data("Hi there\r\n> quoted\r\nbye".utf8)
        #expect(Preview.text(fromPartial: text, headers: plain) == "Hi there bye")
    }

    @Test func previewFromTruncatedMultipartQuotedPrintable() {
        let head = Data("Content-Type: multipart/alternative; boundary=\"b1\"\r\n\r\n".utf8)
        let body = Fixtures.data("""
        --b1
        Content-Type: text/plain; charset=utf-8
        Content-Transfer-Encoding: quoted-printable

        Hej =C3=A5=C3=A4 v=
        """)
        #expect(Preview.text(fromPartial: body, headers: head) == "Hej åä v")
        let cut = body.prefix(body.count - 1) + Data("=C".utf8)
        #expect(Preview.text(fromPartial: Data(cut), headers: head).hasPrefix("Hej åä"))
    }

    @Test func previewFromBase64Part() {
        let head = Data("Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n".utf8)
        let encoded = Data("Hej världen".utf8).base64EncodedString()
        let cut = Data(encoded.prefix(encoded.count - 3).utf8)
        let text = Preview.text(fromPartial: cut, headers: head)
        #expect(text.hasPrefix("Hej v"))
        #expect(text.count >= 5)
    }

    @Test func previewTrimsCutUtf8() {
        let head = Data("Content-Type: text/plain; charset=utf-8\r\n\r\n".utf8)
        let bytes = Array("åäö".utf8)
        #expect(Preview.text(fromPartial: Data(bytes.prefix(5)), headers: head) == "åä")
        #expect(Preview.text(fromPartial: Data(bytes.prefix(1)), headers: head) == "")
    }

    @Test func longAddressInputIsLinear() throws {
        let value = String(repeating: "a", count: 500_000) + "@" + String(repeating: ":", count: 500_000)
        let raw = Data(("From: " + value + "\r\n\r\n").utf8)
        let start = SuspendingClock.now
        _ = try MIMEParser.parseHeaders(raw)
        #expect(SuspendingClock.now - start < .seconds(2))
    }

    @Test func addressEmailIsCaseInsensitive() {
        #expect(Address(name: "A", email: "X@Example.org") == Address(name: nil, email: "x@example.org"))
    }

    /// Multiparts nested and side by side, with lines that look like delimiters and are not, CR-only
    /// and bare-LF line ends: every part reads back as written.
    @Test func nestedPartsReadBackWhateverTheirLines() throws {
        var generator = SplitMix64(state: 0xB0B_0000)
        let noise = ["--", "--x", "-- b0", "--b0x", "plain", "\r", "a\rb", ""]
        for round in 0..<60 {
            var texts: [String] = []
            func text() -> String {
                let count = Int.random(in: 1..<6, using: &generator)
                let body = (0..<count).map { _ in noise[Int.random(in: 0..<noise.count, using: &generator)] }
                    .joined(separator: Bool.random(using: &generator) ? "\r\n" : "\n")
                let marked = "part\(texts.count) " + body
                texts.append(marked)
                return marked
            }
            let depth = Int.random(in: 1..<5, using: &generator)
            var inner = "Content-Type: text/plain\r\nContent-Disposition: attachment; filename=i.txt\r\n\r\n" + text()
            for level in 0..<depth {
                let boundary = "b\(round)-\(level)"
                let sibling = "Content-Type: text/plain\r\nContent-Disposition: attachment; filename=s\(level).txt\r\n\r\n"
                    + text()
                inner = "Content-Type: multipart/mixed; boundary=\"\(boundary)\"\r\n\r\n"
                    + "--\(boundary)\r\n\(inner)\r\n--\(boundary)\r\n\(sibling)\r\n--\(boundary)--\r\n"
            }
            let message = "From: a@example.org\r\nSubject: x\r\nMIME-Version: 1.0\r\n" + inner
            let parsed = try MIMEParser.parse(Data(message.utf8))
            let read = parsed.attachments.map { String(decoding: $0.data, as: UTF8.self) }
            #expect(Set(read) == Set(texts))
        }
    }

    /// #12: a text file attached before the message's own text is not its preview.
    @Test func aTextAttachmentIsNotThePreview() {
        let head = Data("Content-Type: multipart/mixed; boundary=\"m\"\r\n\r\n".utf8)
        let body = Data(("--m\r\nContent-Type: text/plain\r\nContent-Disposition: attachment; filename=log.txt\r\n\r\n"
            + "ERROR 42 in the log\r\n--m\r\nContent-Type: text/plain\r\n\r\nHej Bo, se loggen.\r\n--m--\r\n").utf8)
        #expect(Preview.text(fromPartial: body, headers: head) == "Hej Bo, se loggen.")
    }

    /// #18: a limit on the text cuts it while it is read, and says so.
    @Test func aTextLimitCutsTheTextWhileItIsRead() throws {
        let long = String(repeating: "abcdefghij", count: 1_000)
        let raw = Data(("From: bo@example.org\r\nContent-Type: text/plain\r\n\r\n" + long).utf8)
        let cut = try MIMEParser.parse(raw, limits: MIMELimits(textBytes: 100))
        #expect(cut.textBody?.count == 100)
        #expect(cut.isTextShortened)
        let whole = try MIMEParser.parse(raw)
        #expect(whole.textBody == long)
        #expect(!whole.isTextShortened)
    }

    /// #18: a limit cuts quoted-printable and base64 text after it is decoded: what is kept is the
    /// text's own beginning, and the cut is said.
    @Test(arguments: ["quoted-printable", "base64"])
    func aTextLimitKeepsTheBeginningWhateverTheEncoding(encoding: String) throws {
        let text = String(repeating: "Привет мир ", count: 2_000)
        let body: String
        if encoding == "base64" {
            body = Data(text.utf8).base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
        } else {
            body = Data(text.utf8).map { String(format: "=%02X", $0) }.joined()
                .split(every: 72).joined(separator: "=\r\n")
        }
        let raw = Data(("From: bo@example.org\r\nContent-Type: text/plain; charset=utf-8\r\n"
            + "Content-Transfer-Encoding: \(encoding)\r\n\r\n" + body).utf8)
        for limit in [10_000, 10_001, 10_003] {
            let cut = try MIMEParser.parse(raw, limits: MIMELimits(textBytes: limit))
            let read = try #require(cut.textBody)
            #expect(cut.isTextShortened)
            #expect(text.hasPrefix(read))
            #expect(read.utf8.count > limit - 4)
        }
    }

    /// #18: a text in another charset is cut on a whole character, never read as Latin-1.
    @Test(arguments: [("shift_jis", String.Encoding.shiftJIS), ("utf-16be", String.Encoding.utf16BigEndian),
                      ("euc-jp", String.Encoding.japaneseEUC)])
    func aTextLimitCutsOnAWholeCharacterInAnyCharset(label: String, encoding: String.Encoding) throws {
        let text = String(repeating: "日本語のテキスト", count: 500)
        let bytes = try #require(text.data(using: encoding))
        let raw = Data("From: bo@example.org\r\nContent-Type: text/plain; charset=\(label)\r\nContent-Transfer-Encoding: 8bit\r\n\r\n".utf8)
            + bytes
        for limit in [1_001, 1_002, 1_003] {
            let read = try #require(try MIMEParser.parse(raw, limits: MIMELimits(textBytes: limit)).textBody)
            #expect(!read.isEmpty)
            #expect(text.hasPrefix(read))
        }
    }

    /// Any bytes, any small limit: reading never traps and never keeps more text than allowed.
    @Test func aTextLimitHoldsOverArbitraryBytes() {
        var generator = SplitMix64(state: 0x7E57_B17E)
        let encodings = ["", "quoted-printable", "base64", "8bit"]
        let charsets = ["", "utf-8", "shift_jis", "utf-16", "iso-8859-1"]
        for _ in 0..<500 {
            let count = Int.random(in: 0..<600, using: &generator)
            let noise = (0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) }
            let encoding = encodings[Int.random(in: 0..<encodings.count, using: &generator)]
            let charset = charsets[Int.random(in: 0..<charsets.count, using: &generator)]
            let limit = Int.random(in: 0..<200, using: &generator)
            let head = "From: a@example.org\r\nContent-Type: text/plain; charset=\(charset)\r\n"
                + "Content-Transfer-Encoding: \(encoding)\r\n\r\n"
            guard let message = try? MIMEParser.parse(Data(head.utf8) + Data(noise), limits: MIMELimits(textBytes: limit))
            else { continue }
            #expect((message.textBody?.unicodeScalars.count ?? 0) <= max(limit, 0))
        }
    }

    /// #12: a text part sent inline with a file name is an attachment to the preview too.
    @Test func anInlineTextFileIsNotThePreview() {
        let head = Data("Content-Type: multipart/mixed; boundary=\"m\"\r\n\r\n".utf8)
        let body = Data(("--m\r\nContent-Type: text/plain; name=log.txt\r\nContent-Disposition: inline; filename=log.txt\r\n\r\n"
            + "ERROR 42 in the log\r\n--m\r\nContent-Type: text/plain\r\n\r\nHej Bo, se loggen.\r\n--m--\r\n").utf8)
        #expect(Preview.text(fromPartial: body, headers: head) == "Hej Bo, se loggen.")
    }
}

private extension String {
    /// The string in pieces of `size` characters.
    func split(every size: Int) -> [String] {
        var pieces: [String] = []
        var rest = self[...]
        while !rest.isEmpty {
            pieces.append(String(rest.prefix(size)))
            rest = rest.dropFirst(size)
        }
        return pieces
    }
}

/// The calendar part of a message.
extension ParserTests {
    @Test func outlookStyleInvitationHasCalendarPart() throws {
        let m = try MIMEParser.parse(Fixtures.outlookInvitation)
        #expect(m.calendar?.method == "REQUEST")
        let ics = String(decoding: m.calendar?.data ?? Data(), as: UTF8.self)
        #expect(ics.contains("UID:u1@example.org"))
        #expect(m.isInvitation)
        #expect(m.textBody == "Planning meeting")
        #expect(m.htmlBody == "<p>Planning meeting</p>")
    }

    @Test func icsAttachmentWithMethodInBody() throws {
        let m = try MIMEParser.parse(Fixtures.icsAttachment(method: "CANCEL"))
        #expect(m.calendar?.method == "CANCEL")
        #expect(m.isInvitation)
        #expect(m.attachments.contains { $0.filename == "invite.ics" })
    }

    @Test func replyIsAnInvitationMessage() throws {
        let m = try MIMEParser.parse(Fixtures.icsAttachment(method: "reply"))
        #expect(m.calendar?.method == "REPLY")
        #expect(m.isInvitation)
    }

    @Test func publishIsNot() throws {
        let m = try MIMEParser.parse(Fixtures.icsAttachment(method: "PUBLISH"))
        #expect(m.calendar?.method == "PUBLISH")
        #expect(!m.isInvitation)
        #expect(m.attachments.count == 1)
    }

    @Test func aMessageWithoutCalendarHasNone() throws {
        #expect(try MIMEParser.parse(Fixtures.alternative).calendar == nil)
    }

    @Test func oversizedCalendarPartIsOnlyAnAttachment() throws {
        let line = "X-PAD:" + String(repeating: "a", count: 70) + "\r\n"
        let pad = String(repeating: line, count: (600 << 10) / line.utf8.count)
        var raw = Data("""
        From: org@example.org\r
        Content-Type: multipart/mixed; boundary="mix"\r
        \r
        --mix\r
        Content-Type: text/calendar; charset=utf-8; method=REQUEST\r
        Content-Disposition: attachment; filename="big.ics"\r
        \r
        BEGIN:VCALENDAR\r
        METHOD:REQUEST\r

        """.utf8)
        raw.append(Data(pad.utf8))
        raw.append(Data("END:VCALENDAR\r\n--mix--\r\n".utf8))
        let m = try MIMEParser.parse(raw)
        #expect(m.calendar == nil)
        #expect(!m.isInvitation)
        #expect(m.attachments.count == 1)
        #expect(m.attachments.first?.mimeType == "text/calendar")
    }

    @Test func headersAloneMarkEveryHandledMethod() throws {
        for method in ["REQUEST", "add", "CANCEL", "REPLY"] {
            let raw = Fixtures.data("From: a@example.org\nContent-Type: text/calendar; method=\(method)\n\nx")
            #expect(try MIMEParser.parseHeaders(raw).isInvitation)
        }
        let publish = Fixtures.data("From: a@example.org\nContent-Type: text/calendar; method=PUBLISH\n\nx")
        #expect(try !MIMEParser.parseHeaders(publish).isInvitation)
    }
}
