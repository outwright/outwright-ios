// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
@testable import OutwrightIMAP
import OutwrightFakes
import Testing

/// The server's identity (IMAP ID, RFC 2971).
@Suite struct IDTests {
    @Test func serverNamesItself() async throws {
        let server = FakeIMAPServer()
        await server.identify(as: ["name": "Dovecot", "version": "2.4.1"])
        try await withClient(server) { client in
            let fields = try await client.serverID()
            #expect(fields == ["name": "Dovecot", "version": "2.4.1"])
        }
    }

    @Test func withoutIDCapabilityNothingIsAsked() async throws {
        let server = FakeIMAPServer()
        try await withClient(server) { client in
            let fields = try await client.serverID()
            #expect(fields.isEmpty)
        }
        #expect(await server.idRequests == 0)
    }

    @Test func idNilIsEmpty() throws {
        let response = try IMAPParser.parse(Data("* ID NIL".utf8))
        #expect(IMAPParser.idFields(from: [response]) == [:])
    }

    @Test func idAnswersNeverTrap() {
        var generator = SplitMix64(seed: 0x1D_2971)
        let alphabet = Array("* ID ()\"NIL name Dovecot{}\\\r\n0123456789".utf8)
        for _ in 0..<3000 {
            let length = Int.random(in: 0..<120, using: &generator)
            let noise = (0..<length).map { _ in
                Bool.random(using: &generator)
                    ? alphabet[Int.random(in: 0..<alphabet.count, using: &generator)]
                    : UInt8.random(in: 0...255, using: &generator)
            }
            for line in [Data(noise), Data("* ID (".utf8) + Data(noise)] {
                if let response = try? IMAPParser.parse(line) {
                    _ = IMAPParser.idFields(from: [response])
                }
            }
        }
    }
}
