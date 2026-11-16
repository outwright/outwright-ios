// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightFakes
import Testing

@testable import OutwrightGraph

@Suite struct GraphContactsTests {
    private let createID = "6f1c2c8e-0b6a-4c52-9a6e-3d2f4f0e9b11"

    @Test func foldersListDefaultFirst() async throws {
        try await withGraph { server, client, _ in
            let family = await server.addFolder("Family")
            let folders = try await client.folders()
            #expect(folders == [GraphFolder(path: "me", name: "Contacts"),
                                GraphFolder(path: "me/contactFolders/\(family)", name: "Family")])
        }
    }

    @Test func contactsAreReadWithTheirETag() async throws {
        try await withGraph { server, client, _ in
            let id = await server.put(json(fullContact))
            let contact = try #require(try await client.contacts(in: .defaultFolder).first)
            #expect(contact.id == id)
            #expect(contact.etag == #"W/"1""#)
            let fields = contact.fields
            #expect(fields.givenName == "Maja" && fields.surname == "Ek" && fields.displayName == "Maja Ek")
            #expect(fields.companyName == "Ek AB" && fields.personalNotes == "Met in Lund")
            #expect(fields.emails == ["maja@example.org", "ek@example.org"])
            #expect(fields.mobilePhone == "+46 70 111")
            #expect(fields.businessPhones == ["+46 8 222"] && fields.homePhones == ["+46 8 333", "+46 8 444"])
            #expect(fields.home == GraphAddress(street: "Storgatan 1", city: "Lund", postalCode: "222 22",
                                                countryOrRegion: "Sweden"))
            #expect(fields.business == nil && fields.other == nil)
        }
    }

    @Test func contactsInAFolderAreItsOwn() async throws {
        try await withGraph { server, client, _ in
            let family = await server.addFolder("Family")
            await server.put(json(["displayName": "Default"]))
            await server.put(json(["displayName": "Mor"]), in: family)
            let found = try await client.contacts(in: GraphFolder(path: "me/contactFolders/\(family)", name: "Family"))
            #expect(found.map(\.fields.displayName) == ["Mor"])
        }
    }

    @Test func wrongTypesReadAsEmpty() throws {
        let data = json([
            "id": "c1", "@odata.etag": "e", "givenName": 7, "surname": NSNull(), "emailAddresses": "nope",
            "businessPhones": [1, "+46 1"], "homeAddress": ["street": ["x"]], "mobilePhone": ["a"],
        ])
        let contact = try #require(GraphContacts.contact(data))
        #expect(contact.fields.givenName == "" && contact.fields.surname == "")
        #expect(contact.fields.emails.isEmpty && contact.fields.mobilePhone == "")
        #expect(contact.fields.businessPhones == ["+46 1"])
        #expect(contact.fields.home == nil)
    }

    @Test func contactWithoutIdOrETagIsSkipped() throws {
        let page = json(["value": [["displayName": "No id"], ["id": "c1", "@odata.etag": "e1"]]])
        #expect(try GraphContacts.page(page).contacts.map(\.id) == ["c1"])
    }

    @Test func createCarriesTheMarker() async throws {
        try await withGraph { server, client, _ in
            let made = try await client.create(
                GraphContactFields(displayName: "New One", emails: ["new@example.org"]), createID: createID,
                in: .defaultFolder)
            #expect(made.fields.displayName == "New One")
            let post = try #require(await server.requests.last)
            let body = try #require(try JSONSerialization.jsonObject(with: post.body) as? [String: Any])
            let marker = try #require((body["singleValueExtendedProperties"] as? [[String: String]])?.first)
            #expect(marker["id"] == GraphContacts.createMarkerID && marker["value"] == createID)
        }
    }

    @Test func findLooksUpTheMarker() async throws {
        try await withGraph { server, client, _ in
            await server.dropAnswerOfNextPost()
            await #expect(throws: GraphError.net) {
                try await client.create(GraphContactFields(displayName: "Lost"), createID: createID, in: .defaultFolder)
            }
            let found = try #require(try await client.find(createID: createID, in: .defaultFolder))
            #expect(found.fields.displayName == "Lost")
            #expect(try await client.find(createID: "00000000-0000-0000-0000-000000000000", in: .defaultFolder) == nil)
        }
    }

    @Test func findRefusesAnUnsafeCreateID() async throws {
        try await withGraph { _, client, _ in
            await #expect(throws: GraphError.malformed) {
                try await client.find(createID: "x' or 1 eq 1 or '", in: .defaultFolder)
            }
        }
    }

    @Test func updateSendsOnlyOwnProperties() async throws {
        try await withGraph { server, client, _ in
            let id = await server.put(json(fullContact))
            let updated = try await client.update(
                id: id, GraphContactFields(givenName: "Maja", surname: "Berg"), ifMatch: #"W/"1""#)
            #expect(updated.fields.surname == "Berg" && updated.etag == #"W/"2""#)
            let patch = try #require(await server.requests.last)
            #expect(patch.headers["if-match"] == #"W/"1""#)
            let body = try #require(try JSONSerialization.jsonObject(with: patch.body) as? [String: Any])
            #expect(Set(body.keys).isSubset(of: GraphContacts.ownProperties))
            let stored = try #require(await server.contactsJSON().first)
            let object = try #require(try JSONSerialization.jsonObject(with: stored) as? [String: Any])
            #expect(object["jobTitle"] as? String == "Chief")
        }
    }

    @Test func staleUpdateIsAPreconditionFailure() async throws {
        try await withGraph { server, client, _ in
            let id = await server.put(json(fullContact))
            await server.edit(id, "surname", "Elsewhere")
            await #expect(throws: GraphError.preconditionFailed) {
                try await client.update(id: id, GraphContactFields(surname: "Mine"), ifMatch: #"W/"1""#)
            }
        }
    }

    @Test func deleteOfAGoneContactIsDone() async throws {
        try await withGraph { server, client, _ in
            let id = await server.put(json(fullContact))
            try await client.delete(id: id, ifMatch: #"W/"1""#)
            #expect(await server.contactsJSON().isEmpty)
            try await client.delete(id: id, ifMatch: #"W/"1""#)
        }
    }

    @Test func contactByIdIsNilWhenGone() async throws {
        try await withGraph { server, client, _ in
            let id = await server.put(json(fullContact))
            let found = try await client.contact(id: id)
            #expect(found?.id == id)
            await server.remove(id)
            let gone = try await client.contact(id: id)
            #expect(gone == nil)
        }
    }
}
