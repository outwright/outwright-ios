// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightFakes
import OutwrightNet
import Testing
@testable import OutwrightSMTP

/// Addresses with non-ASCII characters (RFC 6531): a domain goes as its A-labels, a local part
/// needs the server's SMTPUTF8.
@Suite struct UTF8AddressTests {
    private let message = Data("From: jk@example.org\r\nTo: a@example.org\r\nSubject: Hi\r\n\r\nHello\r\n".utf8)

    private func send(
        _ data: Data, from: String = "jk@example.org", to: [String], port: UInt16
    ) async throws(SMTPError) {
        try await SMTPClient.send(
            data, envelopeFrom: from, recipients: to,
            via: ServerEndpoint(host: "127.0.0.1", port: port, security: .plainLoopbackOnly),
            user: "jk@example.org", password: Secret("secret"))
    }

    @Test func aNonASCIIDomainGoesAsItsALabelsWithoutSMTPUTF8() async throws {
        let server = FakeSMTPServer()
        let port = try await server.start()
        try await send(message, to: ["bo@räksmörgås.se"], port: port)
        let received = await server.received
        let parameters = await server.mailParameters
        await server.stop()
        #expect(received.first?.to == ["bo@xn--rksmrgs-5wao1o.se"])
        #expect(parameters == [""])
    }

    @Test func aNonASCIILocalPartAsksForSMTPUTF8WhenOffered() async throws {
        let server = FakeSMTPServer(offersSMTPUTF8: true)
        let port = try await server.start()
        try await send(message, to: ["jörgen@example.org"], port: port)
        let received = await server.received
        let parameters = await server.mailParameters
        await server.stop()
        #expect(received.first?.to == ["jörgen@example.org"])
        #expect(parameters == ["SMTPUTF8"])
    }

    @Test func aMessageWithUTF8HeadersAsksForSMTPUTF8() async throws {
        let server = FakeSMTPServer(offersSMTPUTF8: true)
        let port = try await server.start()
        let utf8 = Data("From: jk@example.org\r\nCc: jörgen@example.org\r\n\r\nHello\r\n".utf8)
        try await send(utf8, to: ["a@example.org"], port: port)
        let parameters = await server.mailParameters
        await server.stop()
        #expect(parameters == ["SMTPUTF8"])
    }

    @Test func anASCIIMessageDoesNotAskForSMTPUTF8EvenWhenOffered() async throws {
        let server = FakeSMTPServer(offersSMTPUTF8: true)
        let port = try await server.start()
        let body = Data("Subject: x\r\n\r\nHej på dig\r\n".utf8)
        try await send(body, to: ["a@example.org"], port: port)
        let parameters = await server.mailParameters
        await server.stop()
        #expect(parameters == [""])
    }

    @Test(arguments: [
        (["jörgen@example.org"], "jk@example.org", false),
        (["a@example.org"], "jörgen@example.org", false),
        (["a@example.org"], "jk@example.org", true),
    ])
    func aServerWithoutSMTPUTF8GetsNoMessageThatNeedsIt(_ to: [String], _ from: String, _ inHeader: Bool) async throws {
        let server = FakeSMTPServer()
        let port = try await server.start()
        let data = inHeader ? Data("From: jk@example.org\r\nTo: jörgen@example.org\r\n\r\nHello\r\n".utf8) : message
        var failure: SMTPError?
        do {
            try await send(data, from: from, to: to, port: port)
        } catch {
            failure = error
        }
        let received = await server.received
        let parameters = await server.mailParameters
        await server.stop()
        #expect(failure == .smtpUTF8NotOffered)
        #expect(received.isEmpty)
        #expect(parameters.isEmpty)
    }

    @Test func aDomainWithNoASCIIFormIsAnInvalidRecipient() async throws {
        let server = FakeSMTPServer(offersSMTPUTF8: true)
        let port = try await server.start()
        var failure: SMTPError?
        do {
            try await send(message, to: ["a@" + String(repeating: "ö", count: 70) + ".se"], port: port)
        } catch {
            failure = error
        }
        await server.stop()
        #expect(failure == .invalidRecipient)
    }
}
