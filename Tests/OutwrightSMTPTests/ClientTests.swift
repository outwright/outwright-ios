// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightFakes
import OutwrightNet
import Testing
@testable import OutwrightSMTP

@Suite struct ClientTests {
    private let message = Data("From: jk@example.org\r\nTo: a@example.org\r\nSubject: Hi\r\n\r\nHello\r\n".utf8)

    private func endpoint(_ port: UInt16, _ security: TransportSecurity = .plainLoopbackOnly) -> ServerEndpoint {
        ServerEndpoint(host: "127.0.0.1", port: port, security: security)
    }

    private func send(
        _ data: Data, from: String = "jk@example.org", to: [String],
        port: UInt16, security: TransportSecurity = .plainLoopbackOnly, password: String = "secret"
    ) async throws(SMTPError) {
        try await SMTPClient.send(
            data, envelopeFrom: from, recipients: to, via: endpoint(port, security),
            user: "jk@example.org", password: Secret(password))
    }

    @Test func sendsMessageToAllRecipients() async throws {
        let server = FakeSMTPServer()
        let port = try await server.start()
        let to = ["a@example.org", "b@example.org", "c@example.org"]
        try await send(message, to: to, port: port)
        let received = await server.received
        await server.stop()
        #expect(received.count == 1)
        #expect(received.first?.from == "jk@example.org")
        #expect(received.first?.to == to)
        #expect(received.first?.data == message)
    }

    @Test func dotStuffsLinesStartingWithDot() async throws {
        let server = FakeSMTPServer()
        let port = try await server.start()
        let body = Data("Subject: x\r\n\r\n.hidden\r\n..two\r\n.\r\nend".utf8)
        try await send(body, to: ["a@example.org"], port: port)
        let received = await server.received
        await server.stop()
        #expect(received.first?.data == Data("Subject: x\r\n\r\n.hidden\r\n..two\r\n.\r\nend\r\n".utf8))
    }

    @Test func startTLSNotOfferedRefusedBeforeAuth() async throws {
        let server = FakeSMTPServer(offersStartTLS: false)
        let port = try await server.start()
        var failure: SMTPError?
        do {
            try await send(message, to: ["a@example.org"], port: port, security: .startTLS)
        } catch {
            failure = error
        }
        let attempts = await server.authAttempts
        await server.stop()
        #expect(failure == .startTLSNotOffered)
        #expect(attempts == 0)
    }

    @Test func rejectedRecipientThrowsWithCode() async throws {
        let server = FakeSMTPServer(rejectRecipient: "x@example.org")
        let port = try await server.start()
        var failure: SMTPError?
        do {
            try await send(message, to: ["a@example.org", "x@example.org"], port: port)
        } catch {
            failure = error
        }
        let received = await server.received
        await server.stop()
        guard case let .recipientRejected(code, text)? = failure else {
            Issue.record("expected recipientRejected, got \(String(describing: failure))")
            return
        }
        #expect(code == 550)
        #expect(text.count <= 200)
        #expect(received.isEmpty)
    }

    @Test func stripsCrLfFromEnvelope() async throws {
        let server = FakeSMTPServer()
        let port = try await server.start()
        try await send(
            message, from: "a@example.org\r\nRCPT TO:<evil@example.org>", to: ["b@example.org"], port: port)
        let received = await server.received
        await server.stop()
        #expect(received.count == 1)
        #expect(received.first?.to == ["b@example.org"])
    }

    @Test func aQuotedLocalPartGoesInThePathWithItsSpaces() async throws {
        let server = FakeSMTPServer()
        let port = try await server.start()
        try await send(
            message, from: "\"j k\"@example.org", to: ["\"a b\"@example.org", " \"c\\\"d\" @ example.org"], port: port)
        let received = await server.received
        await server.stop()
        #expect(received.first?.from == "\"j k\"@example.org")
        #expect(received.first?.to == ["\"a b\"@example.org", "\"c\\\"d\"@example.org"])
    }

    @Test func aQuotedLocalPartLosesItsLineBreaks() async throws {
        let server = FakeSMTPServer()
        let port = try await server.start()
        try await send(message, to: ["\"a\r\nRCPT TO:<evil@example.org> b\"@example.org"], port: port)
        let received = await server.received
        await server.stop()
        #expect(received.first?.to == ["\"aRCPT TO:<evil@example.org> b\"@example.org"])
    }

    @Test func wrongPasswordIsAuthenticationFailedWithoutThePassword() async throws {
        let server = FakeSMTPServer()
        let port = try await server.start()
        var failure: SMTPError?
        do {
            try await send(message, to: ["a@example.org"], port: port, password: "hunter2-wrong")
        } catch {
            failure = error
        }
        await server.stop()
        #expect(failure == .authenticationFailed)
        #expect(!String(describing: failure).contains("hunter2"))
    }

    @Test func noRecipientsIsRefused() async throws {
        let server = FakeSMTPServer()
        let port = try await server.start()
        var failure: SMTPError?
        do {
            try await send(message, to: [], port: port)
        } catch {
            failure = error
        }
        await server.stop()
        #expect(failure == .noRecipients)
    }

    @Test func aRecipientThatIsNoAddressRefusesTheWholeMessage() async throws {
        let server = FakeSMTPServer()
        let port = try await server.start()
        var failure: SMTPError?
        do {
            try await send(message, to: ["a@example.org", "<\r\n>"], port: port)
        } catch {
            failure = error
        }
        let received = await server.received
        await server.stop()
        #expect(failure == .invalidRecipient)
        #expect(received.isEmpty)
    }

    @Test func signInCheckSendsNoMessage() async throws {
        let server = FakeSMTPServer()
        let port = try await server.start()
        try await SMTPClient.signIn(via: endpoint(port), user: "jk@example.org", password: Secret("secret"))
        let attempts = await server.authAttempts
        let received = await server.received
        await server.stop()
        #expect(attempts == 1)
        #expect(received.isEmpty)
    }

    @Test func signInCheckWithWrongPasswordFails() async throws {
        let server = FakeSMTPServer()
        let port = try await server.start()
        var failure: SMTPError?
        do {
            try await SMTPClient.signIn(via: endpoint(port), user: "jk@example.org", password: Secret("wrong"))
        } catch {
            failure = error
        }
        await server.stop()
        #expect(failure == .authenticationFailed)
    }

    @Test func aRecipientLongerThanAPathRefusesTheWholeMessage() async throws {
        let server = FakeSMTPServer()
        let port = try await server.start()
        var failure: SMTPError?
        do {
            try await send(message, to: ["a@example.org", String(repeating: "a", count: 250) + "@example.org"], port: port)
        } catch {
            failure = error
        }
        let received = await server.received
        await server.stop()
        #expect(failure == .invalidRecipient)
        #expect(received.isEmpty)
    }

    // MARK: - #20: the password is sent as it is, or not at all

    @Test func aPasswordWithALineBreakSignsIn() async throws {
        let server = FakeSMTPServer()
        await server.acceptPassword("se\r\ncret")
        let port = try await server.start()
        try await send(message, to: ["a@example.org"], port: port, password: "se\r\ncret")
        let received = await server.received
        await server.stop()
        #expect(received.count == 1)
    }

    @Test func aPasswordWithNULIsNeverSent() async throws {
        let server = FakeSMTPServer()
        let port = try await server.start()
        await #expect(throws: SMTPError.authenticationFailed) {
            try await send(message, to: ["a@example.org"], port: port, password: "se\0cret")
        }
        let attempts = await server.authAttempts
        await server.stop()
        #expect(attempts == 0)
    }

    @Test func authMethodsAreReadFromEveryEHLOLine() {
        let features: Set = ["FAKE.EXAMPLE", "AUTH=X-UNKNOWN", "AUTH PLAIN LOGIN", "SIZE 1000"]
        #expect(SMTPClient.authMethods(features) == ["X-UNKNOWN", "PLAIN", "LOGIN"])
    }

    @Test func aPasswordWithALineBreakSignsInWithLogin() async throws {
        let server = FakeSMTPServer()
        await server.announce(["fake.example", "AUTH LOGIN"])
        await server.acceptPassword("se\r\ncret")
        let port = try await server.start()
        try await send(message, to: ["a@example.org"], port: port, password: "se\r\ncret")
        let received = await server.received
        await server.stop()
        #expect(received.count == 1)
    }

    @Test func authMethodsOnAnyEHLOLineCount() async throws {
        let server = FakeSMTPServer()
        await server.announce(["fake.example", "AUTH=X-UNKNOWN", "AUTH PLAIN LOGIN"])
        let port = try await server.start()
        try await send(message, to: ["a@example.org"], port: port)
        let received = await server.received
        await server.stop()
        #expect(received.count == 1)
    }

    // MARK: - #25: hostile replies and bare LF

    private func refusal(greeting: [String]) async throws -> SMTPError? {
        let server = FakeSMTPServer()
        await server.greet(with: greeting)
        let port = try await server.start()
        defer { Task { await server.stop() } }
        do {
            try await send(message, to: ["a@example.org"], port: port)
            return nil
        } catch {
            return error
        }
    }

    @Test func aReplyOfMoreThanAHundredLinesIsRefused() async throws {
        let lines = Array(repeating: "220-hello", count: 150) + ["220 ready"]
        #expect(try await refusal(greeting: lines) == .net(.lineTooLong))
    }

    @Test func aReplyWithoutAThreeDigitCodeIsRefused() async throws {
        #expect(try await refusal(greeting: ["2x0 hello"]) == .net(.io("malformed reply")))
        #expect(try await refusal(greeting: ["22"]) == .net(.io("malformed reply")))
    }

    @Test func anOverlongReplyLineIsRefused() async throws {
        #expect(try await refusal(greeting: ["220 " + String(repeating: "x", count: 10_000)]) == .net(.lineTooLong))
    }

    @Test func aMessageWithBareLineFeedsGoesWithCRLF() async throws {
        let server = FakeSMTPServer()
        let port = try await server.start()
        try await send(Data("Subject: x\n\none\n.two\nend".utf8), to: ["a@example.org"], port: port)
        let received = await server.received
        await server.stop()
        #expect(received.first?.data == Data("Subject: x\r\n\r\none\r\n.two\r\nend\r\n".utf8))
    }

    // A server that echoes the AUTH line it refuses never puts the credential in the error.
    @Test func anEchoedAUTHLineStaysOutOfTheError() async throws {
        let listener = FakeListener { connection in
            connection.send(Data("220 ready\r\n".utf8))
            while let raw = await connection.readLine() {
                let line = String(decoding: raw, as: UTF8.self) // swiftlint:disable:this optional_data_string_conversion
                let answer = line.hasPrefix("EHLO") ? "250-fake.example\r\n250 AUTH PLAIN" : "500 5.5.1 Unknown command '\(line)'"
                connection.send(Data((answer + "\r\n").utf8))
            }
        }
        let port = try await listener.start()
        defer { listener.stop() }
        var failure: SMTPError?
        do {
            try await send(message, to: ["a@example.org"], port: port, password: "hunter2")
        } catch {
            failure = error
        }
        let text = String(reflecting: failure)
        #expect(failure != nil)
        #expect(!text.contains("hunter2") && !text.contains("AGprQGV4YW1wbGUub3JnAGh1bnRlcjI"))
    }
}
