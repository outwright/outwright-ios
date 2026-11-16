// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightModel
import OutwrightNet
import OutwrightStore
@testable import OutwrightSync
import Synchronization
import Testing

/// The iPhone's Contacts app, in memory: contacts and groups, Outwright's and the owner's own.
final class FakePhone: PhoneContacts {
    struct Entry: Equatable {
        var name: String
        var email: String = ""
    }

    struct State {
        var entries: [String: Entry] = [:]
        var groups: [String: (name: String, members: Set<String>)] = [:]
        var next = 1
        var denied = false
    }

    private let state = Mutex(State())

    /// Contacts and groups the owner made in the Contacts app.
    init(ownContacts: [String: Entry] = [:], ownGroups: [String: (name: String, members: Set<String>)] = [:]) {
        state.withLock {
            $0.entries = ownContacts
            $0.groups = ownGroups
        }
    }

    var entries: [String: Entry] { state.withLock { $0.entries } }
    var groupNames: [String] { state.withLock { $0.groups.values.map(\.name).sorted() } }

    func members(named name: String) -> Set<String> {
        state.withLock { $0.groups.values.first { $0.name == name }?.members ?? [] }
    }

    /// What the owner does in the Contacts app.
    func change(_ body: (inout State) -> Void) {
        state.withLock { body(&$0) }
    }

    func requestAccess() async -> Bool { state.withLock { !$0.denied } }

    func group(identifier: String?, name: String) throws(SyncError) -> (identifier: String, adopted: Bool) {
        try state.withLock { (state: inout State) throws(SyncError) -> (identifier: String, adopted: Bool) in
            guard !state.denied else { throw .phoneContactsDenied }
            if let identifier, state.groups[identifier] != nil { return (identifier, false) }
            if let found = state.groups.first(where: { $0.value.name == name })?.key { return (found, true) }
            let made = "group-\(state.next)"
            state.next += 1
            state.groups[made] = (name, [])
            return (made, false)
        }
    }

    func members(ofGroup group: String) throws(SyncError) -> [PhoneMember] {
        try state.withLock { (state: inout State) throws(SyncError) -> [PhoneMember] in
            guard !state.denied else { throw .phoneContactsDenied }
            return (state.groups[group]?.members ?? []).sorted().compactMap { id in
                state.entries[id].map { PhoneMember(identifier: id, name: $0.name, email: $0.email) }
            }
        }
    }

    func upsert(_ contact: Contact, identifier: String?, group: String, addToGroup: Bool) throws(SyncError) -> String {
        try state.withLock { (state: inout State) throws(SyncError) -> String in
            guard !state.denied else { throw .phoneContactsDenied }
            var key = identifier ?? ""
            var add = addToGroup
            if identifier == nil || state.entries[key] == nil {
                key = "phone-\(state.next)"
                state.next += 1
                add = true
            }
            state.entries[key] = Entry(
                name: PhoneExport.phoneName(contact.details),
                email: contact.details.emails.first?.value.lowercased() ?? "")
            if add { state.groups[group]?.members.insert(key) }
            return key
        }
    }

    func remove(identifiers: [String], group: String?) throws(SyncError) {
        try state.withLock { (state: inout State) throws(SyncError) in
            guard !state.denied else { throw .phoneContactsDenied }
            for identifier in identifiers {
                state.entries[identifier] = nil
                for key in state.groups.keys { state.groups[key]?.members.remove(identifier) }
            }
            if let group, state.groups[group]?.members.isEmpty == true { state.groups[group] = nil }
        }
    }
}

private func contact(_ raw: Int64, _ name: String) -> Contact {
    Contact(
        id: ContactID(raw: raw), accountID: AccountID(), addressBookID: AddressBookID(raw: 1),
        details: ContactDetails(givenName: name))
}

/// A store with one account (exporting to the phone or not) and one address book, and a coordinator
/// that never reaches a network.
private struct PhoneFixture {
    let store: MailStore
    let account: Account
    let book: AddressBook
    let phone: FakePhone
    let sync: SyncCoordinator

    init(savesToPhone: Bool = true, phone: FakePhone = FakePhone(), cardDAVOff: Bool = false,
         probe: @escaping @Sendable (URL) async -> URL? = { _ in nil }) throws {
        store = try MailStore(path: nil)
        var account = Account(
            id: AccountID(), displayName: "Anna", email: "anna@example.org", colorIndex: 0,
            imap: MailEndpoint(host: "127.0.0.1", port: 1, security: "plainLoopbackOnly"),
            smtp: MailEndpoint(host: "127.0.0.1", port: 1, security: "plainLoopbackOnly"),
            user: "anna@example.org", signature: "", sortOrder: 0)
        account.savesContactsToPhone = savesToPhone
        // Contacts come only with a CardDAV address (loopback, never asked here).
        account.cardDAV = "http://127.0.0.1:1/"
        try store.save(account)
        try store.replaceAddressBooks([(href: "/book/", name: "Contacts", isReadOnly: false)], for: account.id)
        book = try #require(try store.addressBooks(account.id).first)
        if cardDAVOff {
            account.cardDAV = nil
            account.cardDAVOff = true
            try store.save(account)
        }
        self.account = account
        self.phone = phone
        sync = offlineCoordinator(
            store: store, secrets: InMemorySecretStore(), resolver: FakeDoH(), probe: probe, phoneContacts: phone)
    }

    @discardableResult
    func add(_ name: String) throws -> ContactID {
        try store.createContact(
            ContactDetails(givenName: name, emails: [Labeled(label: "work", value: "\(name.lowercased())@example.org")]),
            in: book.id)
    }

    /// The account's CardDAV address goes from the stored account only (its contacts stay), so a
    /// refresh asks no server and reports only the phone's outcome.
    func withoutCardDAVServer() throws {
        var current = try #require(try store.accounts().first)
        current.cardDAV = nil
        try store.save(current)
    }

    func turn(_ isOn: Bool) throws {
        var current = try #require(try store.accounts().first)
        current.savesContactsToPhone = isOn
        try store.save(current)
    }
}

@Suite struct PhoneExportTests {
    @Test func planAddsChangesAndRemoves() {
        let kept = contact(1, "Ann")
        let added = contact(3, "Cia")
        let plan = PhoneExport.plan(
            exported: [ContactID(raw: 1): "phone-1", ContactID(raw: 2): "phone-2"], wanted: [kept, added])
        #expect(plan.upsert.map(\.0) == [kept, added])
        #expect(plan.upsert.map(\.1) == ["phone-1", nil])
        #expect(plan.remove == ["phone-2"])
    }

    @Test func planRemovesDeletedContacts() async throws {
        let mine = FakePhone.Entry(name: "Owner's own")
        let f = try PhoneFixture(phone: FakePhone(ownContacts: ["own-1": mine]))
        let ann = try f.add("Ann")
        let bo = try f.add("Bo")
        try await f.sync.syncPhoneExport(f.account.id)
        #expect(Set(f.phone.entries.values.map(\.name)) == ["Owner's own", "Ann", "Bo"])
        let annOnPhone = try #require(try f.store.phoneExports(f.account.id)[ann])
        #expect(f.phone.members(named: "anna@example.org").count == 2)

        try f.store.deleteContact(bo)
        try f.store.updateContact(
            ann, ContactDetails(givenName: "Ann", familyName: "Ek", emails: [Labeled(label: "", value: "ann@example.org")]))
        try await f.sync.syncPhoneExport(f.account.id)

        #expect(f.phone.entries == ["own-1": mine, annOnPhone: FakePhone.Entry(name: "Ann Ek", email: "ann@example.org")])
        #expect(try f.store.phoneExports(f.account.id) == [ann: annOnPhone])
    }

    @Test func removingAccountRemovesItsExport() async throws {
        let mine = FakePhone.Entry(name: "Owner's own")
        let f = try PhoneFixture(phone: FakePhone(ownContacts: ["own-1": mine]))
        try f.add("Ann")
        try f.add("Bo")
        try await f.sync.syncPhoneExport(f.account.id)
        #expect(f.phone.entries.count == 3)

        try f.store.removeAccount(f.account.id)
        await f.sync.refreshAll()

        #expect(f.phone.entries == ["own-1": mine])
        #expect(f.phone.groupNames.isEmpty)
        #expect(try f.store.phoneExportAccounts().isEmpty)
    }

    @Test func ownersGroupOfExportedContactsSurvivesTurningOff() async throws {
        let f = try PhoneFixture(phone: FakePhone(ownGroups: ["family": ("Family", [])]))
        try f.add("Ann")
        try await f.sync.syncPhoneExport(f.account.id)
        let ann = try #require(f.phone.entries.first { $0.value.name == "Ann" }?.key)
        f.phone.change { $0.groups["family"]?.members.insert(ann) }

        try f.turn(false)
        try await f.sync.syncPhoneExport(f.account.id)

        #expect(f.phone.entries.isEmpty)
        #expect(f.phone.groupNames == ["Family"])
        #expect(try f.store.phoneExportGroup(f.account.id) == nil)
    }

    @Test func exportedContactReturnsToTheGroup() async throws {
        let f = try PhoneFixture()
        try f.add("Ann")
        try await f.sync.syncPhoneExport(f.account.id)
        let ann = try #require(f.phone.entries.first?.key)

        f.phone.change { state in
            for key in state.groups.keys { state.groups[key]?.members.remove(ann) }
        }
        try await f.sync.syncPhoneExport(f.account.id)
        #expect(f.phone.members(named: "anna@example.org") == [ann])

        f.phone.change { $0.groups = [:] }
        try await f.sync.syncPhoneExport(f.account.id)
        #expect(f.phone.members(named: "anna@example.org") == [ann])
        #expect(f.phone.entries.count == 1)
    }

    @Test func emptyGroupGoesWhenItsContactsAreAlreadyGone() async throws {
        let f = try PhoneFixture()
        try f.add("Ann")
        try await f.sync.syncPhoneExport(f.account.id)
        f.phone.change { state in
            state.entries = [:]
            for key in state.groups.keys { state.groups[key]?.members = [] }
        }

        try f.turn(false)
        try await f.sync.syncPhoneExport(f.account.id)

        #expect(f.phone.groupNames.isEmpty)
        #expect(try f.store.phoneExportAccounts().isEmpty)
    }

    @Test func groupFoundByNameIsAdoptedWithOnlyMatchingMembers() async throws {
        let annOnPhone = FakePhone.Entry(name: "Ann", email: "ann@example.org")
        let zed = FakePhone.Entry(name: "Zed", email: "zed@example.org")
        let namesake = FakePhone.Entry(name: "Bo", email: "other@example.org")
        let f = try PhoneFixture(phone: FakePhone(
            ownContacts: ["old-ann": annOnPhone, "zed": zed, "namesake": namesake],
            ownGroups: ["old": ("anna@example.org", ["old-ann", "zed", "namesake"])]))
        let ann = try f.add("Ann")
        let bo = try f.add("Bo")

        try await f.sync.syncPhoneExport(f.account.id)

        let exported = try f.store.phoneExports(f.account.id)
        #expect(exported[ann] == "old-ann")
        #expect(exported[bo].map { $0 != "namesake" } == true)
        #expect(f.phone.entries.count == 4)
        #expect(try f.store.phoneExportGroup(f.account.id) == "old")

        try f.turn(false)
        try await f.sync.syncPhoneExport(f.account.id)
        #expect(f.phone.entries == ["zed": zed, "namesake": namesake])
        #expect(f.phone.members(named: "anna@example.org") == ["zed", "namesake"])
    }

    @Test func adoptionNeverClaimsAnotherAccountsCopy() async throws {
        let copy = FakePhone.Entry(name: "Ann", email: "ann@example.org")
        let f = try PhoneFixture(phone: FakePhone(
            ownContacts: ["home-ann": copy], ownGroups: ["old": ("anna@example.org", ["home-ann"])]))
        let home = Account(
            id: AccountID(), displayName: "Home", email: "home@example.org", colorIndex: 1,
            imap: f.account.imap, smtp: f.account.smtp, user: "home@example.org", signature: "", sortOrder: 1)
        try f.store.save(home)
        try f.store.setPhoneExport("home-ann", for: ContactID(raw: 999), account: home.id)
        let ann = try f.add("Ann")

        try await f.sync.syncPhoneExport(f.account.id)

        #expect(try f.store.phoneExports(f.account.id)[ann].map { $0 != "home-ann" } == true)
        #expect(f.phone.entries["home-ann"] == copy)
    }

    @Test func refusedAccessIsReportedOncePerChange() async throws {
        let f = try PhoneFixture()
        try f.add("Ann")
        try await f.sync.syncPhoneExport(f.account.id)
        f.phone.change { $0.denied = true }
        try f.turn(false)
        try f.withoutCardDAVServer()

        #expect(await f.sync.refreshContacts(f.account.id) == .phoneContactsDenied)
        #expect(await f.sync.refreshContacts(f.account.id) == nil)
        await #expect(throws: SyncError.phoneContactsDenied) { try await f.sync.syncPhoneExport(f.account.id) }
        #expect(await f.sync.refreshContacts(f.account.id) == nil)
        #expect(try f.store.phoneExports(f.account.id).count == 1)

        f.phone.change { $0.denied = false }
        try await f.sync.syncPhoneExport(f.account.id)
        #expect(f.phone.entries.isEmpty)
    }

    @Test func accountNotSavingToPhoneExportsNothing() async throws {
        let f = try PhoneFixture(savesToPhone: false)
        try f.add("Ann")
        try await f.sync.syncPhoneExport(f.account.id)
        #expect(f.phone.entries.isEmpty)
        #expect(f.phone.groupNames.isEmpty)
    }

    @Test func accountWithCardDAVTurnedOffIsNotLookedUp() async throws {
        let asked = Mutex(0)
        let f = try PhoneFixture(cardDAVOff: true) { _ in
            asked.withLock { $0 += 1 }
            return URL(string: "https://example.org/dav/")
        }
        _ = await f.sync.refreshContacts(f.account.id)
        #expect(asked.withLock { $0 } == 0)
        #expect(try f.store.accounts().first?.cardDAV == nil)
    }

    @Test func contactsOnlyRefreshLeavesMailAlone() async throws {
        try await withContacts { h in
            let book = await h.server.addBook("Work")
            await h.server.putCard(card("a", given: "Ann", family: "Ek"), uid: "a", in: book)
            let sync = offlineCoordinator(store: h.store, secrets: h.secrets, resolver: FakeDoH(), probe: { _ in nil })
            await sync.refreshContacts(of: h.account.id)
            let names = try h.names()
            #expect(names == ["Ann Ek"])
            #expect(await sync.lastErrors[h.account.id] == nil)
        }
    }

    @Test func contactSyncIsFollowedByTheExport() async throws {
        try await withContacts { h in
            var account = h.account
            account.savesContactsToPhone = true
            try h.store.save(account)
            let book = await h.server.addBook("Work")
            await h.server.putCard(card("a", given: "Ann", family: "Ek"), uid: "a", in: book)
            let phone = FakePhone()
            let sync = offlineCoordinator(
                store: h.store, secrets: h.secrets, resolver: FakeDoH(), probe: { _ in nil }, phoneContacts: phone)

            await sync.refreshAll()

            #expect(phone.entries.values.map(\.name) == ["Ann Ek"])
            #expect(try h.store.phoneExports(account.id).count == 1)
        }
    }
}
