// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightFakes
import OutwrightIMAP
import OutwrightNet
import Testing

@Suite(.timeLimit(.minutes(1))) struct XOAuth2Tests {
    private let token = "synthetic-access-token-1"

    private func withTokenClient(
        saslIR: Bool = true, _ body: (FakeIMAPServer, IMAPClient) async throws -> Void
    ) async throws {
        let server = FakeIMAPServer()
        await server.acceptToken(token)
        await server.offerSASLIR(saslIR)
        try await withServer(server) { port in
            let client = try await IMAPClient.connect(endpoint(port))
            do {
                try await body(server, client)
            } catch {
                await client.logout()
                throw error
            }
            await client.logout()
        }
    }

    @Test func xoauth2WithSASLIR() async throws {
        try await withTokenClient { server, client in
            #expect(await client.capabilities.contains("SASL-IR"))
            try await client.authenticate(user: "jk@example.org", accessToken: Secret(token))
            #expect(try await client.listFolders().contains { $0.path == "INBOX" })
            let attempts = await server.tokenAttempts
            #expect(attempts.map(\.initialResponse) == [true])
            #expect(attempts.map(\.accepted) == [true])
        }
    }

    @Test func xoauth2WithoutSASLIR() async throws {
        try await withTokenClient(saslIR: false) { server, client in
            #expect(await !client.capabilities.contains("SASL-IR"))
            try await client.authenticate(user: "jk@example.org", accessToken: Secret(token))
            #expect(try await client.listFolders().contains { $0.path == "INBOX" })
            let attempts = await server.tokenAttempts
            #expect(attempts.map(\.initialResponse) == [false])
            #expect(attempts.map(\.accepted) == [true])
        }
    }

    @Test(arguments: [true, false]) func wrongTokenIsAuthenticationFailed(saslIR: Bool) async throws {
        try await withTokenClient(saslIR: saslIR) { server, client in
            await #expect(throws: IMAPError.authenticationFailed) {
                try await client.authenticate(user: "jk@example.org", accessToken: Secret("expired-token"))
            }
            // The challenge was answered and the command ended: the connection is still in step.
            try await client.authenticate(user: "jk@example.org", accessToken: Secret(token))
            #expect(try await client.listFolders().contains { $0.path == "INBOX" })
            #expect(await server.tokenAttempts.map(\.accepted) == [false, true])
        }
    }

    @Test func tokenNeverEchoed() async throws {
        try await withTokenClient { _, client in
            let wrong = "wrong-token-that-must-not-leak"
            do {
                try await client.authenticate(user: "jk@example.org", accessToken: Secret(wrong))
                Issue.record("a wrong token signed in")
            } catch {
                #expect(!"\(error)".contains(wrong))
                #expect(!String(reflecting: error).contains(wrong))
                #expect(!error.localizedDescription.contains(wrong))
            }
        }
    }

    @Test func lineBreaksNeverReachTheWire() async throws {
        try await withTokenClient { server, client in
            await #expect(throws: IMAPError.authenticationFailed) {
                try await client.authenticate(user: "jk@example.org", accessToken: Secret("abc\r\nA1 LOGOUT"))
            }
            #expect(await server.tokenAttempts.isEmpty)
            // CR, LF and NUL are taken out of the user before the string is built.
            try await client.authenticate(user: "jk@exa\r\nmple.org\0", accessToken: Secret(token))
            #expect(await server.tokenAttempts.map(\.user) == ["jk@example.org"])
        }
    }

    @Test func passwordLoginUnchanged() async throws {
        try await withTokenClient { _, client in
            try await client.login(user: "jk@example.org", password: Secret("secret"))
            #expect(try await client.listFolders().contains { $0.path == "INBOX" })
        }
    }
}
