// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightFakes
import OutwrightIMAP
import Testing

@Suite struct UIDsAboveTests {
    /// `UID n+1:*` with no message above `n` still matches the last message (the star): it is
    /// left out.
    @Test func uidsAboveExcludesTheStarMessage() async throws {
        let server = FakeIMAPServer()
        for index in 1...3 {
            await server.deliver(Data("Subject: \(index)\r\n\r\nHi\r\n".utf8), to: "INBOX")
        }
        try await withClient(server) { client in
            _ = try await client.select("INBOX")
            #expect(try await client.uids(above: 3) == [])
            #expect(try await client.uids(above: 1) == [2, 3])
            #expect(try await client.uids(above: 0) == [1, 2, 3])
        }
    }

    @Test func uidsAboveMaxUIDIsEmpty() async throws {
        let server = FakeIMAPServer()
        await server.deliver(Data("Subject: a\r\n\r\nHi\r\n".utf8), to: "INBOX")
        try await withClient(server) { client in
            _ = try await client.select("INBOX")
            #expect(try await client.uids(above: UInt32.max) == [])
        }
    }

    @Test func highestUIDIsTheNewestOrNil() async throws {
        let server = FakeIMAPServer()
        try await withClient(server) { client in
            _ = try await client.select("INBOX")
            #expect(try await client.highestUID() == nil)
            for index in 1...3 {
                await server.deliver(Data("Subject: \(index)\r\n\r\nHi\r\n".utf8), to: "INBOX")
            }
            #expect(try await client.highestUID() == 3)
        }
    }
}
