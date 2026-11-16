// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightFakes
import OutwrightGraph
import OutwrightModel
import OutwrightStore
import Testing

@testable import OutwrightSync

/// A Microsoft account signed in to the fake token endpoint, with a fake Graph behind it.
struct GraphHarness {
    let microsoft: OAuthAccountHarness
    let graph: FakeGraphServer
    let base: URL

    var store: MailStore { microsoft.mail.store }
    var account: Account { microsoft.account }

    func syncer() -> GraphContactSyncer {
        GraphContactSyncer(
            account: account, store: store, credentials: microsoft.credentials, lock: AccountLock(), base: base,
            session: URLSession(configuration: .ephemeral))
    }

    func names() throws -> [String] {
        try store.contacts(in: nil, matching: nil).map(\.details.name).sorted()
    }
}

func withGraphContacts(_ body: (GraphHarness) async throws -> Void) async throws {
    try await withOAuthAccount { m in
        let graph = FakeGraphServer()
        let base = try await graph.start()
        do {
            try await body(GraphHarness(microsoft: m, graph: graph, base: base))
        } catch {
            await graph.stop()
            throw error
        }
        await graph.stop()
    }
}

func graphJSON(_ object: [String: Any]) -> Data {
    (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
}

@Suite struct GraphContactSyncTests {
    @Test func foldersBecomeAddressBooks() async throws {
        try await withGraphContacts { h in
            let family = await h.graph.addFolder("Family")
            try await h.syncer().sync()
            let books = try h.store.addressBooks(h.account.id)
            #expect(books.map(\.name) == ["Contacts", "Family"])
            #expect(books.map(\.href) == ["me", "me/contactFolders/\(family)"])
            #expect(books.allSatisfy { !$0.isReadOnly })
        }
    }

    @Test func contactsArriveWithDetails() async throws {
        try await withGraphContacts { h in
            await h.graph.put(graphJSON([
                "givenName": "Maja", "surname": "Ek", "companyName": "Ek AB", "personalNotes": "Lund",
                "emailAddresses": [["address": "maja@example.org"]], "mobilePhone": "+46 70 1",
                "businessPhones": ["+46 8 2"], "homePhones": ["+46 8 3"],
                "homeAddress": ["street": "Storgatan 1", "city": "Lund"],
                "businessAddress": ["city": "Malmö"], "otherAddress": ["countryOrRegion": "Sweden"],
            ]))
            try await h.syncer().sync()
            let maja = try #require(try h.store.contacts(in: nil, matching: nil).first)
            let details = maja.details
            #expect(details.givenName == "Maja" && details.familyName == "Ek")
            #expect(details.organization == "Ek AB" && details.note == "Lund")
            #expect(details.emails == [Labeled(label: "other", value: "maja@example.org")])
            #expect(details.phones == [
                Labeled(label: "mobile", value: "+46 70 1"), Labeled(label: "work", value: "+46 8 2"),
                Labeled(label: "home", value: "+46 8 3"),
            ])
            #expect(details.addresses == [
                PostalAddress(label: "home", street: "Storgatan 1", locality: "Lund"),
                PostalAddress(label: "work", locality: "Malmö"), PostalAddress(label: "other", country: "Sweden"),
            ])
            #expect(try h.store.contacts(withEmail: "maja@example.org").count == 1)
        }
    }

    @Test func changedETagIsFetchedAgain() async throws {
        try await withGraphContacts { h in
            let id = await h.graph.put(graphJSON(["givenName": "Bo", "surname": "Berg"]))
            let syncer = h.syncer()
            try await syncer.sync()
            await h.graph.edit(id, "surname", "Björk")
            try await syncer.sync()
            #expect(try h.names() == ["Bo Björk"])
        }
    }

    @Test func contactGoneFromListingIsRemoved() async throws {
        try await withGraphContacts { h in
            let id = await h.graph.put(graphJSON(["displayName": "Gone Soon"]))
            await h.graph.put(graphJSON(["displayName": "Stays"]))
            let syncer = h.syncer()
            try await syncer.sync()
            await h.graph.remove(id)
            try await syncer.sync()
            #expect(try h.names() == ["Stays"])
        }
    }

    @Test func contactWithUnsentChangeIsKept() async throws {
        try await withGraphContacts { h in
            let id = await h.graph.put(graphJSON(["givenName": "Bo", "surname": "Berg"]))
            let syncer = h.syncer()
            try await syncer.sync()
            let bo = try #require(try h.store.contacts(in: nil, matching: nil).first)
            try h.store.updateContact(bo.id, ContactDetails(givenName: "Bo", familyName: "Own"))
            await h.graph.remove(id)
            await h.graph.failNext(status: 503)
            _ = try? await syncer.sync()
            #expect(try h.names() == ["Bo Own"])
        }
    }

    @Test func graph401WithIMAPFineRenewsGraphOnly() async throws {
        try await withGraphContacts { h in
            let source = try h.microsoft.credentials.tokenSource(for: h.account.id, provider: testOAuthProvider)
            let outlook = try await source.accessToken(for: .mail)
            let syncer = h.syncer()
            try await syncer.sync()
            let before = await h.microsoft.oauth.server.requests
            h.microsoft.oauth.offset.value.withLock { $0 = 120 }
            await h.graph.failNext(status: 401)
            try await syncer.sync()
            #expect(await h.microsoft.oauth.server.requests == before + 1)
            #expect(try await source.accessToken(for: .mail).reveal() == outlook.reveal())
        }
    }

    @Test func secondGraph401IsSignInAgain() async throws {
        try await withGraphContacts { h in
            await h.graph.setAcceptedTokens([])
            await #expect(throws: SyncError.needsSignIn(h.account.id)) { try await h.syncer().sync() }
        }
    }

    @Test func passwordAccountIsLeftAlone() async throws {
        try await withGraphContacts { h in
            var plain = h.account
            plain.auth = .password
            plain.calendarVia = .calDAV
            plain.contactsVia = .cardDAV
            let syncer = GraphContactSyncer(
                account: plain, store: h.store, credentials: h.microsoft.credentials, lock: AccountLock(),
                base: h.base, session: URLSession(configuration: .ephemeral))
            try await syncer.sync()
            #expect(await h.graph.requests.isEmpty)
        }
    }

    @Test func mappingRoundTrips() {
        let details = ContactDetails(
            givenName: "Maja", familyName: "Ek", displayName: "Maja Ek", organization: "Ek AB", note: "Note",
            emails: [Labeled(label: "other", value: "a@example.org"), Labeled(label: "other", value: "b@example.org")],
            phones: [Labeled(label: "mobile", value: "1"), Labeled(label: "work", value: "2"),
                     Labeled(label: "work", value: "3"), Labeled(label: "home", value: "4")],
            addresses: [PostalAddress(label: "home", street: "S", locality: "L", region: "R", postalCode: "P",
                                      country: "C"),
                        PostalAddress(label: "work", locality: "W")])
        #expect(GraphContactMapping.details(GraphContactMapping.fields(details)) == details)
    }

    /// The coordinator runs Graph for a Microsoft account, as it runs CardDAV for others.
    @Test func coordinatorSyncsMicrosoftContacts() async throws {
        try await withGraphContacts { h in
            await h.graph.put(graphJSON(["givenName": "Via", "surname": "Coordinator"]))
            let coordinator = SyncCoordinator(
                store: h.store, secrets: h.microsoft.oauth.secrets, tokens: [testOAuthProvider: h.microsoft.oauth.oauth],
                now: { fixedNow }, davSession: URLSession(configuration: .ephemeral), graphBases: [testOAuthProvider: h.base])
            await coordinator.refreshAll()
            let names = try h.names()
            #expect(names == ["Via Coordinator"])
        }
    }

    /// Coming to the front brings the contacts too, not only the Inbox: one added elsewhere shows
    /// without a pull to refresh.
    @Test func comingToTheFrontSyncsContacts() async throws {
        try await withGraphContacts { h in
            await h.graph.put(graphJSON(["givenName": "Via", "surname": "Front"]))
            let coordinator = SyncCoordinator(
                store: h.store, secrets: h.microsoft.oauth.secrets, tokens: [testOAuthProvider: h.microsoft.oauth.oauth],
                now: { fixedNow }, davSession: URLSession(configuration: .ephemeral), graphBases: [testOAuthProvider: h.base])
            await coordinator.startForeground()
            let synced = await eventually { (try? h.names()) == ["Via Front"] }
            await coordinator.stopForeground()
            #expect(synced)
        }
    }

    /// A 401 whose renewal meets the token endpoint's own trouble is the network, not a sign-in.
    @Test func renewalTroubleAfterA401IsNotSignIn() async throws {
        try await withGraphContacts { h in
            let syncer = h.syncer()
            try await syncer.sync()
            await h.graph.failNext(status: 401)
            await h.microsoft.oauth.server.script([FakeHTTPResponse(status: 503)])
            await #expect(throws: SyncError.graph(.net)) { try await syncer.sync() }
        }
    }
}
