// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightFakes
import OutwrightGraph
import OutwrightModel
import OutwrightStore
import Testing

@testable import OutwrightSync

/// The fake's contacts in the default folder, as JSON objects.
private func serverContacts(_ h: GraphHarness) async throws -> [[String: Any]] {
    try await h.graph.contactsJSON().map { try #require(try JSONSerialization.jsonObject(with: $0) as? [String: Any]) }
}

private func defaultBook(_ h: GraphHarness) throws -> AddressBook {
    try #require(try h.store.addressBooks(h.account.id).first { $0.href == "me" })
}

private func only(_ h: GraphHarness) throws -> Contact {
    try #require(try h.store.contacts(in: nil, matching: nil).first)
}

@Suite struct GraphContactQueueTests {
    @Test func newContactIsPosted() async throws {
        try await withGraphContacts { h in
            let syncer = h.syncer()
            try await syncer.sync()
            _ = try h.store.createContact(
                ContactDetails(givenName: "Ny", familyName: "Person", emails: [Labeled(label: "other", value: "ny@example.org")]),
                in: try defaultBook(h).id)
            try await syncer.runChanges()
            let made = try await serverContacts(h)
            #expect(made.count == 1)
            #expect(made.first?["surname"] as? String == "Person")
            let stored = try only(h)
            #expect(try h.store.pendingContactChangeCount(h.account.id) == 0)
            #expect(try h.store.remoteETags(stored.addressBookID).count == 1)
        }
    }

    @Test func lostCreateAnswerMakesNoDuplicate() async throws {
        try await withGraphContacts { h in
            let syncer = h.syncer()
            try await syncer.sync()
            _ = try h.store.createContact(ContactDetails(givenName: "Once", familyName: "Only"), in: try defaultBook(h).id)
            await h.graph.dropAnswerOfNextPost()
            _ = try? await syncer.runChanges()
            try await syncer.sync()
            try await syncer.sync()
            #expect(try await serverContacts(h).count == 1)
            #expect(try h.store.contacts(in: nil, matching: nil).count == 1)
            #expect(try h.store.pendingContactChangeCount(h.account.id) == 0)
        }
    }

    @Test func editIsPatchedWithIfMatch() async throws {
        try await withGraphContacts { h in
            await h.graph.put(graphJSON(["givenName": "Bo", "surname": "Berg"]))
            let syncer = h.syncer()
            try await syncer.sync()
            try h.store.updateContact(try only(h).id, ContactDetails(givenName: "Bo", familyName: "Björk"))
            try await syncer.runChanges()
            let patch = try #require(await h.graph.requests.last { $0.method == "PATCH" })
            #expect(patch.headers["if-match"] == #"W/"1""#)
            #expect(try await serverContacts(h).first?["surname"] as? String == "Björk")
            #expect(try h.store.pendingContactChangeCount(h.account.id) == 0)
        }
    }

    @Test func staleEditKeepsBothVersions() async throws {
        try await withGraphContacts { h in
            let id = await h.graph.put(graphJSON(["givenName": "Bo", "surname": "Berg"]))
            let syncer = h.syncer()
            try await syncer.sync()
            try h.store.updateContact(try only(h).id, ContactDetails(givenName: "Bo", familyName: "Mine"))
            await h.graph.edit(id, "surname", "Theirs")
            try await syncer.runChanges()
            let contact = try only(h)
            #expect(contact.details.familyName == "Theirs")
            #expect(contact.conflict?.familyName == "Mine")
        }
    }

    @Test func editOfAGoneContactFails() async throws {
        try await withGraphContacts { h in
            let id = await h.graph.put(graphJSON(["givenName": "Bo", "surname": "Berg"]))
            let syncer = h.syncer()
            try await syncer.sync()
            try h.store.updateContact(try only(h).id, ContactDetails(givenName: "Bo", familyName: "Late"))
            await h.graph.remove(id)
            try await syncer.runChanges()
            #expect(try only(h).changeFailed)
        }
    }

    @Test func deleteIsSent() async throws {
        try await withGraphContacts { h in
            await h.graph.put(graphJSON(["displayName": "Delete Me"]))
            let syncer = h.syncer()
            try await syncer.sync()
            try h.store.deleteContact(try only(h).id)
            try await syncer.runChanges()
            #expect(try await serverContacts(h).isEmpty)
            #expect(try h.store.contacts(in: nil, matching: nil).isEmpty)
        }
    }

    /// A contact held without an etag is still deleted on Graph, without If-Match.
    @Test func deleteWithoutAnETagIsSent() async throws {
        try await withGraphContacts { h in
            await h.graph.put(graphJSON(["displayName": "No Tag"]))
            let syncer = h.syncer()
            try await syncer.sync()
            let id = try only(h).id
            try h.store.updateContact(id, ContactDetails(givenName: "No", familyName: "Tag"))
            let queued = try #require(try h.store.pendingContactChanges(h.account.id).first)
            let href = try #require(queued.href)
            try h.store.contactChangeDone(id, href: href, etag: nil, vcard: Data(), revision: queued.revision)
            try h.store.deleteContact(id)
            try await syncer.runChanges()
            #expect(try await serverContacts(h).isEmpty)
            let delete = try #require(await h.graph.requests.last { $0.method == "DELETE" })
            #expect(delete.headers["if-match"] == nil)
        }
    }

    @Test func deleteOfAGoneContactIsDone() async throws {
        try await withGraphContacts { h in
            let id = await h.graph.put(graphJSON(["displayName": "Gone"]))
            let syncer = h.syncer()
            try await syncer.sync()
            try h.store.deleteContact(try only(h).id)
            await h.graph.remove(id)
            try await syncer.runChanges()
            #expect(try h.store.pendingContactChangeCount(h.account.id) == 0)
        }
    }

    @Test func refusalFailsTheChangeForGood() async throws {
        try await withGraphContacts { h in
            await h.graph.put(graphJSON(["givenName": "Bo", "surname": "Berg"]))
            let syncer = h.syncer()
            try await syncer.sync()
            try h.store.updateContact(try only(h).id, ContactDetails(givenName: "Bo", familyName: "Bad"))
            await h.graph.failNext(status: 400)
            try await syncer.runChanges()
            #expect(try only(h).changeFailed)
            #expect(try h.store.pendingContactChangeCount(h.account.id) == 0)
        }
    }

    @Test func throttlingStopsTheQueueWithoutCounting() async throws {
        try await withGraphContacts { h in
            await h.graph.put(graphJSON(["givenName": "Bo", "surname": "Berg"]))
            let syncer = h.syncer()
            try await syncer.sync()
            let bo = try only(h)
            try h.store.updateContact(bo.id, ContactDetails(givenName: "Bo", familyName: "Later"))
            await h.graph.failNext(status: 429)
            await #expect(throws: SyncError.graph(.throttled)) { try await syncer.runChanges() }
            #expect(try h.store.pendingContactChangeCount(h.account.id) == 1)
            #expect(try h.store.contactChangeAttempted(bo.id, revision: -1) == 0)
            try await syncer.runChanges()
            #expect(try await serverContacts(h).first?["surname"] as? String == "Later")
        }
    }

    @Test func unshownPropertiesSurviveAnEdit() async throws {
        try await withGraphContacts { h in
            await h.graph.put(graphJSON(["givenName": "Bo", "surname": "Berg", "jobTitle": "Chief"]))
            let syncer = h.syncer()
            try await syncer.sync()
            try h.store.updateContact(try only(h).id, ContactDetails(givenName: "Bo", familyName: "Björk"))
            try await syncer.runChanges()
            #expect(try await serverContacts(h).first?["jobTitle"] as? String == "Chief")
        }
    }

    @Test func discardingAFailedEditRestoresGraphsVersion() async throws {
        try await withGraphContacts { h in
            let id = await h.graph.put(graphJSON(["givenName": "Bo", "surname": "Berg"]))
            let syncer = h.syncer()
            try await syncer.sync()
            let bo = try only(h)
            try h.store.updateContact(bo.id, ContactDetails(givenName: "Bo", familyName: "Bad"))
            await h.graph.failNext(status: 400)
            try await syncer.runChanges()
            try ContactRestore.discardFailedChange(bo.id, in: h.store)
            #expect(try only(h).details.familyName == "Berg")
            _ = id
        }
    }

    /// A 429, then a 401 on a token renewed a moment ago: Graph renews it once and goes on; the
    /// edit reaches Graph on the next sync and the account is never asked to sign in again.
    @Test func throttlingThenARefusedTokenIsSurvived() async throws {
        try await withGraphContacts { h in
            await h.graph.put(graphJSON(["givenName": "Bo", "surname": "Berg"]))
            let syncer = h.syncer()
            try await syncer.sync()
            try h.store.updateContact(try only(h).id, ContactDetails(givenName: "Bo", familyName: "Through"))
            await h.graph.failNext(status: 429)
            await h.graph.failNext(status: 401)
            await #expect(throws: SyncError.graph(.throttled)) { try await syncer.sync() }
            let before = await h.microsoft.oauth.server.requests
            try await syncer.sync()
            #expect(await h.microsoft.oauth.server.requests == before + 1)
            #expect(try await serverContacts(h).first?["surname"] as? String == "Through")
        }
    }

    /// Graph's name for an address (Outlook shows it) is kept when the contact is edited.
    @Test func addressNamesSurviveAnEdit() async throws {
        try await withGraphContacts { h in
            await h.graph.put(graphJSON([
                "givenName": "Bo", "surname": "Berg",
                "emailAddresses": [["name": "Bo at work", "address": "bo@example.org"]],
            ]))
            let syncer = h.syncer()
            try await syncer.sync()
            var details = try only(h).details
            details.familyName = "Björk"
            try h.store.updateContact(try only(h).id, details)
            try await syncer.runChanges()
            let emails = try #require(try await serverContacts(h).first?["emailAddresses"] as? [[String: Any]])
            #expect(emails.first?["name"] as? String == "Bo at work")
            #expect(emails.first?["address"] as? String == "bo@example.org")
        }
    }

    /// A note longer than the app holds is written back whole when the owner didn't touch it.
    @Test func aLongNoteSurvivesAnEditElsewhere() async throws {
        try await withGraphContacts { h in
            let long = String(repeating: "Lund ", count: 20_000)
            await h.graph.put(graphJSON(["givenName": "Bo", "surname": "Berg", "personalNotes": long]))
            let syncer = h.syncer()
            try await syncer.sync()
            var details = try only(h).details
            details.familyName = "Björk"
            try h.store.updateContact(try only(h).id, details)
            try await syncer.runChanges()
            let server = try #require(try await serverContacts(h).first)
            #expect(server["surname"] as? String == "Björk")
            #expect(server["personalNotes"] as? String == long)
        }
    }
}
