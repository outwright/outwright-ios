// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightFakes
import OutwrightModel
import OutwrightStore
import OutwrightSync
import Testing

@Suite struct PersonServerSearchTests {
    @Test func serverSearchBringsInAPersonsOlderMail() async throws {
        let server = await standardServer()
        await server.deliver(mail("recent from bo", date: daysAgo(2)), to: "INBOX")
        await server.deliver(mail("old from bo", date: daysAgo(400)), to: "INBOX")
        await server.deliver(mail("old from carl", from: "carl@example.org", date: daysAgo(400)), to: "INBOX")
        await server.deliver(
            mail("old to bo", from: "jk@example.org", to: "bo@example.org", date: daysAgo(410)), to: "Sent")
        try await withHarness(server) { h in
            let syncer = h.syncer()
            try await syncer.syncFolders()
            try await syncer.sync(try h.folder(.inbox).id)
            try await syncer.sync(try h.folder(.sent).id)
            let from = ServerQuery(text: "", people: ["bo@example.org"], direction: .from, before: nil)
            let found = try await syncer.searchServer(from, limit: 10)
            #expect(found.count == 1)
            #expect(Set(try h.rows(.inbox).map(\.subject)) == ["recent from bo", "old from bo"])
            let to = ServerQuery(text: "", people: ["bo@example.org"], direction: .to, before: nil)
            #expect(try await syncer.searchServer(to, limit: 10).count == 1)
            #expect(try h.rows(.sent).map(\.subject) == ["old to bo"])
        }
    }

    @Test func serverSearchLooksInAFolderNotOpenedHereYet() async throws {
        let server = await standardServer()
        await server.deliver(
            mail("sent to bo", from: "jk@example.org", to: "bo@example.org", date: daysAgo(3)), to: "Sent")
        try await withHarness(server) { h in
            let syncer = h.syncer()
            try await syncer.syncFolders()
            let to = ServerQuery(text: "", people: ["bo@example.org"], direction: .to, before: nil)
            #expect(try await syncer.searchServer(to, limit: 10).count == 1)
            #expect(try h.rows(.sent).map(\.subject) == ["sent to bo"])
            // The folder synced afterwards keeps what the search brought in, once.
            try await syncer.sync(try h.folder(.sent).id)
            #expect(try h.rows(.sent).map(\.subject) == ["sent to bo"])
        }
    }

    @Test func beforeKeepsOnlyOlderHits() async throws {
        let server = await standardServer()
        await server.deliver(mail("budget now", date: daysAgo(100)), to: "INBOX")
        await server.deliver(mail("budget then", date: daysAgo(300)), to: "INBOX")
        try await withHarness(server) { h in
            let syncer = h.syncer()
            try await syncer.syncFolders()
            try await syncer.sync(try h.folder(.inbox).id)
            let query = ServerQuery(text: "budget", people: [], direction: nil, before: daysAgo(200))
            #expect(try await syncer.searchServer(query, limit: 10).count == 1)
            #expect(try h.rows(.inbox).map(\.subject) == ["budget then"])
        }
    }
}
