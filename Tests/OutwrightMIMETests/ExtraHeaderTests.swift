// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Testing

@testable import OutwrightMIME

@Suite struct ExtraHeaderTests {
    func message(_ headers: [(name: String, value: String)]) -> OutgoingMessage {
        var message = OutgoingMessage(
            from: Address(name: nil, email: "j@example.org"), to: [Address(name: nil, email: "bo@example.org")],
            cc: [], bcc: [], subject: "Hi", textBody: "text", htmlBody: nil, attachments: [], inReplyTo: nil,
            references: [], date: Date(timeIntervalSince1970: 1_800_000_000), messageID: "x1@example.org")
        message.extraHeaders = headers
        return message
    }

    @Test func extraHeadersAreWrittenAmongTheHeaders() throws {
        let data = try MIMEWriter.write(message([(name: "X-Test", value: "one")]), includeBcc: false)
        let wire = String(decoding: data, as: UTF8.self)
        let head = try #require(wire.components(separatedBy: "\r\n\r\n").first)
        #expect(head.contains("\r\nX-Test: one"))
    }

    @Test func stripsLineBreaks() throws {
        let data = try MIMEWriter.write(
            message([(name: "X-Te\r\nst", value: "a\r\nBcc: evil@example.org\0b")]), includeBcc: false)
        let wire = String(decoding: data, as: UTF8.self)
        let head = try #require(wire.components(separatedBy: "\r\n\r\n").first)
        let lines = head.components(separatedBy: "\r\n")
        #expect(!lines.contains { $0.hasPrefix("Bcc:") })
        #expect(!data.contains(0))
        #expect(lines.contains { $0.hasPrefix("X-Test: ") })
    }
}
