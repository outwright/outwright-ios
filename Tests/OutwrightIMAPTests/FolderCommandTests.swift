// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightFakes
import Testing
@testable import OutwrightIMAP

@Suite struct FolderCommandTests {
    @Test func renameMovesTheFolderAndItsSubfolders() async throws {
        let server = FakeIMAPServer()
        await server.addFolder("Projects", specialUse: nil)
        await server.addFolder("Projects/2026", specialUse: nil)
        await server.addFolder("ProjectsOld", specialUse: nil)
        try await withClient(server) { client in
            try await client.rename(from: "Projects", to: "Work")
        }
        let paths = await server.folderPaths()
        #expect(paths.contains("Work"))
        #expect(paths.contains("Work/2026"))
        #expect(!paths.contains("Projects"))
        #expect(!paths.contains("Projects/2026"))
        // Only what is under the folder follows it, not a sibling sharing its prefix.
        #expect(paths.contains("ProjectsOld"))
    }

    @Test func renameWritesUTF7() async throws {
        let server = FakeIMAPServer()
        await server.addFolder("A", specialUse: nil)
        try await withClient(server) { client in
            try await client.rename(from: "A", to: ModifiedUTF7.encode("R&D Ö"))
            let listed = try await client.listFolders()
            #expect(listed.contains { $0.name == "R&D Ö" })
        }
    }

    @Test func createByPathSendsThePathAsItIs() async throws {
        let server = FakeIMAPServer()
        try await withClient(server) { client in
            try await client.create(path: ModifiedUTF7.encode("Kvitton & Öre"))
            let listed = try await client.listFolders()
            #expect(listed.contains { $0.name == "Kvitton & Öre" })
        }
    }

    @Test func renameOntoAnExistingFolderIsRefused() async throws {
        let server = FakeIMAPServer()
        await server.addFolder("A", specialUse: nil)
        await server.addFolder("B", specialUse: nil)
        try await withClient(server) { client in
            await #expect(throws: IMAPError.self) { try await client.rename(from: "A", to: "B") }
        }
    }

    @Test func deleteRemovesTheFolder() async throws {
        let server = FakeIMAPServer()
        await server.addFolder("Old", specialUse: nil)
        try await withClient(server) { client in
            try await client.delete("Old")
        }
        #expect(await !server.folderPaths().contains("Old"))
    }

    @Test func deleteOfAMissingFolderIsNoFailure() async throws {
        try await withClient(FakeIMAPServer()) { client in
            try await client.delete("Nope")
        }
    }

    @Test func deleteRefusedThrowsNo() async throws {
        let server = FakeIMAPServer()
        await server.addFolder("Keep", specialUse: nil)
        await server.refuse("DELETE", path: "Keep")
        try await withClient(server) { client in
            await #expect {
                try await client.delete("Keep")
            } throws: { error in
                if case IMAPError.no = error { true } else { false }
            }
        }
        #expect(await server.folderPaths().contains("Keep"))
    }

    @Test func aFolderInUseIsWorthAskingAgain() async throws {
        let server = FakeIMAPServer()
        await server.addFolder("Old", specialUse: nil)
        await server.refuseFoldersInUse()
        try await withClient(server) { client in
            _ = try await client.select("Old")
            await #expect {
                try await client.delete("Old")
            } throws: { error in
                if case IMAPError.unavailable = error { true } else { false }
            }
        }
    }

    @Test func subscribeAndUnsubscribe() async throws {
        let server = FakeIMAPServer()
        await server.addFolder("News", specialUse: nil)
        try await withClient(server) { client in
            try await client.subscribe("News")
            #expect(await server.subscribedPaths().contains("News"))
            try await client.unsubscribe("News")
            #expect(await !server.subscribedPaths().contains("News"))
        }
    }

    @Test func subscribedFoldersReadsLSUB() async throws {
        let server = FakeIMAPServer()
        await server.addFolder("News", specialUse: nil)
        await server.addFolder("Old", specialUse: nil)
        try await withClient(server) { client in
            try await client.subscribe("News")
            let subscribed = try await client.subscribedFolders()
            #expect(subscribed == ["News"])
        }
    }

    @Test func messageCountReadsStatus() async throws {
        let server = FakeIMAPServer()
        await server.addFolder("Box", specialUse: nil)
        for subject in ["one", "two", "three"] {
            await server.deliver(message(subject), to: "Box")
        }
        try await withClient(server) { client in
            let count = try await client.messageCount("Box")
            #expect(count == 3)
        }
    }

    @Test func statusOverArbitraryBytesNeverTraps() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<2_000 {
            let length = Int.random(in: 0...80, using: &generator)
            var bytes = Array("* STATUS ".utf8)
            bytes += (0..<length).map { _ in UInt8.random(in: 0...255, using: &generator) }
            guard let response = try? IMAPParser.parse(Data(bytes)) else { continue }
            _ = try? IMAPClient.messageCount(of: [response])
        }
        #expect(throws: IMAPError.self) { try IMAPClient.messageCount(of: []) }
        let huge = IMAPResponse.data(
            number: nil, keyword: "STATUS",
            values: [.atom("Box"), .list([.atom("MESSAGES"), .atom("99999999999999999999999")])])
        #expect(throws: IMAPError.self) { try IMAPClient.messageCount(of: [huge]) }
    }
}
