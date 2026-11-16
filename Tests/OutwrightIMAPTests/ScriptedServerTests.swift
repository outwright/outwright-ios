// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightFakes
import OutwrightNet
import Testing
@testable import OutwrightIMAP

/// A server that says `greeting` and answers each command line with what `respond` gives for
/// its tag and line. It sees what a client sends but keeps no mailbox.
private func scripted(
    greeting: [String],
    _ respond: @escaping @Sendable (_ tag: String, _ line: String) -> [String] = { tag, _ in ["\(tag) OK done"] }
) async throws -> (FakeListener, UInt16) {
    let listener = FakeListener { connection in
        for line in greeting {
            connection.send(Data((line + "\r\n").utf8))
        }
        while let line = await connection.readLine() {
            let text = String(decoding: line, as: UTF8.self)
            let tag = String(text.prefix { $0 != " " })
            for answer in respond(tag, text) {
                connection.send(Data((answer + "\r\n").utf8))
            }
        }
    }
    return (listener, try await listener.start())
}

private let quick = IMAPClient.Timing(perRead: .seconds(2), response: .seconds(2))

@Suite struct ScriptedServerTests {
    @Test func literalMarkInStatusTextIsNotRead() async throws {
        let (listener, port) = try await scripted(greeting: ["* OK [CAPABILITY IMAP4rev1] Ready {5}"]) { tag, line in
            line.contains("LOGIN") ? ["\(tag) OK [CAPABILITY IMAP4rev1] Welcome {3}"] : ["* OK [ALERT] mind {9}", "\(tag) OK done"]
        }
        defer { listener.stop() }
        let client = try await IMAPClient.connect(endpoint(port), timing: quick)
        try await client.login(user: "jk@example.org", password: Secret("secret"))
        #expect(try await client.listFolders().isEmpty)
        await client.logout()
    }

    @Test func drippingServerTimesOut() async throws {
        let listener = FakeListener { connection in
            for byte in Array("* OK this greeting never ends ".utf8) + Array(repeating: UInt8(ascii: "."), count: 200) {
                connection.send(Data([byte]))
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        defer { listener.stop() }
        let port = try await listener.start()
        let start = ContinuousClock.now
        await #expect(throws: IMAPError.net(.timeout)) {
            _ = try await IMAPClient.connect(endpoint(port), timing: IMAPClient.Timing(perRead: .seconds(5), response: .seconds(1)))
        }
        #expect(ContinuousClock.now - start < .seconds(4))
    }

    @Test func protocolViolationBreaksTheClient() async throws {
        let (listener, port) = try await scripted(greeting: ["* OK [CAPABILITY IMAP4rev1] Ready"]) { tag, line in
            line.contains("SELECT") ? [")))"] : ["\(tag) OK done"]
        }
        defer { listener.stop() }
        let client = try await IMAPClient.connect(endpoint(port), timing: quick)
        try await client.login(user: "jk@example.org", password: Secret("secret"))
        await #expect(throws: IMAPError.protocolViolation) {
            _ = try await client.select("INBOX")
        }
        await #expect(throws: IMAPError.net(.closed)) {
            _ = try await client.listFolders()
        }
        await client.logout()
    }

    @Test func responsesForOneCommandAreCappedInTotal() async throws {
        let filler = "* OK " + String(repeating: "x", count: 1_000_000)
        let (listener, port) = try await scripted(greeting: ["* OK [CAPABILITY IMAP4rev1] Ready"]) { tag, line in
            line.contains("SEARCH") ? Array(repeating: filler, count: 12) + ["\(tag) OK done"] : ["\(tag) OK done"]
        }
        defer { listener.stop() }
        var timing = IMAPClient.Timing(perRead: .seconds(10), response: .seconds(10))
        timing.commandTotal = 8 << 20
        let client = try await IMAPClient.connect(endpoint(port), timing: timing)
        try await client.login(user: "jk@example.org", password: Secret("secret"))
        await #expect(throws: IMAPError.protocolViolation) {
            _ = try await client.uids(since: .distantPast)
        }
        await #expect(throws: IMAPError.net(.closed)) {
            _ = try await client.listFolders()
        }
        await client.logout()
    }

    @Test func selectTellsAMissingFolderFromOtherRefusals() async throws {
        let (listener, port) = try await scripted(greeting: ["* OK [CAPABILITY IMAP4rev1] Ready"]) { tag, line in
            if line.contains("SELECT \"Locked\"") {
                return ["\(tag) NO Mailbox is locked"]
            }
            if line.contains("SELECT") {
                return ["\(tag) NO [NONEXISTENT] Unknown mailbox"]
            }
            return ["\(tag) OK done"]
        }
        defer { listener.stop() }
        let client = try await IMAPClient.connect(endpoint(port), timing: quick)
        try await client.login(user: "jk@example.org", password: Secret("secret"))
        await #expect(throws: IMAPError.no("Mailbox is locked")) {
            _ = try await client.select("Locked")
        }
        await #expect(throws: IMAPError.folderMissing("Gone")) {
            _ = try await client.select("Gone")
        }
        await client.logout()
    }

    @Test func pollingIdleEndsPromptlyWhenCancelled() async throws {
        let (listener, port) = try await scripted(greeting: ["* OK [CAPABILITY IMAP4rev1] Ready"])
        defer { listener.stop() }
        let client = try await IMAPClient.connect(endpoint(port), timing: quick)
        try await client.login(user: "jk@example.org", password: Secret("secret"))
        let start = ContinuousClock.now
        let idle = Task { try await client.idle(timeout: .seconds(60)) }
        idle.cancel()
        #expect(try await idle.value == false)
        #expect(ContinuousClock.now - start < .seconds(5))
        await client.logout()
    }

    /// A cancel that comes before the server has started IDLE (no `+` yet) ends the wait at once;
    /// the connection, out of step, is closed.
    @Test func idleCancelledBeforeTheServerStartsItEndsAtOnce() async throws {
        let (listener, port) = try await scripted(greeting: ["* OK [CAPABILITY IMAP4rev1 IDLE] Ready"]) { tag, line in
            line.contains("IDLE") || line == "DONE" ? [] : ["\(tag) OK done"]
        }
        defer { listener.stop() }
        let client = try await IMAPClient.connect(endpoint(port), timing: IMAPClient.Timing(perRead: .seconds(60)))
        try await client.login(user: "jk@example.org", password: Secret("secret"))
        let idle = Task { try await client.idle(timeout: .seconds(60)) }
        try await Task.sleep(for: .milliseconds(300))
        let start = ContinuousClock.now
        idle.cancel()
        _ = await idle.result
        #expect(ContinuousClock.now - start < .seconds(5))
        await #expect(throws: IMAPError.net(.closed)) { _ = try await client.listFolders() }
    }

    /// A server that keeps talking but never ends the IDLE after DONE is given up on once the
    /// timeout and the grace after it have passed, however often it speaks.
    @Test func idleHasADeadlineAsAWhole() async throws {
        let listener = FakeListener { connection in
            connection.send(Data("* OK [CAPABILITY IMAP4rev1 IDLE] Ready\r\n".utf8))
            while let line = await connection.readLine() {
                let text = String(decoding: line, as: UTF8.self)
                let tag = String(text.prefix { $0 != " " })
                guard text.contains("IDLE") else {
                    connection.send(Data("\(tag) OK done\r\n".utf8))
                    continue
                }
                connection.send(Data("+ idling\r\n".utf8))
                for _ in 0..<600 {
                    connection.send(Data("* OK still here\r\n".utf8))
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
        }
        defer { listener.stop() }
        let port = try await listener.start()
        let timing = IMAPClient.Timing(perRead: .seconds(2), response: .seconds(2), idleGrace: .seconds(1))
        let client = try await IMAPClient.connect(endpoint(port), timing: timing)
        try await client.login(user: "jk@example.org", password: Secret("secret"))
        let start = ContinuousClock.now
        await #expect(throws: IMAPError.net(.timeout)) { _ = try await client.idle(timeout: .milliseconds(300)) }
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    /// What arrives during one IDLE is capped in total, as it is for any other command.
    @Test func responsesDuringIdleAreCappedInTotal() async throws {
        let filler = "* OK " + String(repeating: "x", count: 1_000_000)
        let (listener, port) = try await scripted(greeting: ["* OK [CAPABILITY IMAP4rev1 IDLE] Ready"]) { tag, line in
            if line.contains("IDLE") {
                return ["+ idling"] + Array(repeating: filler, count: 12)
            }
            return line == "DONE" ? [] : ["\(tag) OK done"]
        }
        defer { listener.stop() }
        var timing = quick
        timing.commandTotal = 8 << 20
        let client = try await IMAPClient.connect(endpoint(port), timing: timing)
        try await client.login(user: "jk@example.org", password: Secret("secret"))
        await #expect(throws: IMAPError.protocolViolation) { _ = try await client.idle(timeout: .seconds(30)) }
    }

    /// A cancel after DONE was sent, to a server that went silent, gives the answer two seconds
    /// and then closes the connection rather than waiting out the IDLE's deadline.
    @Test func idleCancelledAfterDoneToASilentServerEndsSoon() async throws {
        let (listener, port) = try await scripted(greeting: ["* OK [CAPABILITY IMAP4rev1 IDLE] Ready"]) { tag, line in
            if line.contains("IDLE") {
                return ["+ idling", "* 1 EXISTS"]
            }
            return line == "DONE" ? [] : ["\(tag) OK done"]
        }
        defer { listener.stop() }
        let client = try await IMAPClient.connect(endpoint(port), timing: IMAPClient.Timing(perRead: .seconds(60)))
        try await client.login(user: "jk@example.org", password: Secret("secret"))
        let idle = Task { try await client.idle(timeout: .seconds(60)) }
        try await Task.sleep(for: .milliseconds(300))
        let start = ContinuousClock.now
        idle.cancel()
        _ = await idle.result
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    /// The two seconds after a cancel are for the answer to DONE: a server slow with its `+`
    /// but quick to end the IDLE keeps its connection.
    @Test func idleCancelledBeforeASlowStartKeepsTheConnection() async throws {
        let listener = FakeListener { connection in
            connection.send(Data("* OK [CAPABILITY IMAP4rev1 IDLE] Ready\r\n".utf8))
            var idleTag = ""
            while let line = await connection.readLine() {
                let text = String(decoding: line, as: UTF8.self)
                let tag = String(text.prefix { $0 != " " })
                if text.contains("IDLE") {
                    idleTag = tag
                    try? await Task.sleep(for: .milliseconds(1_500))
                    connection.send(Data("+ idling\r\n".utf8))
                } else if text == "DONE" {
                    try? await Task.sleep(for: .milliseconds(1_000))
                    connection.send(Data("\(idleTag) OK idle done\r\n".utf8))
                } else {
                    connection.send(Data("\(tag) OK done\r\n".utf8))
                }
            }
        }
        defer { listener.stop() }
        let port = try await listener.start()
        let client = try await IMAPClient.connect(endpoint(port), timing: IMAPClient.Timing(perRead: .seconds(60)))
        try await client.login(user: "jk@example.org", password: Secret("secret"))
        let idle = Task { try await client.idle(timeout: .seconds(60)) }
        // IDLE is sent by now; its `+` comes at 1.5 s.
        try await Task.sleep(for: .milliseconds(300))
        idle.cancel()
        #expect(try await idle.value == false)
        #expect(try await client.listFolders().isEmpty)
    }

    /// A server that goes silent after the client's own DONE (a change came) is given up on
    /// after the usual wait for an answer, not the IDLE's whole deadline.
    @Test func idleDoneToASilentServerIsGivenUpOnSoon() async throws {
        let (listener, port) = try await scripted(greeting: ["* OK [CAPABILITY IMAP4rev1 IDLE] Ready"]) { tag, line in
            if line.contains("IDLE") {
                return ["+ idling", "* 1 EXISTS"]
            }
            return line == "DONE" ? [] : ["\(tag) OK done"]
        }
        defer { listener.stop() }
        let client = try await IMAPClient.connect(endpoint(port), timing: IMAPClient.Timing(perRead: .seconds(1)))
        try await client.login(user: "jk@example.org", password: Secret("secret"))
        let start = ContinuousClock.now
        await #expect(throws: IMAPError.self) { _ = try await client.idle(timeout: .seconds(60)) }
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    // MARK: - CONDSTORE and QRESYNC

    /// A FakeListener answering line by line, IDLE ended with the IDLE's own tag.
    private func resyncScript(
        _ capabilities: String, _ respond: @escaping @Sendable (_ tag: String, _ line: String) -> [String]
    ) async throws -> (FakeListener, UInt16) {
        let listener = FakeListener { connection in
            connection.send(Data("* OK [CAPABILITY IMAP4rev1 \(capabilities)] Ready\r\n".utf8))
            var idleTag = ""
            while let line = await connection.readLine() {
                let text = String(decoding: line, as: UTF8.self)
                if text == "DONE" {
                    connection.send(Data("\(idleTag) OK idle done\r\n".utf8))
                    continue
                }
                let tag = String(text.prefix { $0 != " " })
                if text.hasSuffix(" IDLE") {
                    idleTag = tag
                }
                for answer in respond(tag, text) {
                    connection.send(Data((answer + "\r\n").utf8))
                }
            }
        }
        return (listener, try await listener.start())
    }

    @Test func idleEndsOnVanished() async throws {
        let (listener, port) = try await resyncScript("IDLE ENABLE QRESYNC CONDSTORE") { tag, line in
            if line.hasSuffix(" IDLE") {
                return ["+ idling", "* VANISHED 5"]
            }
            if line.contains("ENABLE") {
                return ["* ENABLED QRESYNC", "\(tag) OK enabled"]
            }
            return ["\(tag) OK done"]
        }
        defer { listener.stop() }
        let client = try await IMAPClient.connect(endpoint(port), timing: quick)
        try await client.login(user: "jk@example.org", password: Secret("secret"))
        #expect(try await client.idle(timeout: .seconds(30)) == true)
        await client.logout()
    }

    @Test func unsolicitedVanishedDuringAMoveIsHarmless() async throws {
        let (listener, port) = try await resyncScript("MOVE UIDPLUS ENABLE QRESYNC CONDSTORE") { tag, line in
            if line.contains("ENABLE") {
                return ["* ENABLED QRESYNC", "\(tag) OK enabled"]
            }
            if line.contains("SELECT") {
                return ["* 3 EXISTS", "* OK [UIDVALIDITY 1] v", "* OK [HIGHESTMODSEQ 40] m", "\(tag) OK selected"]
            }
            if line.contains("MOVE") {
                return [
                    "* OK [COPYUID 2 7 101] moved", "* VANISHED 7", "* 3 FETCH (UID 9 MODSEQ (12))",
                    "\(tag) OK moved"
                ]
            }
            return ["\(tag) OK done"]
        }
        defer { listener.stop() }
        let client = try await IMAPClient.connect(endpoint(port), timing: quick)
        try await client.login(user: "jk@example.org", password: Secret("secret"))
        _ = try await client.select("INBOX")
        #expect(try await client.move([7], to: "Archive") == [7: 101])
        await client.logout()
    }

    @Test func oversizedVanishedIsRefused() async throws {
        let many = (1...10_001).map { String($0 * 2) }.joined(separator: ",")
        let (listener, port) = try await resyncScript("ENABLE QRESYNC CONDSTORE") { tag, line in
            if line.contains("ENABLE") {
                return ["* ENABLED QRESYNC", "\(tag) OK enabled"]
            }
            if line.contains("SELECT") {
                return [
                    "* OK [UIDVALIDITY 1] v", "* OK [HIGHESTMODSEQ 40] m", "* VANISHED (EARLIER) \(many)",
                    "\(tag) OK selected"
                ]
            }
            return ["\(tag) OK done"]
        }
        defer { listener.stop() }
        let client = try await IMAPClient.connect(endpoint(port), timing: quick)
        try await client.login(user: "jk@example.org", password: Secret("secret"))
        await #expect(throws: IMAPError.protocolViolation) {
            _ = try await client.select("INBOX", from: QResyncPoint(uidValidity: 1, modSeq: 3, known: nil))
        }
        await client.logout()
    }

    @Test func presentUIDsSplitsLongSets() async throws {
        let (listener, port) = try await resyncScript("ENABLE CONDSTORE") { tag, line in
            if line.contains("UID SEARCH UID ") {
                let set = line.components(separatedBy: "UID SEARCH UID ").last ?? ""
                let present = set.split(separator: ",").filter { (Int($0) ?? 0) % 4 == 0 }
                let width = line.utf8.count < 65_536 ? "" : " TOO-LONG"
                return ["* SEARCH" + width + present.map { " \($0)" }.joined(), "\(tag) OK searched"]
            }
            return ["\(tag) OK done"]
        }
        defer { listener.stop() }
        let client = try await IMAPClient.connect(endpoint(port), timing: quick)
        try await client.login(user: "jk@example.org", password: Secret("secret"))
        let uids = (1...12_000).map { UInt32($0 * 2) }
        let present = try await client.presentUIDs(uids)
        #expect(present == Set(uids.filter { $0 % 4 == 0 }))
        await client.logout()
    }

    @Test func changesBeforeClosedBelongToTheFolderLeft() async throws {
        let (listener, port) = try await resyncScript("ENABLE QRESYNC CONDSTORE") { tag, line in
            if line.contains("ENABLE") {
                return ["* ENABLED QRESYNC", "\(tag) OK enabled"]
            }
            if line.contains("SELECT") {
                return [
                    "* VANISHED 12", "* 4 FETCH (UID 12 FLAGS (\\Seen) MODSEQ (30))", "* OK [CLOSED] left",
                    "* 9 EXISTS", "* OK [UIDVALIDITY 1] v", "* OK [HIGHESTMODSEQ 40] m",
                    "* VANISHED (EARLIER) 7", "* 4 FETCH (UID 5 FLAGS (\\Flagged) MODSEQ (39))",
                    "\(tag) OK selected"
                ]
            }
            return ["\(tag) OK done"]
        }
        defer { listener.stop() }
        let client = try await IMAPClient.connect(endpoint(port), timing: quick)
        try await client.login(user: "jk@example.org", password: Secret("secret"))
        let (status, changes) = try await client.select(
            "Archive", from: QResyncPoint(uidValidity: 1, modSeq: 3, known: nil))
        #expect(status.exists == 9)
        #expect(changes?.vanished == [7...7])
        #expect(changes?.flags == [5: ["\\Flagged"]])
        await client.logout()
    }

    @Test func noEnableWithoutTheEnableCapability() async throws {
        let (listener, port) = try await resyncScript("CONDSTORE") { tag, line in
            // A server that would take ENABLE if sent: the client must not send it unoffered.
            line.contains("ENABLE") ? ["* ENABLED CONDSTORE", "\(tag) OK enabled"] : ["\(tag) OK done"]
        }
        defer { listener.stop() }
        let client = try await IMAPClient.connect(endpoint(port), timing: quick)
        try await client.login(user: "jk@example.org", password: Secret("secret"))
        #expect(await client.resyncMode == ResyncMode.none)
        #expect(try await client.listFolders().isEmpty)
        await client.logout()
    }
}
