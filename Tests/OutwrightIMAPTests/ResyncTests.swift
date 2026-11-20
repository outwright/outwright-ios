// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightFakes
import OutwrightNet
import Testing
@testable import OutwrightIMAP

/// CONDSTORE and QRESYNC (RFC 7162) against the fake server.
@Suite struct ResyncTests {
    /// QRESYNC is turned on after any sign-in, an access token's as much as a password's.
    @Test func anOAuthSignInEnablesQResyncToo() async throws {
        let server = FakeIMAPServer()
        await server.acceptToken("synthetic-access-token-1")
        try await withServer(server) { port in
            let client = try await IMAPClient.connect(endpoint(port))
            try await client.authenticate(user: "jk@example.org", accessToken: Secret("synthetic-access-token-1"))
            #expect(await client.resyncMode == .qresync)
            await client.logout()
        }
    }

    @Test func enablesQResyncWhenOffered() async throws {
        try await withClient(FakeIMAPServer()) { client in
            #expect(await client.resyncMode == .qresync)
        }
        let condstore = FakeIMAPServer()
        await condstore.offerCondstoreOnly()
        try await withClient(condstore) { client in
            #expect(await client.resyncMode == .condstore)
        }
        let neither = FakeIMAPServer()
        await neither.offerNoCondstore()
        try await withClient(neither) { client in
            #expect(await client.resyncMode == ResyncMode.none)
        }
        #expect(await !neither.servedCommands.contains { $0.contains("ENABLE") })
    }

    @Test func selectReportsHighestModSeq() async throws {
        let server = FakeIMAPServer()
        await server.deliver(message("one"), to: "INBOX")
        try await withClient(server) { client in
            let highest = await server.highestModSeq("INBOX")
            let status = try await client.select("INBOX")
            #expect(status.highestModSeq == highest)
            await server.withholdModSeq("INBOX")
            let withheld = try await client.select("INBOX")
            #expect(withheld.highestModSeq == nil)
        }
    }

    @Test func qresyncSelectBringsChangesSincePoint() async throws {
        let server = FakeIMAPServer()
        for subject in ["a", "b", "c"] {
            await server.deliver(message(subject), to: "INBOX")
        }
        try await withClient(server) { client in
            let mark = try #require(try await client.select("INBOX").highestModSeq)
            try await client.setFlags(["\\Seen"], on: [1], add: true)
            try await client.setFlags(["\\Deleted"], on: [2], add: true)
            try await client.expunge([2])
            let point = QResyncPoint(uidValidity: 1, modSeq: mark, known: 1...3)
            let (status, changes) = try await client.select("INBOX", from: point)
            let highest = await server.highestModSeq("INBOX")
            #expect(status.highestModSeq == highest)
            #expect(changes?.flags == [1: ["\\Seen"]])
            #expect(changes?.vanished.flatMap { Array($0) } == [2])
        }
    }

    /// Stalwart v0.16 says what changed before `[CLOSED]` when another folder is selected: the
    /// folder is left first (UNSELECT), so nothing is said of one before the other.
    @Test func changesSaidBeforeClosedStillCome() async throws {
        let server = FakeIMAPServer()
        await server.answerResyncBeforeClosed()
        for subject in ["a", "b", "c"] {
            await server.deliver(message(subject), to: "INBOX")
        }
        try await withClient(server) { client in
            let mark = try #require(try await client.select("INBOX").highestModSeq)
            try await client.setFlags(["\\Seen"], on: [1], add: true)
            try await client.setFlags(["\\Deleted"], on: [2], add: true)
            try await client.expunge([2])
            let point = QResyncPoint(uidValidity: 1, modSeq: mark, known: 1...3)
            let (_, changes) = try await client.select("INBOX", from: point)
            #expect(changes?.flags == [1: ["\\Seen"]])
            #expect(changes?.vanished.flatMap { Array($0) } == [2])
        }
    }

    /// Without UNSELECT a folder already selected cannot be left without a `[CLOSED]`, so no
    /// point is asked from: the answer says so, and the caller reconciles another way.
    @Test func withoutUnselectNoPointIsAskedFromASelectedFolder() async throws {
        let server = FakeIMAPServer()
        await server.answerResyncBeforeClosed()
        await server.withholdUnselect()
        await server.deliver(message("a"), to: "INBOX")
        try await withClient(server) { client in
            let mark = try #require(try await client.select("INBOX").highestModSeq)
            let point = QResyncPoint(uidValidity: 1, modSeq: mark, known: 1...1)
            let (_, changes) = try await client.select("INBOX", from: point)
            #expect(changes == nil)
        }
    }

    @Test func qresyncSelectKeepsToTheKnownRange() async throws {
        let server = FakeIMAPServer()
        for subject in ["a", "b", "c"] {
            await server.deliver(message(subject), to: "INBOX")
        }
        try await withClient(server) { client in
            let mark = try #require(try await client.select("INBOX").highestModSeq)
            try await client.setFlags(["\\Seen"], on: [1, 3], add: true)
            let point = QResyncPoint(uidValidity: 1, modSeq: mark, known: 2...3)
            let (_, changes) = try await client.select("INBOX", from: point)
            #expect(changes?.flags == [3: ["\\Seen"]])
        }
    }

    @Test func aPlainSelectBringsNoChanges() async throws {
        let server = FakeIMAPServer()
        await server.deliver(message("a"), to: "INBOX")
        try await withClient(server) { client in
            let (status, changes) = try await client.select("INBOX", from: nil)
            #expect(status.highestModSeq != nil)
            #expect(changes == nil)
        }
    }

    @Test func changedFlagsReturnsOnlyChanged() async throws {
        let server = FakeIMAPServer()
        await server.offerCondstoreOnly()
        for subject in ["a", "b", "c"] {
            await server.deliver(message(subject), to: "INBOX")
        }
        try await withClient(server) { client in
            let mark = try #require(try await client.select("INBOX").highestModSeq)
            try await client.setFlags(["\\Flagged"], on: [2], add: true)
            #expect(try await client.changedFlags(since: mark) == [2: ["\\Flagged"]])
        }
    }

    @Test func changedFlagsKeepsToTheSpanGiven() async throws {
        let server = FakeIMAPServer()
        await server.offerCondstoreOnly()
        for subject in ["a", "b", "c"] {
            await server.deliver(message(subject), to: "INBOX")
        }
        try await withClient(server) { client in
            let mark = try #require(try await client.select("INBOX").highestModSeq)
            try await client.setFlags(["\\Flagged"], on: [1, 3], add: true)
            #expect(try await client.changedFlags(since: mark, within: 2...3) == [3: ["\\Flagged"]])
        }
    }

    @Test func presentUIDsOmitsExpunged() async throws {
        let server = FakeIMAPServer()
        for subject in ["a", "b", "c"] {
            await server.deliver(message(subject), to: "INBOX")
        }
        try await withClient(server) { client in
            _ = try await client.select("INBOX")
            try await client.setFlags(["\\Deleted"], on: [2], add: true)
            try await client.expunge([2])
            #expect(try await client.presentUIDs([1, 2, 3]) == [1, 3])
            #expect(try await client.presentUIDs([]).isEmpty)
        }
    }

    @Test func uidRangesReadsSetsAndRanges() {
        #expect(IMAPClient.uidRanges("1,3:5,9") == [1...1, 3...5, 9...9])
        #expect(IMAPClient.uidRanges("5:3") == [3...5])
        #expect(IMAPClient.uidRanges("1:4294967295") == [1...4_294_967_295])
        for bad in ["0", "1:*", "", "1,,2", "a", "1:2:3", "4294967296", "-1"] {
            #expect(IMAPClient.uidRanges(Substring(bad)) == nil, "\(bad)")
        }
        let many = (1...10_001).map { String($0 * 2) }.joined(separator: ",")
        #expect(IMAPClient.uidRanges(Substring(many)) == nil)
    }

    @Test func highestModSeqParsesTwentyDigitsAtMost() throws {
        func status(_ code: String) throws -> FolderStatus {
            let lines = ["* OK [UIDVALIDITY 7] v", "* OK [\(code)] m"]
            return try IMAPClient.status(of: lines.map { try IMAPParser.parse(Data($0.utf8)) })
        }
        #expect(try status("HIGHESTMODSEQ 18446744073709551615").highestModSeq == UInt64.max)
        #expect(try status("HIGHESTMODSEQ 18446744073709551616").highestModSeq == nil)
        #expect(try status("HIGHESTMODSEQ 000000000000000000001").highestModSeq == nil)
        #expect(try status("HIGHESTMODSEQ x").highestModSeq == nil)
        #expect(try status("NOMODSEQ").highestModSeq == nil)
    }

    @Test func uidRangesNeverTrapsOnArbitraryBytes() {
        var generator = SplitMix64(seed: 0x7162)
        let alphabet = Array("0123456789:,*  ".utf8)
        for _ in 0..<5000 {
            let length = Int.random(in: 0..<60, using: &generator)
            let noise = (0..<length).map { _ in
                Bool.random(using: &generator)
                    ? alphabet[Int.random(in: 0..<alphabet.count, using: &generator)]
                    : UInt8.random(in: 0...255, using: &generator)
            }
            // swiftlint:disable:next optional_data_string_conversion
            let text = String(decoding: noise, as: UTF8.self)
            if let ranges = IMAPClient.uidRanges(Substring(text)) {
                #expect(ranges.allSatisfy { $0.lowerBound > 0 })
            }
        }
    }

    @Test func resyncChangesNeverTrapsOnArbitraryResponses() {
        var generator = SplitMix64(seed: 0x7164)
        let alphabet = Array("0123456789:,* ()UIDFLAGSMODSEQEARLIER\\Seen".utf8)
        for _ in 0..<5000 {
            let length = Int.random(in: 0..<80, using: &generator)
            let noise = (0..<length).map { _ in
                Bool.random(using: &generator)
                    ? alphabet[Int.random(in: 0..<alphabet.count, using: &generator)]
                    : UInt8.random(in: 0...255, using: &generator)
            }
            let prefix = Bool.random(using: &generator) ? "* VANISHED " : "* 3 FETCH "
            if let response = try? IMAPParser.parse(Data(prefix.utf8) + Data(noise)) {
                _ = IMAPClient.resyncChanges([response])
            }
        }
    }

    @Test func selectStatusNeverTrapsOnArbitraryCodes() {
        var generator = SplitMix64(seed: 0x7163)
        let alphabet = Array("0123456789 HIGHESTMODSEQNOMODSEQUIDVALIDITY[]".utf8)
        for _ in 0..<5000 {
            let length = Int.random(in: 0..<60, using: &generator)
            let noise = (0..<length).map { _ in
                Bool.random(using: &generator)
                    ? alphabet[Int.random(in: 0..<alphabet.count, using: &generator)]
                    : UInt8.random(in: 0...255, using: &generator)
            }
            let line = Data("* OK [".utf8) + Data(noise) + Data("] x".utf8)
            if let response = try? IMAPParser.parse(line) {
                _ = try? IMAPClient.status(of: [response])
                _ = IMAPClient.resyncChanges([response])
            }
        }
    }
}
