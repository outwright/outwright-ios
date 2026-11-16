// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightFakes
import OutwrightNet
import OutwrightSMTP
import Testing

@Suite(.timeLimit(.minutes(1))) struct XOAuth2Tests {
    private let message = Data("From: jk@example.org\r\nTo: a@example.org\r\nSubject: Hi\r\n\r\nHello\r\n".utf8)
    private let token = "synthetic-access-token-1"

    private func withServer(_ body: (FakeSMTPServer, ServerEndpoint) async throws -> Void) async throws {
        let server = FakeSMTPServer()
        await server.acceptToken(token)
        let port = try await server.start()
        do {
            try await body(server, ServerEndpoint(host: "127.0.0.1", port: port, security: .plainLoopbackOnly))
        } catch {
            await server.stop()
            throw error
        }
        await server.stop()
    }

    private func send(_ endpoint: ServerEndpoint, _ credential: SMTPCredential) async throws(SMTPError) {
        try await SMTPClient.send(
            message, envelopeFrom: "jk@example.org", recipients: ["a@example.org"], via: endpoint,
            user: "jk@example.org", credential: credential)
    }

    @Test func xoauth2Sends() async throws {
        try await withServer { server, endpoint in
            try await send(endpoint, .accessToken(Secret(token)))
            #expect(await server.received.map(\.data) == [message])
            #expect(await server.tokenAttempts.map(\.accepted) == [true])
            try await SMTPClient.signIn(via: endpoint, user: "jk@example.org", credential: .accessToken(Secret(token)))
        }
    }

    @Test func wrongTokenFailsAuthentication() async throws {
        try await withServer { server, endpoint in
            let wrong = "expired-token-must-not-leak"
            do throws(SMTPError) {
                try await send(endpoint, .accessToken(Secret(wrong)))
                Issue.record("a wrong token sent mail")
            } catch {
                #expect(error == .authenticationFailed)
                #expect(!"\(error)".contains(wrong))
                #expect(!String(reflecting: error).contains(wrong))
            }
            #expect(await server.received.isEmpty)
            // The 334 challenge was answered: the server got to its 535.
            #expect(await server.tokenAttempts.map(\.accepted) == [false])
        }
    }

    @Test func lineBreakInTokenIsRefusedBeforeSending() async throws {
        try await withServer { server, endpoint in
            await #expect(throws: SMTPError.authenticationFailed) {
                try await send(endpoint, .accessToken(Secret("abc\r\nMAIL FROM:<x@example.org>")))
            }
            #expect(await server.tokenAttempts.isEmpty)
            #expect(await server.received.isEmpty)
        }
    }

    @Test func passwordPathUnchanged() async throws {
        try await withServer { server, endpoint in
            try await send(endpoint, .password(Secret("secret")))
            try await SMTPClient.send(
                message, envelopeFrom: "jk@example.org", recipients: ["a@example.org"], via: endpoint,
                user: "jk@example.org", password: Secret("secret"))
            #expect(await server.received.count == 2)
            #expect(await server.tokenAttempts.isEmpty)
            await #expect(throws: SMTPError.authenticationFailed) { try await send(endpoint, .password(Secret("wrong"))) }
        }
    }
}
