// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
@testable import OutwrightMIME
import Testing

/// Faults found reviewing the Go port, fixed in both engines.
@Suite struct ReviewFindingsTests {
    func message(subject: String) -> OutgoingMessage {
        OutgoingMessage(
            from: Address(name: "Jörgen", email: "j@example.org"),
            to: [Address(name: "Bo", email: "bo@example.org")],
            cc: [], bcc: [], subject: subject, textBody: "text", htmlBody: nil,
            attachments: [
                Attachment(filename: "a.pdf", mimeType: "application/pdf", contentID: nil, isInline: false, data: Data([1]))
            ],
            inReplyTo: nil, references: [], date: Date(timeIntervalSince1970: 1_800_000_000),
            messageID: "x1@example.org")
    }

    func longestLine(_ data: Data) -> Int {
        (String(bytes: data, encoding: .utf8) ?? "").components(separatedBy: "\r\n").map(\.utf8.count).max() ?? 0
    }

    /// A run of spaces, a long media type or a long extra header name never gives a line past 998.
    @Test func noLongRunOrTokenPassesTheLimit() throws {
        let long = "a" + String(repeating: " ", count: 2_000) + "b"
        var named = message(subject: "x")
        named.from = Address(name: long, email: "j@example.org")
        var typed = message(subject: "x")
        typed.attachments[0].mimeType = "a/" + String(repeating: "b", count: 2_000)
        var extra = message(subject: "x")
        extra.extraHeaders = [(name: String(repeating: "X", count: 2_000), value: "v")]
        let blank = message(subject: String(repeating: " ", count: 1_500))
        for item in [message(subject: long), blank, named, typed, extra] {
            #expect(longestLine(try MIMEWriter.write(item, includeBcc: false)) <= 998)
        }
        #expect(try MIMEParser.parse(try MIMEWriter.write(message(subject: long), includeBcc: false)).subject == long)
        #expect(try MIMEParser.parse(try MIMEWriter.write(named, includeBcc: false)).from.first?.name == long)
    }

    /// A thousand hidden elements before a long text cost one pass over it, not a thousand.
    @Test func removingHiddenElementsIsLinear() {
        let text = String(repeating: "plain text ", count: 200_000)
        let html = String(repeating: "<style>p{}</style>", count: 1_000) + text
        let start = ContinuousClock.now
        let out = HTMLText.removingHiddenElements(html)
        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(out == text)
    }

    /// A charset is read from section 0 only, and a section given twice counts once.
    @Test func rfc2231SectionsAreReadOnce() {
        let fromOne = StructuredHeader.parse("attachment; name*1*=utf-8''%C3%A4; name*1*=x; name*0=\"a\"")
        #expect(fromOne.params["name"] == "autf-8''ä")
        let doubled = StructuredHeader.parse("attachment; name*0*=utf-8''%C3%A5; name*0*=zzz; name*1*=%C3%A4")
        #expect(doubled.params["name"] == "åä")
    }
}
