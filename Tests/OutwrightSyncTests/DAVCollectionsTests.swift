// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightFakes
import OutwrightModel
import OutwrightNet
import Testing

@testable import OutwrightSync

/// Whether an account has a calendar or an address book behind its DAV address (#60).
@Suite struct DAVCollectionsTests {
    let session = URLSession(configuration: .ephemeral)

    private func account() -> Account {
        let local = MailEndpoint(host: "127.0.0.1", port: 1, security: "plainLoopbackOnly")
        return Account(
            id: AccountID(), displayName: "JK", email: "jk@example.org", colorIndex: 0, imap: local, smtp: local,
            user: "jk@example.org", signature: "", sortOrder: 0)
    }

    @Test func aCalendarIsFound() async throws {
        let server = FakeCalDAVServer()
        let port = try await server.start()
        _ = await server.addCalendar("Work")
        let found = await DAVCollections.exist(
            .calDAV, at: "http://127.0.0.1:\(port)/", for: account(), password: Secret("secret"), session: session)
        await server.stop()
        #expect(found == true)
    }

    @Test func noCalendarIsNone() async throws {
        let server = FakeCalDAVServer()
        let port = try await server.start()
        let found = await DAVCollections.exist(
            .calDAV, at: "http://127.0.0.1:\(port)/", for: account(), password: Secret("secret"), session: session)
        await server.stop()
        #expect(found == false)
    }

    @Test func anAddressBookIsFound() async throws {
        let server = FakeCardDAVServer()
        let port = try await server.start()
        _ = await server.addBook("Contacts")
        let found = await DAVCollections.exist(
            .cardDAV, at: "http://127.0.0.1:\(port)/", for: account(), password: Secret("secret"), session: session)
        await server.stop()
        #expect(found == true)
    }

    @Test func noAddressBookIsNone() async throws {
        let server = FakeCardDAVServer()
        let port = try await server.start()
        let found = await DAVCollections.exist(
            .cardDAV, at: "http://127.0.0.1:\(port)/", for: account(), password: Secret("secret"), session: session)
        await server.stop()
        #expect(found == false)
    }

    // Only an answer that lists nothing is "none": a refusal says nothing about what is there.
    @Test func aRefusedPasswordIsUnknown() async throws {
        let server = FakeCalDAVServer()
        let port = try await server.start()
        _ = await server.addCalendar("Work")
        let found = await DAVCollections.exist(
            .calDAV, at: "http://127.0.0.1:\(port)/", for: account(), password: Secret("wrong"), session: session)
        await server.stop()
        #expect(found == nil)
    }

    @Test func anUnreachableServerIsUnknown() async throws {
        let server = FakeCalDAVServer()
        let port = try await server.start()
        await server.stop()
        let found = await DAVCollections.exist(
            .calDAV, at: "http://127.0.0.1:\(port)/", for: account(), password: Secret("secret"), session: session)
        #expect(found == nil)
    }
}
