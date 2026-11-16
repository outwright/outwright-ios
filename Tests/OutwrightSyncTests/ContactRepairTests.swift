// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import GRDB
import OutwrightDAV
import OutwrightFakes
import OutwrightModel
import OutwrightSync
import Testing

@testable import OutwrightStore

@Suite struct ContactRepairTests {
    @Test func discardingAFailedChangeBringsBackTheServersVersion() async throws {
        try await withContacts { h in
            let book = await h.server.addBook("Work")
            await h.server.putCard(card("b", given: "Bo", family: "Berg", email: "bo@example.org"), uid: "b", in: book)
            let syncer = h.syncer()
            try await syncer.sync()
            let bo = try h.contact(named: "Bo Berg")
            var own = bo.details
            own.familyName = "Own"
            try h.store.updateContact(bo.id, own)
            await h.server.failWrites(status: 403, count: 1)
            try await syncer.runChanges()
            #expect(try h.store.contact(bo.id)?.changeFailed == true)

            try ContactRestore.discardFailedChange(bo.id, in: h.store)

            let after = try #require(try h.store.contact(bo.id))
            #expect(!after.changeFailed)
            #expect(after.details.name == "Bo Berg")
            #expect(after.details.emails.map(\.value) == ["bo@example.org"])
            #expect(try h.store.pendingContactChanges(h.account.id).isEmpty)
            // No longer frozen: the server's next version comes in.
            await h.server.putCard(card("b", given: "Bo", family: "Lind"), uid: "b", in: book)
            try await syncer.sync()
            #expect(try h.store.contact(bo.id)?.details.name == "Bo Lind")
        }
    }

    @Test(arguments: [true, false]) func discardingAFailedChangeFetchesTheServersLatestVersion(syncCollection: Bool) async throws {
        try await withContacts(sync: syncCollection) { h in
            let book = await h.server.addBook("Work")
            await h.server.putCard(card("b", given: "Bo", family: "Berg"), uid: "b", in: book)
            let syncer = h.syncer()
            try await syncer.sync()
            let bo = try h.contact(named: "Bo Berg")
            try h.store.deleteContact(bo.id)
            await h.server.putCard(card("b", given: "Bo", family: "Server"), uid: "b", in: book)
            try await syncer.sync()
            #expect(try h.store.contact(bo.id)?.changeFailed == true)
            // The server changes it again while the failure waits for the owner.
            await h.server.putCard(card("b", given: "Bo", family: "Latest"), uid: "b", in: book)
            try await syncer.sync()
            #expect(try h.store.contact(bo.id)?.details.name == "Bo Server")

            try ContactRestore.discardFailedChange(bo.id, in: h.store)
            try await syncer.sync()

            #expect(try h.store.contact(bo.id)?.details.name == "Bo Latest")
            // Its ETag is the current one: a delete is taken rather than refused.
            try h.store.deleteContact(bo.id)
            try await syncer.runChanges()
            #expect(await h.server.cards(in: book)["b"] == nil)
            #expect(try h.store.contact(bo.id) == nil)
        }
    }

    @Test func discardingAFailedChangeWithAnUnreadableServerCardFetchesTheServersVersionAgain() async throws {
        try await withContacts { h in
            let book = await h.server.addBook("Work")
            await h.server.putCard(card("b", given: "Bo", family: "Berg"), uid: "b", in: book)
            let syncer = h.syncer()
            try await syncer.sync()
            let bo = try h.contact(named: "Bo Berg")
            var own = bo.details
            own.familyName = "Own"
            try h.store.updateContact(bo.id, own)
            await h.server.failWrites(status: 403, count: 1)
            try await syncer.runChanges()
            try h.store.write { database in
                try database.execute(sql: "UPDATE contact SET vcard = X'00'")
            }

            try ContactRestore.discardFailedChange(bo.id, in: h.store)
            try await syncer.sync()

            // The server's card is unchanged, yet it replaces the owner's given-up details.
            #expect(try h.store.contact(bo.id)?.details.familyName == "Berg")
        }
    }

    @Test func unreadableDetailsAreReadAgainFromTheServersCardBeforeAnythingIsSent() async throws {
        try await withContacts { h in
            let book = await h.server.addBook("Work")
            let text = card("b", given: "Bo", family: "Berg", email: "bo@example.org", extra: ["TEL:+461"])
            await h.server.putCard(text, uid: "b", in: book)
            let syncer = h.syncer()
            try await syncer.sync()
            let bo = try h.contact(named: "Bo Berg")
            try h.store.write { database in
                try database.execute(sql: "UPDATE contact SET detailsJSON = '{\"emails\": 5}'")
            }
            #expect(try h.store.contact(bo.id)?.details.name == "")

            try await syncer.sync()

            let after = try #require(try h.store.contact(bo.id))
            #expect(after.details.name == "Bo Berg")
            #expect(after.details.phones.map(\.value) == ["+461"])
            #expect(await h.server.cards(in: book)["b"] == text)
        }
    }
}
