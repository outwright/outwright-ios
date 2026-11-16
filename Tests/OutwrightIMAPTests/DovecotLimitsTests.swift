// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightFakes
import OutwrightIMAP
import OutwrightNet
import Testing

/// The client within Dovecot's limits (`keepDovecotLimits`): command lines under 64 kB however many
/// messages a command names, and what the server offers only once signed in read after the sign-in.
@Suite struct DovecotLimitsTests {
    /// Every other UID up to 40 000: as one set, a line far past 64 kB.
    static let scattered = Array(stride(from: UInt32(1), through: 40_000, by: 2))

    @Test func commandsOnThousandsOfScatteredMessagesStayUnderTheLineLimit() async throws {
        let server = FakeIMAPServer()
        await server.addFolder("Archive", specialUse: "\\Archive")
        await server.keepDovecotLimits()
        try await withClient(server) { client in
            _ = try await client.select("INBOX")
            try await client.setFlags(["\\Seen"], on: Self.scattered, add: true)
            _ = try await client.flags(uids: Self.scattered)
            _ = try await client.presentUIDs(Self.scattered)
            _ = try await client.move(Self.scattered, to: "Archive")
            try await client.expunge(Self.scattered)
        }
    }

    @Test func aLineOverTheLimitIsRefused() async throws {
        // The fake's own check: what the test above stays under is a real limit.
        let server = FakeIMAPServer()
        await server.keepDovecotLimits(lineBytes: 1_000)
        await #expect(throws: IMAPError.self) {
            try await withClient(server) { client in
                _ = try await client.select("INBOX")
                _ = try await client.presentUIDs(Self.scattered)
            }
        }
    }

    @Test func whatTheServerOffersOnlyOnceSignedInIsUsed() async throws {
        let server = FakeIMAPServer()
        await server.addFolder("Archive", specialUse: "\\Archive")
        await server.keepDovecotLimits()
        try await withServer(server) { port in
            let client = try await IMAPClient.connect(endpoint(port))
            #expect(await !client.capabilities.contains("MOVE"))
            try await client.login(user: "jk@example.org", password: Secret("secret"))
            #expect(await client.capabilities.contains("MOVE"))
            let uid = await server.deliver(message("Moved"), to: "INBOX")
            _ = try await client.select("INBOX")
            _ = try await client.move([uid], to: "Archive")
            await client.logout()
        }
        #expect(await server.servedCommands.contains { $0.uppercased().contains("UID MOVE") })
    }

    @Test func aSignInPastTheConnectionLimitIsRefused() async throws {
        // The fake's own check, for the sync's test that the app stays under it.
        let server = FakeIMAPServer()
        await server.keepDovecotLimits(connections: 2)
        try await withServer(server) { port in
            var clients: [IMAPClient] = []
            for _ in 0..<2 {
                let client = try await IMAPClient.connect(endpoint(port))
                try await client.login(user: "jk@example.org", password: Secret("secret"))
                clients.append(client)
            }
            let third = try await IMAPClient.connect(endpoint(port))
            await #expect(throws: IMAPError.self) {
                try await third.login(user: "jk@example.org", password: Secret("secret"))
            }
            for client in clients { await client.logout() }
        }
        #expect(await server.peakSignedIn == 2)
        #expect(await server.limitRefusals == 1)
    }
}
