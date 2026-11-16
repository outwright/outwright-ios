// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightModel
import OutwrightNet
import OutwrightPush
import OutwrightStore
import OutwrightSync
import Synchronization
import Testing

@testable import OutwrightUI

private struct Disabled: Equatable {
    var account: AccountID
    var hadPassword: Bool
}

/// Records each `disable` and whether the account's password was still kept at that moment.
private final class RemovalSwitch: PushSwitching, Sendable {
    private let secrets: InMemorySecretStore
    private let failure: PushError?
    private let calls = Mutex<[Disabled]>([])

    init(secrets: InMemorySecretStore, failure: PushError? = nil) {
        self.secrets = secrets
        self.failure = failure
    }

    var disabled: [Disabled] { calls.withLock { $0 } }
    private let changes = Mutex<[Account]>([])
    var changed: [Account] { changes.withLock { $0 } }

    func accountChanged(_ account: Account) async {
        changes.withLock { $0.append(account) }
    }

    func isEnabled(_ account: AccountID) async -> Bool { true }
    func enable(_ account: Account) async throws(PushError) {}

    func disable(_ account: AccountID) async throws(PushError) {
        let kept = ((try? secrets.password(for: account)) ?? nil) != nil
        calls.withLock { $0.append(Disabled(account: account, hadPassword: kept)) }
        if let failure { throw failure }
    }
}

@MainActor @Suite struct AccountSettingsTests {
    @Test func removingAnAccountForgetsItsPassword() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let bo = try box.addAccount("bo@example.org")
        let secrets = InMemorySecretStore()
        try secrets.setPassword(Secret("pw"), for: anna.id)
        let app = AppModel(store: box.store, sync: offlineSync(store: box.store, secrets: secrets))
        app.open(try box.folder(anna, .inbox).id)
        try await app.removeAccount(anna.id)
        #expect(app.accounts.map(\.id) == [bo.id])
        #expect(try secrets.password(for: anna.id) == nil)
        #expect(app.scope == .allAccounts)
    }

    @Test func removingAnAccountSwitchesItsPushOffFirst() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let secrets = InMemorySecretStore()
        try secrets.setPassword(Secret("pw"), for: anna.id)
        let switcher = RemovalSwitch(secrets: secrets)
        let app = AppModel(store: box.store, sync: offlineSync(store: box.store, secrets: secrets))
        app.push = PushSupport(switcher: switcher, offersPush: { _ in true }, askPermission: { true }, registerForRemote: {})
        try await app.removeAccount(anna.id)
        // Switched off while the password was still there to reach the mail server with.
        #expect(switcher.disabled == [Disabled(account: anna.id, hadPassword: true)])
        #expect(app.accounts.isEmpty)
    }

    @Test func removingAnAccountGoesOnWhenPushCannotBeSwitchedOff() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let secrets = InMemorySecretStore()
        try secrets.setPassword(Secret("pw"), for: anna.id)
        let switcher = RemovalSwitch(secrets: secrets, failure: .timeout)
        let app = AppModel(store: box.store, sync: offlineSync(store: box.store, secrets: secrets))
        app.push = PushSupport(switcher: switcher, offersPush: { _ in true }, askPermission: { true }, registerForRemote: {})
        try await app.removeAccount(anna.id)
        #expect(switcher.disabled.map(\.account) == [anna.id])
        #expect(app.accounts.isEmpty)
        #expect(try secrets.password(for: anna.id) == nil)
    }

    @Test func aChangedAccountReachesPush() async throws {
        var box = try Mailbox()
        var anna = try box.addAccount("anna@example.org")
        let secrets = InMemorySecretStore()
        let switcher = RemovalSwitch(secrets: secrets)
        let app = AppModel(store: box.store, sync: offlineSync(store: box.store, secrets: secrets))
        app.push = PushSupport(switcher: switcher, offersPush: { _ in true }, askPermission: { true }, registerForRemote: {})
        anna.displayName = "Anna Lind"
        try app.updateAccount(anna)
        await app.pushRefresh?.value
        #expect(switcher.changed.map(\.displayName) == ["Anna Lind"])
        #expect(switcher.changed.first?.id == anna.id)
    }

    @Test func signatureAndNameAreSaved() throws {
        var box = try Mailbox()
        var anna = try box.addAccount("anna@example.org")
        let app = AppModel(store: box.store, sync: offlineSync(store: box.store, secrets: InMemorySecretStore()))
        anna.signature = "Anna\nExempel AB"
        anna.displayName = "Anna A"
        try app.updateAccount(anna)
        #expect(app.accounts.first?.signature == "Anna\nExempel AB")
        #expect(try box.store.accounts().first?.displayName == "Anna A")
    }

    @Test func removingAnAccountTellsWhatWouldBeLost() throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let bo = try box.addAccount("bo@example.org")
        let app = AppModel(store: box.store, sync: offlineSync(store: box.store, secrets: InMemorySecretStore()))
        #expect(app.unsentWork(of: anna.id) == UnsentWork(changes: 0, messages: 0))
        let received = try box.add(anna, uid: 1)
        let draft = try box.add(anna, .drafts, uid: 0, subject: "Ut")
        try box.store.apply(.setFlagged(received, true))
        try box.store.apply(.send(draftID: draft))
        #expect(app.unsentWork(of: anna.id) == UnsentWork(changes: 1, messages: 1))
        #expect(app.unsentWork(of: bo.id) == UnsentWork(changes: 0, messages: 0))
    }
}

/// The iPhone's Contacts in memory, with access given or refused.
final class FakePhone: PhoneContacts {
    private let state = Mutex<(names: [String: String], groups: [String: Set<String>], next: Int)>(([:], [:], 1))
    let grants: Bool
    /// Access given at the question but refused when saving (taken back in Settings meanwhile).
    let refusesSaves: Bool

    init(grants: Bool = true, refusesSaves: Bool = false, ownContacts: [String: String] = [:]) {
        self.grants = grants
        self.refusesSaves = refusesSaves
        state.withLock { $0.names = ownContacts }
    }

    /// Phone contact identifiers and their names.
    var names: [String: String] { state.withLock { $0.names } }
    var groupCount: Int { state.withLock { $0.groups.count } }

    func requestAccess() async -> Bool { grants }

    func group(identifier: String?, name: String) throws(SyncError) -> (identifier: String, adopted: Bool) {
        if refusesSaves { throw .phoneContactsDenied }
        return state.withLock { state in
            if let identifier, state.groups[identifier] != nil { return (identifier, false) }
            state.groups[name] = []
            return (name, false)
        }
    }

    func members(ofGroup group: String) throws(SyncError) -> [PhoneMember] {
        state.withLock { state in
            (state.groups[group] ?? []).map { PhoneMember(identifier: $0, name: state.names[$0] ?? "", email: "") }
        }
    }

    func upsert(_ contact: Contact, identifier: String?, group: String, addToGroup: Bool) throws(SyncError) -> String {
        state.withLock { state in
            let key = identifier.flatMap { state.names[$0] == nil ? nil : $0 } ?? "phone-\(state.next)"
            state.next += 1
            state.names[key] = contact.details.name
            state.groups[group, default: []].insert(key)
            return key
        }
    }

    func remove(identifiers: [String], group: String?) throws(SyncError) {
        state.withLock { state in
            for identifier in identifiers {
                state.names[identifier] = nil
                for key in state.groups.keys { state.groups[key]?.remove(identifier) }
            }
            if let group, state.groups[group]?.isEmpty == true { state.groups[group] = nil }
        }
    }
}

@MainActor @Suite struct AccountContactSettingsTests {
    private func fixture(_ phone: FakePhone) throws -> (app: AppModel, account: Account, box: Mailbox) {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org", cardDAV: true)
        try box.store.replaceAddressBooks([(href: "/book/", name: "Contacts", isReadOnly: false)], for: anna.id)
        let book = try #require(try box.store.addressBooks(anna.id).first)
        for name in ["Ann", "Bo"] {
            _ = try box.store.createContact(ContactDetails(givenName: name), in: book.id)
        }
        let sync = offlineSync(store: box.store, secrets: InMemorySecretStore(), phoneContacts: phone)
        return (AppModel(store: box.store, sync: sync), anna, box)
    }

    private func stored(_ box: Mailbox, _ id: AccountID) throws -> Account {
        try #require(try box.store.accounts().first { $0.id == id })
    }

    @Test func confirmingParkedURLStartsUsingIt() throws {
        let (app, anna, box) = try fixture(FakePhone())
        var parked = anna
        parked.cardDAVUnconfirmed = "https://dav.provider.example/dav/"
        try box.store.save(parked)
        app.reloadAccounts()

        try app.confirmCardDAV(anna.id)

        let account = try stored(box, anna.id)
        #expect(account.cardDAV == "https://dav.provider.example/dav/")
        #expect(account.cardDAVUnconfirmed == nil)
        #expect(app.accounts.first?.cardDAV == "https://dav.provider.example/dav/")
    }

    @Test func editedURLReplacesParkedOneAndEmptyMeansNone() throws {
        let (app, anna, box) = try fixture(FakePhone())
        var parked = anna
        parked.cardDAVUnconfirmed = "https://dav.provider.example/dav/"
        try box.store.save(parked)

        try app.setCardDAV(" https://dav.example.org/ ", for: anna.id)
        #expect(try stored(box, anna.id).cardDAV == "https://dav.example.org/")
        #expect(try stored(box, anna.id).cardDAVUnconfirmed == nil)

        #expect(try !stored(box, anna.id).cardDAVOff)

        try app.setCardDAV("", for: anna.id)
        #expect(try stored(box, anna.id).cardDAV == nil)
        #expect(try stored(box, anna.id).cardDAVOff)
    }

    @Test func clearedURLIsNotLookedUpAgain() async throws {
        var box = try Mailbox()
        var anna = try box.addAccount("anna@example.org")
        anna.cardDAV = "https://dav.example.org/"
        try box.store.save(anna)
        let asked = Mutex(0)
        let sync = offlineSync(
            store: box.store, secrets: InMemorySecretStore(), resolver: FixedDoH(answers: [:]),
            probe: { _ in
                asked.withLock { $0 += 1 }
                return URL(string: "https://example.org/dav/")
            })
        let app = AppModel(store: box.store, sync: sync)
        try app.setCardDAV(" ", for: anna.id)
        await sync.refreshContacts(of: anna.id)
        #expect(asked.withLock { $0 } == 0)
        #expect(try stored(box, anna.id).cardDAV == nil)
    }

    @Test func confirmingParkedURLTurnsCardDAVOn() throws {
        let (app, anna, box) = try fixture(FakePhone())
        var off = anna
        off.cardDAVOff = true
        off.cardDAVUnconfirmed = "https://dav.provider.example/dav/"
        try box.store.save(off)
        try app.confirmCardDAV(anna.id)
        #expect(try !stored(box, anna.id).cardDAVOff)
    }

    @Test func savingNameKeepsContactSettings() throws {
        let (app, anna, box) = try fixture(FakePhone())
        var onScreen = anna
        try app.setCardDAV("https://dav.example.org/", for: anna.id)
        onScreen.displayName = "Anna A"
        try app.updateAccount(onScreen)
        #expect(try stored(box, anna.id).displayName == "Anna A")
        #expect(try stored(box, anna.id).cardDAV == "https://dav.example.org/")
    }

    @Test func turningExportOffRemovesExportedContacts() async throws {
        let phone = FakePhone(ownContacts: ["own-1": "Owner's own"])
        let (app, anna, box) = try fixture(phone)

        try await app.setSavesContactsToPhone(true, for: anna.id)
        #expect(Set(phone.names.values) == ["Owner's own", "Ann", "Bo"])
        #expect(try stored(box, anna.id).savesContactsToPhone)

        try await app.setSavesContactsToPhone(false, for: anna.id)
        #expect(phone.names == ["own-1": "Owner's own"])
        #expect(phone.groupCount == 0)
        #expect(try !stored(box, anna.id).savesContactsToPhone)
        #expect(try box.store.phoneExports(anna.id).isEmpty)
    }

    @Test func refusedAccessLeavesExportOff() async throws {
        let phone = FakePhone(grants: false)
        let (app, anna, box) = try fixture(phone)
        await #expect(throws: AccountSettingsError.contactsDenied) {
            try await app.setSavesContactsToPhone(true, for: anna.id)
        }
        #expect(try !stored(box, anna.id).savesContactsToPhone)
        #expect(phone.names.isEmpty)
    }

    @Test func refusalWhileSavingTurnsExportBackOff() async throws {
        let phone = FakePhone(refusesSaves: true)
        let (app, anna, box) = try fixture(phone)
        await #expect(throws: AccountSettingsError.contactsDenied) {
            try await app.setSavesContactsToPhone(true, for: anna.id)
        }
        #expect(try !stored(box, anna.id).savesContactsToPhone)
        #expect(app.accounts.first?.savesContactsToPhone == false)
    }

    @Test func removingAnAccountCountsItsUnsentContactChanges() throws {
        let (app, anna, _) = try fixture(FakePhone())
        #expect(app.unsentWork(of: anna.id) == UnsentWork(changes: 2, messages: 0))
    }

    @Test func blankingTheAddressClearsTheAccountsContactsHere() throws {
        let (app, anna, box) = try fixture(FakePhone())
        #expect(app.unsentContactChanges(of: anna.id) == 2)

        try app.setCardDAV("", for: anna.id)

        #expect(try box.store.contacts(in: nil, matching: nil).isEmpty)
        #expect(try box.store.addressBooks(anna.id).isEmpty)
        #expect(app.unsentContactChanges(of: anna.id) == 0)
    }

    @Test func changedAddressKeepsTheContacts() throws {
        let (app, anna, box) = try fixture(FakePhone())
        try app.setCardDAV("https://dav2.example.org/", for: anna.id)
        #expect(try box.store.contacts(in: nil, matching: nil).count == 2)
    }

    @Test func decliningParkedURLTurnsCardDAVOff() throws {
        let (app, anna, box) = try fixture(FakePhone())
        var parked = anna
        parked.cardDAV = nil
        parked.cardDAVUnconfirmed = "https://dav.provider.example/dav/"
        try box.store.save(parked)
        try app.declineCardDAV(anna.id)
        let account = try stored(box, anna.id)
        #expect(account.cardDAVUnconfirmed == nil)
        #expect(account.cardDAV == nil)
        #expect(account.cardDAVOff)
    }

    @Test func removingAccountRemovesItsExport() async throws {
        let phone = FakePhone(ownContacts: ["own-1": "Owner's own"])
        let (app, anna, box) = try fixture(phone)
        try await app.setSavesContactsToPhone(true, for: anna.id)
        try await app.removeAccount(anna.id)
        #expect(phone.names == ["own-1": "Owner's own"])
        #expect(try box.store.phoneExportAccounts().isEmpty)
    }
}

@MainActor @Suite struct AccountCalendarSettingsTests {
    private func stored(_ fixture: CalendarFixture, _ id: AccountID) throws -> Account {
        try #require(try fixture.store.accounts().first { $0.id == id })
    }

    @Test func confirmingParkedCalDAVStartsUsingIt() throws {
        let fixture = try CalendarFixture()
        let anna = try #require(fixture.box.accounts.first)
        var parked = anna
        parked.calDAV = nil
        parked.calDAVOff = true
        parked.calDAVUnconfirmed = "https://cal.provider.example/dav/"
        try fixture.store.save(parked)
        fixture.app.reloadAccounts()

        try fixture.app.confirmCalDAV(anna.id)

        let account = try stored(fixture, anna.id)
        #expect(account.calDAV == "https://cal.provider.example/dav/")
        #expect(account.calDAVUnconfirmed == nil)
        #expect(!account.calDAVOff)
        #expect(fixture.app.accounts.first?.calDAV == "https://cal.provider.example/dav/")
    }

    @Test func decliningParkedCalDAVTurnsItOff() throws {
        let fixture = try CalendarFixture()
        let anna = try #require(fixture.box.accounts.first)
        var parked = anna
        parked.calDAV = nil
        parked.calDAVUnconfirmed = "https://cal.provider.example/dav/"
        try fixture.store.save(parked)
        fixture.app.reloadAccounts()

        try fixture.app.declineCalDAV(anna.id)

        let account = try stored(fixture, anna.id)
        #expect(account.calDAV == nil)
        #expect(account.calDAVUnconfirmed == nil)
        #expect(account.calDAVOff)
        #expect(try fixture.store.calendars(anna.id).isEmpty, "an account without CalDAV keeps no calendars")
    }

    @Test func blankCalDAVTurnsCalendarsOffAndCountsUnsentChanges() throws {
        let fixture = try CalendarFixture()
        let anna = try #require(fixture.box.accounts.first)
        let id = try fixture.timed("Planning", day: 10, 9)
        try fixture.store.updateEvent(
            id, EventDetails(title: "Moved", start: .utc(fixture.at(day: 10, 10)), end: .utc(fixture.at(day: 10, 11))),
            rule: nil, scope: .event)
        #expect(fixture.app.unsentEventChanges(of: anna.id) == 1)

        try fixture.app.setCalDAV(" https://cal.example.org/ ", for: anna.id)
        #expect(try stored(fixture, anna.id).calDAV == "https://cal.example.org/")
        #expect(try !stored(fixture, anna.id).calDAVOff)
        #expect(try !fixture.store.calendars(anna.id).isEmpty)

        try fixture.app.setCalDAV("", for: anna.id)
        #expect(try stored(fixture, anna.id).calDAV == nil)
        #expect(try stored(fixture, anna.id).calDAVOff)
        #expect(try fixture.store.calendars(anna.id).isEmpty)
        #expect(fixture.app.unsentEventChanges(of: anna.id) == 0)
    }

    @Test func defaultCalendarIsSaved() throws {
        let fixture = try CalendarFixture()
        let family = try fixture.calendar("Family")
        try fixture.app.setDefaultCalendar(family.id)
        #expect(fixture.app.defaultCalendar?.id == family.id)
        #expect(try fixture.store.defaultCalendar()?.id == family.id)
    }

    @Test func turningTheCalendarOffTakesItsRemindersAway() async throws {
        let fixture = try CalendarFixture()
        let anna = try #require(fixture.box.accounts.first)
        let soon = Date().addingTimeInterval(86_400)
        try fixture.add(
            EventDetails(
                title: "Soon", start: .utc(soon), end: .utc(soon.addingTimeInterval(3_600)), reminder: 15))
        await fixture.app.sync.rescheduleReminders()
        #expect(await !fixture.reminders.last.isEmpty)

        try fixture.app.setCalDAV("", for: anna.id)
        await fixture.app.refreshCalendars(anna.id)
        #expect(await fixture.reminders.last.isEmpty, "the cleared calendar's reminders go")
    }

    @Test func removingAnAccountTakesItsRemindersAway() async throws {
        let fixture = try CalendarFixture()
        let anna = try #require(fixture.box.accounts.first)
        let soon = Date().addingTimeInterval(86_400)
        try fixture.add(
            EventDetails(
                title: "Soon", start: .utc(soon), end: .utc(soon.addingTimeInterval(3_600)), reminder: 15))
        await fixture.app.sync.rescheduleReminders()
        #expect(await !fixture.reminders.last.isEmpty)

        try await fixture.app.removeAccount(anna.id)
        #expect(await fixture.reminders.last.isEmpty)
    }

    @Test func removingAnAccountCountsItsUnsentEventChanges() throws {
        let fixture = try CalendarFixture()
        let anna = try #require(fixture.box.accounts.first)
        let id = try fixture.timed("Planning", day: 10, 9)
        try fixture.store.updateEvent(
            id, EventDetails(title: "Moved", start: .utc(fixture.at(day: 10, 10)), end: .utc(fixture.at(day: 10, 11))),
            rule: nil, scope: .event)
        #expect(fixture.app.unsentWork(of: anna.id) == UnsentWork(changes: 1, messages: 0))
    }
}
