// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
@testable import OutwrightIMAP
import OutwrightFakes
import Synchronization
import Testing

@Suite struct MetadataTests {
    static let entry = "/private/vendor/vendor.example/a"

    @Test func setThenGetRoundTrips() async throws {
        let server = FakeIMAPServer()
        await server.offerMetadata(true)
        try await withClient(server) { client in
            #expect(await client.offersServerMetadata)
            try await client.setServerMetadata([Self.entry: "x"])
            #expect(try await client.serverMetadata([Self.entry]) == [Self.entry: "x"])
        }
        #expect(await server.serverMetadata == [Self.entry: "x"])
    }

    @Test func nilRemoves() async throws {
        let server = FakeIMAPServer()
        await server.offerMetadata(true)
        try await withClient(server) { client in
            try await client.setServerMetadata([Self.entry: "x"])
            try await client.setServerMetadata([Self.entry: nil])
            #expect(try await client.serverMetadata([Self.entry]) == [:])
        }
    }

    @Test func depthInfinityListsUnderPrefix() async throws {
        let server = FakeIMAPServer()
        await server.offerMetadata(true)
        let prefix = "/private/vendor/vendor.example/push"
        try await withClient(server) { client in
            try await client.setServerMetadata([
                prefix + "/one": "1", prefix + "/two": "2", "/private/vendor/vendor.example/other": "3"
            ])
            #expect(try await client.metadataEntries(under: prefix) == [prefix + "/one": "1", prefix + "/two": "2"])
        }
    }

    @Test func refusedWithoutCapability() async throws {
        let server = FakeIMAPServer()
        try await withClient(server) { client in
            #expect(await !client.offersServerMetadata)
            await #expect(throws: IMAPError.extensionMissing) {
                try await client.setServerMetadata([Self.entry: "x"])
            }
        }
    }

    @Test func refusedWriteIsNo() async throws {
        let server = FakeIMAPServer()
        await server.offerMetadata(true)
        await server.refuseMetadataWrites()
        try await withClient(server) { client in
            await #expect {
                try await client.setServerMetadata([Self.entry: "x"])
            } throws: { error in
                if case .no = error as? IMAPError { true } else { false }
            }
        }
    }

    @Test func appendHookSeesInboxAppend() async throws {
        let server = FakeIMAPServer()
        let seen = Mutex<[String]>([])
        await server.onAppend { path, data in
            seen.withLock { $0.append(path + ":" + (String(bytes: data, encoding: .utf8) ?? "")) }
        }
        try await withClient(server) { client in
            _ = try await client.append(Data("Subject: hi\r\n\r\nx\r\n".utf8), to: "INBOX", flags: [])
        }
        #expect(seen.withLock { $0 } == ["INBOX:Subject: hi\r\n\r\nx\r\n"])
    }

    @Test func metadataAnswersNeverTrap() {
        var generator = SplitMix64(seed: 0x00ED_A7A)
        let alphabet = Array("* METADATA \"\" ()/{}\\\r\n0123456789NIL/private".utf8)
        for _ in 0..<3000 {
            let length = Int.random(in: 0..<120, using: &generator)
            let noise = (0..<length).map { _ in
                Bool.random(using: &generator)
                    ? alphabet[Int.random(in: 0..<alphabet.count, using: &generator)]
                    : UInt8.random(in: 0...255, using: &generator)
            }
            for line in [Data(noise), Data("* METADATA \"\" (".utf8) + Data(noise)] {
                if let response = try? IMAPParser.parse(line) {
                    _ = IMAPParser.metadataEntries(from: [response])
                }
            }
        }
    }

    @Test func metadataEntriesSkipNilAndNonText() throws {
        let lines = [
            "* METADATA \"\" (/private/a \"1\" /private/b NIL)",
            "* METADATA \"INBOX\" (/private/c \"2\")",
            "* METADATA \"\" (/private/d)"
        ]
        let responses = try lines.map { line throws(IMAPError) in try IMAPParser.parse(Data(line.utf8)) }
        #expect(IMAPParser.metadataEntries(from: responses) == ["/private/a": "1"])
    }

    @Test func passingNoIsUnavailableAndOtherNoIsNo() async throws {
        let server = FakeIMAPServer()
        await server.offerMetadata(true)
        try await withClient(server) { client in
            await server.failMetadata(with: "[UNAVAILABLE] Try again later")
            await #expect(throws: IMAPError.unavailable("Try again later")) {
                try await client.setServerMetadata([Self.entry: "x"])
            }
            await server.failMetadata(with: "[NOPERM] Not yours")
            await #expect(throws: IMAPError.no("Not yours")) {
                try await client.setServerMetadata([Self.entry: "x"])
            }
        }
    }
}
