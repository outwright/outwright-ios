// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Testing
@testable import OutwrightMIME

/// A quoted local part (RFC 5322 section 3.4.1) is a mailbox of its own: its quotes and the spaces
/// inside them are kept, read and written.
@Suite struct QuotedLocalPartTests {
    @Test(arguments: [
        ("Bob <\"a b\"@example.org>", "\"a b\"@example.org"),
        ("\"a b\"@example.org", "\"a b\"@example.org"),
        ("Bob <\"a\\\"b\"@example.org>", "\"a\\\"b\"@example.org"),
        ("\"a\\\\b\"@example.org (Bob)", "\"a\\\\b\"@example.org"),
        ("Bob <\"ab\"@example.org>", "ab@example.org"),
        ("\"a.b\"@example.org", "a.b@example.org"),
        ("Bob <a @ example.org>", "a@example.org"),
        ("Bob <\"a \r\n b\"@example.org>", "\"a  b\"@example.org"),
        ("\"a b\" @ example.org", "\"a b\"@example.org"),
    ])
    func aQuotedLocalPartKeepsItsQuotesAndSpaces(_ header: String, _ expected: String) {
        let list = AddressScanner.parseList(header)
        #expect(list.count == 1)
        #expect(list.first?.email == expected)
    }

    @Test func theDisplayNameIsReadAsBefore() {
        let list = AddressScanner.parseList("\"Bo B\" <\"a b\"@example.org>")
        #expect(list.first?.name == "Bo B")
        #expect(list.first?.email == "\"a b\"@example.org")
    }

    @Test func onlyTheDomainIsEncoded() {
        #expect(MailAddress.ascii("\"a b\"@räksmörgås.se") == "\"a b\"@xn--rksmrgs-5wao1o.se")
        #expect(MailAddress.ascii("\"a@ö\"@example.org") == "\"a@ö\"@example.org")
        #expect(MailAddress.ascii("\"a@ö\"") == "\"a@ö\"")
    }

    @Test func aReplyWritesTheQuotedLocalPartIntact() throws {
        let received = try MIMEParser.parse(
            Data("From: Bob <\"a b\"@example.org>\r\nTo: j@example.org\r\nSubject: Hi\r\n\r\nHello\r\n".utf8))
        var to = try #require(received.from.first)
        to.name = String(repeating: "Robert ", count: 10)
        let data = try MIMEWriter.write(reply(to: to), includeBcc: false)
        #expect(String(decoding: data, as: UTF8.self).contains("<\"a b\"@example.org>"))
        #expect(try MIMEParser.parse(data).to.first?.email == "\"a b\"@example.org")
    }

    @Test func aLineBreakInAQuotedLocalPartIsWrittenWithoutIt() throws {
        let data = try MIMEWriter.write(
            reply(to: Address(name: "Bo", email: "\"a \r\nBcc: evil@example.org\"@example.org")), includeBcc: false)
        let head = String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n\r\n").first ?? ""
        #expect(!head.components(separatedBy: "\r\n").contains { $0.hasPrefix("Bcc:") })
        #expect(try MIMEParser.parse(data).to.first?.email == "\"a Bcc: evil@example.org\"@example.org")
    }

    /// Arbitrary quoted local parts never give a line break, a NUL or a trap.
    @Test func arbitraryQuotedAddressesStayClean() {
        var generator = SplitMix64(state: 0x0A0B)
        let pieces = ["a", " ", "\"", "\\", "@", "<", ">", ",", "\r", "\n", "\r\n", "\0", "ö", "(", ")", ":", ";", "."]
        for _ in 0..<2_000 {
            let count = Int.random(in: 0..<60, using: &generator)
            let text = (0..<count).map { _ in pieces[Int.random(in: 0..<pieces.count, using: &generator)] }.joined()
            for address in AddressScanner.parseList(text) {
                #expect(!address.email.unicodeScalars.contains { $0 == "\r" || $0 == "\n" || $0 == "\0" })
            }
        }
    }

    private func reply(to: Address) -> OutgoingMessage {
        OutgoingMessage(
            from: Address(name: "Jörgen", email: "j@example.org"), to: [to], cc: [], bcc: [],
            subject: "Re: Hi", textBody: "Hej", htmlBody: nil, attachments: [], inReplyTo: nil, references: [],
            date: Date(timeIntervalSince1970: 1_800_000_000), messageID: "out1@example.org")
    }
}
