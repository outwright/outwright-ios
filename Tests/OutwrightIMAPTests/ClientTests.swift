// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightFakes
import OutwrightIMAP
import OutwrightNet
import Synchronization
import Testing

func message(_ subject: String, date: String = "Fri, 06 Nov 2026 10:00:00 +0000", body: String = "Hello there") -> Data {
    Data("""
    From: Bo <bo@example.org>\r
    To: jk@example.org\r
    Subject: \(subject)\r
    Date: \(date)\r
    \r
    \(body)\r

    """.utf8)
}

func endpoint(_ port: UInt16, _ security: TransportSecurity = .plainLoopbackOnly) -> ServerEndpoint {
    ServerEndpoint(host: "127.0.0.1", port: port, security: security)
}

/// Starts `server`, runs `body` with its port, and stops the server whatever happens.
func withServer(_ server: FakeIMAPServer, _ body: (UInt16) async throws -> Void) async throws {
    let port = try await server.start()
    do {
        try await body(port)
    } catch {
        await server.stop()
        throw error
    }
    await server.stop()
}

/// As `withServer`, with a client signed in; logs out before the server stops.
func withClient(_ server: FakeIMAPServer, _ body: (IMAPClient) async throws -> Void) async throws {
    try await withServer(server) { port in
        let client = try await IMAPClient.connect(endpoint(port))
        do {
            try await client.login(user: "jk@example.org", password: Secret("secret"))
            try await body(client)
        } catch {
            await client.logout()
            throw error
        }
        await client.logout()
    }
}

private func utc(_ year: Int, _ month: Int, _ day: Int) throws -> Date {
    try #require(Calendar(identifier: .gregorian).date(from: DateComponents(timeZone: .gmt, year: year, month: month, day: day)))
}

@Suite struct ClientTests {
    @Test func logsInListsAndSelects() async throws {
        let server = FakeIMAPServer()
        await server.addFolder("Sent", specialUse: "\\Sent")
        await server.addFolder("Skr&AOQ-ppost", specialUse: nil)
        await server.addFolder("Projekt", specialUse: nil)
        await server.setUIDValidity(777, for: "INBOX")
        _ = await server.deliver(message("one"), to: "INBOX")
        _ = await server.deliver(message("two"), to: "INBOX")
        try await withClient(server) { client in
            #expect(await client.capabilities.contains("IDLE"))
            let folders = try await client.listFolders()
            #expect(folders.first { $0.role == .inbox }?.path == "INBOX")
            #expect(folders.first { $0.role == .sent }?.path == "Sent")
            let junk = try #require(folders.first { $0.role == .junk })
            #expect(junk.name == "Skräppost")
            #expect(junk.path == "Skr&AOQ-ppost")
            #expect(folders.first { $0.path == "Projekt" }?.role == .other)

            let status = try await client.select("INBOX")
            #expect(status.uidValidity == 777)
            #expect(status.exists == 2)
            #expect(status.uidNext == 3)

            // Paths are wire paths: the one LIST gave selects, the display name does not.
            #expect(try await client.select(junk.path).exists == 0)
            await #expect(throws: IMAPError.folderMissing("Skräppost")) {
                _ = try await client.select("Skräppost")
            }
            await #expect(throws: IMAPError.folderMissing("Nowhere")) {
                _ = try await client.select("Nowhere")
            }
        }
    }

    @Test func wrongPasswordIsAuthenticationFailedWithoutThePassword() async throws {
        let server = FakeIMAPServer()
        try await withServer(server) { port in
            let client = try await IMAPClient.connect(endpoint(port))
            do {
                try await client.login(user: "jk@example.org", password: Secret("wrong\"pass"))
                Issue.record("login succeeded")
            } catch {
                #expect(error as? IMAPError == .authenticationFailed)
                #expect(!"\(error)".contains("wrong"))
            }
            #expect(await server.loginAttempts == 1)
            await client.logout()
        }
    }

    @Test func startTLSNotOfferedRefusedBeforeLogin() async throws {
        let server = FakeIMAPServer(offersStartTLS: false)
        try await withServer(server) { port in
            await #expect(throws: IMAPError.startTLSNotOffered) {
                let client = try await IMAPClient.connect(endpoint(port, .startTLS))
                try await client.login(user: "jk@example.org", password: Secret("secret"))
            }
            #expect(await server.loginAttempts == 0)
        }
    }

    @Test func findsMailBetweenTwoDays() async throws {
        let server = FakeIMAPServer()
        let older = await server.deliver(message("older", date: "Mon, 06 Jan 2020 10:00:00 +0000"), to: "INBOX")
        let middle = await server.deliver(message("middle", date: "Wed, 03 Jun 2026 10:00:00 +0000"), to: "INBOX")
        _ = await server.deliver(message("newest"), to: "INBOX")
        try await withClient(server) { client in
            _ = try await client.select("INBOX")
            #expect(try await client.uids(since: utc(2026, 5, 1), before: utc(2026, 7, 1)) == [middle])
            #expect(try await client.uids(since: nil, before: utc(2026, 7, 1)) == [older, middle])
            #expect(try await client.uids(since: nil, before: utc(2019, 1, 1)).isEmpty)
        }
    }

    @Test func fetchesSummariesSinceDate() async throws {
        let server = FakeIMAPServer()
        let oldMessage = message("old", date: "Mon, 06 Jan 2020 10:00:00 +0000")
        let newMessage = message("new", body: String(repeating: "abcdefgh", count: 1000))
        let old = await server.deliver(oldMessage, to: "INBOX")
        let new = await server.deliver(newMessage, to: "INBOX", flags: ["\\Seen"])
        try await withClient(server) { client in
            _ = try await client.select("INBOX")
            #expect(try await client.uids(since: utc(2026, 10, 1)) == [new])
            #expect(try await client.uids(since: .distantPast) == [old, new])

            let summaries = try await client.summaries(uids: [old, new])
            #expect(summaries.count == 2)
            let summary = try #require(summaries.first { $0.uid == new })
            #expect(summary.flags == ["\\Seen"])
            #expect(String(decoding: summary.headers, as: UTF8.self).contains("Subject: new"))
            #expect(summary.partialText.count == 4096)
            #expect(summary.size == newMessage.count)
            #expect(summary.internalDate == Date(timeIntervalSince1970: 1_793_959_200))

            #expect(try await client.body(uid: old) == oldMessage)
            #expect(try await client.summaries(uids: []).isEmpty)
        }
    }

    @Test func setsClearsAndReadsFlags() async throws {
        let server = FakeIMAPServer()
        let uid = await server.deliver(message("flag me"), to: "INBOX")
        let other = await server.deliver(message("leave me"), to: "INBOX", flags: ["$Label1"])
        try await withClient(server) { client in
            _ = try await client.select("INBOX")
            try await client.setFlags(["\\Seen", "\\Flagged"], on: [uid], add: true)
            #expect(await server.messages(in: "INBOX").first?.flags == ["\\Seen", "\\Flagged"])
            try await client.setFlags(["\\Flagged"], on: [uid], add: false)
            #expect(await server.messages(in: "INBOX").first?.flags == ["\\Seen"])
            #expect(try await client.flags(uids: [uid, other]) == [uid: ["\\Seen"], other: ["$Label1"]])
            #expect(try await client.flags(uids: []).isEmpty)
        }
    }

    @Test(arguments: [true, false]) func movesWithAndWithoutMoveExtension(offersMove: Bool) async throws {
        let server = FakeIMAPServer(offersMove: offersMove)
        await server.addFolder("Archive", specialUse: "\\Archive")
        _ = await server.deliver(message("already archived"), to: "Archive")
        let keep = await server.deliver(message("keep"), to: "INBOX")
        let first = await server.deliver(message("move 1"), to: "INBOX")
        let second = await server.deliver(message("move 2"), to: "INBOX")
        try await withClient(server) { client in
            #expect(await client.capabilities.contains("MOVE") == offersMove)
            _ = try await client.select("INBOX")

            let moved = try await client.move([first, second], to: "Archive")
            #expect(moved == [first: 2, second: 3])
            #expect(await server.messages(in: "INBOX").map(\.uid) == [keep])
            let archived = await server.messages(in: "Archive")
            #expect(archived.count == 3)
            #expect(archived.allSatisfy { !$0.flags.contains("\\Deleted") })
            #expect(archived.last?.data == message("move 2"))

            await #expect(throws: IMAPError.folderMissing("Nowhere")) {
                _ = try await client.move([keep], to: "Nowhere")
            }
        }
    }

    @Test func movesByCopyWithoutUIDPlusLeavingOriginalsDeleted() async throws {
        let server = FakeIMAPServer(offersMove: false, offersUIDPlus: false)
        await server.addFolder("Archive", specialUse: "\\Archive")
        let keep = await server.deliver(message("keep"), to: "INBOX")
        let gone = await server.deliver(message("move"), to: "INBOX")
        try await withClient(server) { client in
            _ = try await client.select("INBOX")
            #expect(try await client.move([gone], to: "Archive").isEmpty)
            let inbox = await server.messages(in: "INBOX")
            #expect(inbox.map(\.uid) == [keep, gone])
            #expect(inbox.last?.flags.contains("\\Deleted") == true)
            #expect(await server.messages(in: "Archive").count == 1)
        }
    }

    @Test func expungesOnlyTheNamedMessages() async throws {
        let server = FakeIMAPServer()
        let first = await server.deliver(message("one"), to: "INBOX", flags: ["\\Deleted"])
        let second = await server.deliver(message("two"), to: "INBOX", flags: ["\\Deleted"])
        try await withClient(server) { client in
            _ = try await client.select("INBOX")
            try await client.expunge([first])
            #expect(await server.messages(in: "INBOX").map(\.uid) == [second])
        }
    }

    @Test func expungeNeedsUIDPlus() async throws {
        let server = FakeIMAPServer(offersUIDPlus: false)
        let uid = await server.deliver(message("one"), to: "INBOX", flags: ["\\Deleted"])
        try await withClient(server) { client in
            _ = try await client.select("INBOX")
            await #expect(throws: IMAPError.extensionMissing) {
                try await client.expunge([uid])
            }
            #expect(await server.messages(in: "INBOX").count == 1)
        }
    }

    @Test(arguments: [true, false]) func appendsToDrafts(offersUIDPlus: Bool) async throws {
        let server = FakeIMAPServer(offersUIDPlus: offersUIDPlus)
        await server.addFolder("Drafts", specialUse: "\\Drafts")
        try await withClient(server) { client in
            let draft = message("draft with åäö")
            let uid = try await client.append(draft, to: "Drafts", flags: ["\\Draft", "\\Seen"])
            #expect(uid == (offersUIDPlus ? 1 : nil))
            let stored = await server.messages(in: "Drafts")
            #expect(stored.count == 1)
            #expect(stored.first?.data == draft)
            #expect(stored.first?.flags == ["\\Draft", "\\Seen"])

            await #expect(throws: IMAPError.folderMissing("Nowhere")) {
                _ = try await client.append(draft, to: "Nowhere", flags: [])
            }
        }
    }

    @Test func createsFoldersFromDisplayNamesAndStripsLineBreaks() async throws {
        let server = FakeIMAPServer()
        try await withClient(server) { client in
            try await client.create("Kvitton")
            try await client.create("Skräppost")
            try await client.create("R&D")
            try await client.create("Evil\r\nA9 DELETE INBOX")
            let folders = try await client.listFolders()
            let paths = folders.map(\.path)
            #expect(paths.contains("Kvitton"))
            #expect(paths.contains("Skr&AOQ-ppost"))
            #expect(paths.contains("R&-D"))
            #expect(folders.first { $0.path == "R&-D" }?.name == "R&D")
            #expect(paths.contains("EvilA9 DELETE INBOX"))
            #expect(paths.contains("INBOX"))
        }
    }

    @Test func searchesText() async throws {
        let server = FakeIMAPServer()
        let crayfish = await server.deliver(message("Kräftskiva i helgen"), to: "INBOX")
        let invoice = await server.deliver(message("Invoice 42", body: "Please pay the invoice"), to: "INBOX")
        _ = await server.deliver(message("Old invoice", date: "Mon, 06 Jan 2020 10:00:00 +0000", body: "invoice"), to: "INBOX")
        try await withClient(server) { client in
            _ = try await client.select("INBOX")
            #expect(try await client.searchText("kräftskiva", since: nil) == [crayfish])
            #expect(try await client.searchText("invoice", since: utc(2026, 1, 1)) == [invoice])
            #expect(try await client.searchText("nothing \"like\" this", since: nil).isEmpty)
        }
    }

    @Test func searchesByPersonAndAge() async throws {
        let server = FakeIMAPServer()
        func mail(from: String, to: String, cc: String = "nobody@example.org", date: String) -> Data {
            Data("From: \(from)\r\nTo: \(to)\r\nCc: \(cc)\r\nSubject: x\r\nDate: \(date)\r\n\r\nHello\r\n".utf8)
        }
        let recent = "Fri, 06 Nov 2026 10:00:00 +0000"
        let fromBo = await server.deliver(mail(from: "bo@example.org", to: "jk@example.org", date: recent), to: "INBOX")
        let toBo = await server.deliver(mail(from: "jk@example.org", to: "bo@example.org", date: recent), to: "INBOX")
        let ccBo = await server.deliver(
            mail(from: "jk@example.org", to: "x@example.org", cc: "bo@example.org", date: recent), to: "INBOX")
        let oldFromBo = await server.deliver(
            mail(from: "bo@example.org", to: "jk@example.org", date: "Mon, 06 Jan 2020 10:00:00 +0000"), to: "INBOX")
        try await withClient(server) { client in
            _ = try await client.select("INBOX")
            #expect(try await client.search(IMAPSearch(from: "bo@example.org")) == [fromBo, oldFromBo])
            #expect(try await client.search(IMAPSearch(to: "bo@example.org")) == [toBo])
            #expect(try await client.search(IMAPSearch(cc: "bo@example.org")) == [ccBo])
            #expect(try await client.search(IMAPSearch(from: "bo@example.org", before: utc(2026, 1, 1))) == [oldFromBo])
            #expect(try await client.search(IMAPSearch(text: "hello", from: "bo@example.org\r\n")).count == 2)
            #expect(try await client.search(IMAPSearch()).isEmpty, "no criteria asks nothing")
        }
    }

    @Test func findsMessagesByMessageID() async throws {
        let server = FakeIMAPServer()
        func withID(_ id: String, _ subject: String) -> Data {
            Data("From: bo@example.org\r\nMessage-ID: <\(id)>\r\nSubject: \(subject)\r\n\r\nNames <b@example.org>\r\n".utf8)
        }
        _ = await server.deliver(withID("a@example.org", "first"), to: "INBOX")
        let wanted = await server.deliver(withID("b@example.org", "second"), to: "INBOX")
        try await withClient(server) { client in
            _ = try await client.select("INBOX")
            #expect(try await client.uids(messageID: "b@example.org") == [wanted])
            #expect(try await client.uids(messageID: "<b@example.org>") == [wanted])
            #expect(try await client.uids(messageID: "c@example.org").isEmpty)
            #expect(try await client.uids(messageID: "\r\n").isEmpty)
        }
    }

    /// A folder that is already there is no failure; any other refusal is.
    @Test func createTakesAnExistingFolderAndThrowsOtherRefusals() async throws {
        let server = FakeIMAPServer()
        await server.keepFoldersUnderInbox()
        await server.addFolder("INBOX.Archive", specialUse: nil)
        try await withClient(server) { client in
            try await client.create("INBOX.Archive")
            await #expect(throws: IMAPError.self) { try await client.create("Archive") }
        }
    }

    /// SEARCH HEADER matches a substring: a Message-ID inside another is not taken for it.
    @Test func aMessageIDInsideAnotherIsNotAMatch() async throws {
        let server = FakeIMAPServer()
        func withID(_ id: String) -> Data {
            Data("From: bo@example.org\r\nMessage-ID: <\(id)>\r\nSubject: x\r\n\r\nx\r\n".utf8)
        }
        _ = await server.deliver(withID("5123@example.org"), to: "INBOX")
        let wanted = await server.deliver(withID("123@example.org"), to: "INBOX")
        _ = await server.deliver(withID("123@example.org.uk"), to: "INBOX")
        try await withClient(server) { client in
            _ = try await client.select("INBOX")
            #expect(try await client.uids(messageID: "<123@example.org>") == [wanted])
        }
    }

    @Test func idleReturnsTrueOnNewMail() async throws {
        let server = FakeIMAPServer()
        try await withClient(server) { client in
            _ = try await client.select("INBOX")
            let delivery = Task {
                await server.waitUntilIdling()
                _ = await server.deliver(message("fresh"), to: "INBOX")
            }
            let start = SuspendingClock.now
            #expect(try await client.idle(timeout: .seconds(20)) == true)
            #expect(SuspendingClock.now - start < .seconds(10))
            await delivery.value

            #expect(try await client.idle(timeout: .milliseconds(300)) == false)
            // The connection is still in step after both idles.
            #expect(try await client.select("INBOX").exists == 1)
        }
    }

    @Test func closeEndsAnIdleAtOnceWithoutWaitingForTheServer() async throws {
        let server = FakeIMAPServer()
        try await withServer(server) { port in
            let client = try await IMAPClient.connect(endpoint(port))
            try await client.login(user: "jk@example.org", password: Secret("secret"))
            _ = try await client.select("INBOX")
            let idling = Task { try await client.idle(timeout: .seconds(600)) }
            await server.waitUntilIdling()
            await server.stopAnswering()
            let start = SuspendingClock.now
            await client.close()
            await #expect(throws: IMAPError.self) { _ = try await idling.value }
            #expect(SuspendingClock.now - start < .seconds(5))
            await #expect(throws: IMAPError.net(.closed)) { _ = try await client.listFolders() }
        }
    }

    @Test func idleEndsPromptlyWhenCancelled() async throws {
        let server = FakeIMAPServer()
        try await withClient(server) { client in
            _ = try await client.select("INBOX")
            let idle = Task { try await client.idle(timeout: .seconds(60)) }
            await server.waitUntilIdling()
            let start = SuspendingClock.now
            idle.cancel()
            #expect(try await idle.value == false)
            #expect(SuspendingClock.now - start < .seconds(5))
            #expect(try await client.select("INBOX").exists == 0)
        }
    }

    @Test func idleCancelledWhileWaitingForItsTurnEndsAtOnce() async throws {
        let server = FakeIMAPServer()
        let uid = await server.deliver(Data("Subject: Hi\r\n\r\nHello\r\n".utf8), to: "INBOX")
        await server.delayFetches(.seconds(2))
        try await withClient(server) { client in
            _ = try await client.select("INBOX")
            let slowDone = Mutex(false)
            let slow = Task {
                defer { slowDone.withLock { $0 = true } }
                return try await client.body(uid: uid)
            }
            try await Task.sleep(for: .milliseconds(200))
            let idle = Task { try await client.idle(timeout: .seconds(60)) }
            try await Task.sleep(for: .milliseconds(200))
            let start = SuspendingClock.now
            idle.cancel()
            #expect(try await idle.value == false)
            // Ended while the command ahead of it still ran, not once it was done.
            #expect(!slowDone.withLock { $0 })
            #expect(SuspendingClock.now - start < .seconds(1))
            _ = try await slow.value
        }
    }

    @Test func aCommandCancelledWhileWaitingForItsTurnSendsNothing() async throws {
        let server = FakeIMAPServer()
        let uid = await server.deliver(Data("Subject: Hi\r\n\r\nHello\r\n".utf8), to: "INBOX")
        await server.delayFetches(.seconds(2))
        try await withClient(server) { client in
            _ = try await client.select("INBOX")
            let slowDone = Mutex(false)
            let slow = Task {
                defer { slowDone.withLock { $0 = true } }
                return try await client.body(uid: uid)
            }
            try await Task.sleep(for: .milliseconds(200))
            let waiting = Task { try await client.listFolders() }
            try await Task.sleep(for: .milliseconds(200))
            let start = SuspendingClock.now
            waiting.cancel()
            await #expect(throws: IMAPError.cancelled) {
                _ = try await waiting.value
            }
            // Ended while the command ahead of it still ran, not once it was done.
            #expect(!slowDone.withLock { $0 })
            #expect(SuspendingClock.now - start < .seconds(1))
            _ = try await slow.value
            #expect(try await client.select("INBOX").exists == 1)
        }
    }

    @Test func aLogoutCancelledWhileWaitingForItsTurnLetsTheCommandFinish() async throws {
        let server = FakeIMAPServer()
        let uid = await server.deliver(Data("Subject: Hi\r\n\r\nHello\r\n".utf8), to: "INBOX")
        await server.delayFetches(.seconds(1))
        try await withClient(server) { client in
            _ = try await client.select("INBOX")
            let slow = Task { try await client.body(uid: uid) }
            try await Task.sleep(for: .milliseconds(200))
            let logout = Task { await client.logout() }
            try await Task.sleep(for: .milliseconds(200))
            // Next in line after the logout: it must not get a turn while the fetch has it.
            let after = Task { try await client.listFolders() }
            try await Task.sleep(for: .milliseconds(200))
            logout.cancel()
            #expect(String(decoding: try await slow.value, as: UTF8.self).contains("Hello"))
            await logout.value
            await #expect(throws: IMAPError.net(.closed)) {
                _ = try await after.value
            }
        }
    }

    @Test func droppedConnectionIsReportedAsClosedAndStaysClosed() async throws {
        let server = FakeIMAPServer()
        // Signing in takes two commands (LOGIN, ENABLE); the next one finds the connection gone.
        await server.dropNextConnection(afterCommands: 2)
        try await withClient(server) { client in
            await #expect(throws: IMAPError.net(.closed)) {
                _ = try await client.select("INBOX")
            }
            await #expect(throws: IMAPError.net(.closed)) {
                _ = try await client.listFolders()
            }
        }
    }
}
