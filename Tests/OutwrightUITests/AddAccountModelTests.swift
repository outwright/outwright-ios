// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightFakes
import OutwrightModel
import OutwrightNet
import OutwrightStore
import OutwrightSync
import Synchronization
import Testing

@testable import OutwrightUI

/// Fixed SRV answers.
struct FixedDoH: DoHResolving {
    let answers: [String: [SRVRecord]]

    func srv(_ name: String) async -> [SRVRecord] {
        answers[name] ?? []
    }

    func mx(_ name: String) async -> [MXRecord] { [] }
}

/// Secrets that remember every write.
final class RecordingSecrets: SecretStore {
    private let values = Mutex<[AccountID: Secret]>([:])
    private let tokens = Mutex<[AccountID: Secret]>([:])
    private let writes = Mutex(0)
    private let addresses = Mutex<[UUID: Secret]>([:])

    var writeCount: Int { writes.withLock { $0 } }

    func password(for account: AccountID) throws(SyncError) -> Secret? { values.withLock { $0[account] } }

    func setPassword(_ secret: Secret, for account: AccountID) throws(SyncError) {
        writes.withLock { $0 += 1 }
        values.withLock { $0[account] = secret }
    }

    func refreshToken(for account: AccountID) throws(SyncError) -> Secret? { tokens.withLock { $0[account] } }

    func setRefreshToken(_ secret: Secret, for account: AccountID) throws(SyncError) {
        writes.withLock { $0 += 1 }
        tokens.withLock { $0[account] = secret }
    }

    func remove(for account: AccountID) throws(SyncError) {
        _ = values.withLock { $0.removeValue(forKey: account) }
        _ = tokens.withLock { $0.removeValue(forKey: account) }
    }

    func subscriptionAddress(_ key: UUID) throws(SyncError) -> Secret? { addresses.withLock { $0[key] } }

    func setSubscriptionAddress(_ secret: Secret, for key: UUID) throws(SyncError) {
        addresses.withLock { $0[key] = secret }
    }

    func removeSubscriptionAddress(_ key: UUID) throws(SyncError) {
        _ = addresses.withLock { $0.removeValue(forKey: key) }
    }
}

@MainActor @Suite struct AddAccountModelTests {
    /// No /.well-known/carddav answers: nothing leaves the test.
    private let noProbe: @Sendable (URL) async -> URL? = { _ in nil }
    /// Every DAV address has a calendar or an address book behind it.
    private let found: @Sendable (DAVService, String, Account, Secret) async -> Bool? = { _, _, _, _ in true }

    private func withFakes(_ body: (UInt16, UInt16) async throws -> Void) async throws {
        let imap = FakeIMAPServer()
        let smtp = FakeSMTPServer()
        let imapPort = try await imap.start()
        let smtpPort = try await smtp.start()
        do {
            try await body(imapPort, smtpPort)
        } catch {
            await imap.stop()
            await smtp.stop()
            throw error
        }
        await imap.stop()
        await smtp.stop()
    }

    private func local(_ port: UInt16) -> MailEndpoint {
        MailEndpoint(host: "127.0.0.1", port: port, security: "plainLoopbackOnly")
    }

    @Test func discoverFillsServers() async throws {
        let store = try MailStore(path: nil)
        let resolver = FixedDoH(answers: [
            "_imaps._tcp.example.org": [(target: "mail.example.org.", port: 993, priority: 0)],
            "_submissions._tcp.example.org": [(target: "smtp.example.org", port: 465, priority: 0)],
        ])
        let model = AddAccountModel(store: store, secrets: InMemorySecretStore(), resolver: resolver, collections: found, probe: noProbe)
        model.email = "jk@example.org"
        await model.discover()
        #expect(model.imap == MailEndpoint(host: "mail.example.org", port: 993, security: "tls"))
        #expect(model.smtp == MailEndpoint(host: "smtp.example.org", port: 465, security: "tls"))
        #expect(model.user == "jk@example.org")
        #expect(!model.needsServerConfirmation)

        let elsewhere = AddAccountModel(
            store: store, secrets: InMemorySecretStore(),
            resolver: FixedDoH(answers: ["_imaps._tcp.example.org": [(target: "imap.host.example", port: 993, priority: 0)]]), collections: found, probe: noProbe)
        elsewhere.email = "jk@example.org"
        elsewhere.password = "secret"
        await elsewhere.discover()
        #expect(elsewhere.imap?.host == "imap.host.example")
        #expect(elsewhere.needsServerConfirmation)
        await #expect(throws: AddAccountError.serversNotConfirmed) { _ = try await elsewhere.connect() }
        elsewhere.confirmServers()
        #expect(!elsewhere.needsServerConfirmation)
    }

    @Test func wrongPasswordSavesNothing() async throws {
        try await withFakes { imapPort, smtpPort in
            let store = try MailStore(path: nil)
            let secrets = RecordingSecrets()
            let model = AddAccountModel(store: store, secrets: secrets, resolver: FixedDoH(answers: [:]), collections: found, probe: noProbe)
            model.email = "jk@example.org"
            model.password = "not-the-password"
            model.imap = local(imapPort)
            model.smtp = local(smtpPort)
            await #expect(throws: AddAccountError.signIn(.imap(.authenticationFailed))) { _ = try await model.connect() }
            #expect(try store.accounts().isEmpty)
            #expect(secrets.writeCount == 0)
        }
    }

    @Test func successSavesAccountAndSecret() async throws {
        try await withFakes { imapPort, smtpPort in
            let store = try MailStore(path: nil)
            let secrets = RecordingSecrets()
            let model = AddAccountModel(store: store, secrets: secrets, resolver: FixedDoH(answers: [:]), collections: found, probe: noProbe)
            model.email = "jk@example.org"
            model.name = "Jörgen"
            model.password = FakeIMAPServer.password
            model.imap = local(imapPort)
            model.smtp = local(smtpPort)
            let account = try await model.connect()
            #expect(try store.accounts().map(\.id) == [account.id])
            #expect(account.displayName == "Jörgen")
            #expect(account.user == "jk@example.org")
            #expect(!ComposeModel.signature(of: account).isEmpty)
            #expect(try secrets.password(for: account.id)?.reveal() == FakeIMAPServer.password)
            #expect(secrets.writeCount == 1)
        }
    }

    /// The form redraws when the servers are confirmed: the button goes and Connect opens at once (#57).
    @Test func confirmingTheServersRedrawsWhatReadsThem() async throws {
        let model = AddAccountModel(
            store: try MailStore(path: nil), secrets: InMemorySecretStore(),
            resolver: FixedDoH(answers: ["_imaps._tcp.example.org": [(target: "imap.host.example", port: 993, priority: 0)]]), collections: found, probe: noProbe)
        model.email = "jk@example.org"
        await model.discover()
        let changed = Mutex(false)
        withObservationTracking {
            _ = model.needsServerConfirmation
        } onChange: {
            changed.withLock { $0 = true }
        }
        model.confirmServers()
        #expect(changed.withLock { $0 })
    }

    @Test func changingOnlyThePortStillNeedsConfirmation() async throws {
        let model = AddAccountModel(
            store: try MailStore(path: nil), secrets: InMemorySecretStore(),
            resolver: FixedDoH(answers: ["_imaps._tcp.example.org": [(target: "imap.host.example", port: 993, priority: 0)]]), collections: found, probe: noProbe)
        model.email = "jk@example.org"
        await model.discover()
        model.imap?.port = 1993
        model.imap?.security = "startTLS"
        model.imap?.host = "IMAP.host.example"
        #expect(model.needsServerConfirmation)
        model.confirmServers()
        #expect(!model.needsServerConfirmation)
    }

    @Test func anAddressAlreadyAddedIsRefused() async throws {
        var box = try Mailbox()
        try box.addAccount("jk@example.org")
        let secrets = RecordingSecrets()
        let model = AddAccountModel(store: box.store, secrets: secrets, resolver: FixedDoH(answers: [:]), collections: found, probe: noProbe)
        model.email = "JK@example.org"
        model.password = "secret"
        model.imap = local(1)
        model.smtp = local(2)
        await #expect(throws: AddAccountError.alreadyAdded) { _ = try await model.connect() }
        #expect(secrets.writeCount == 0)
    }

    @Test func cardDAVIsDiscoveredAndSaved() async throws {
        try await withFakes { imapPort, smtpPort in
            let store = try MailStore(path: nil)
            let resolver = FixedDoH(answers: [
                "_carddavs._tcp.example.org": [(target: "dav.example.org", port: 443, priority: 0)]
            ])
            let model = AddAccountModel(
                store: store, secrets: RecordingSecrets(), resolver: resolver,
                collections: found, probe: { url in url.host() == "dav.example.org" ? URL(string: "https://dav.example.org/dav/") : nil })
            model.email = "jk@example.org"
            await model.discover()
            #expect(model.cardDAV == "https://dav.example.org/dav/")
            #expect(!model.needsServerConfirmation)
            model.password = FakeIMAPServer.password
            model.imap = local(imapPort)
            model.smtp = local(smtpPort)
            let account = try await model.connect()
            #expect(try store.accounts().first?.cardDAV == "https://dav.example.org/dav/")
            #expect(try store.accounts().first?.cardDAVOff == false)
            #expect(account.cardDAV == "https://dav.example.org/dav/")
        }
    }

    @Test func emptyCardDAVSavesNone() async throws {
        try await withFakes { imapPort, smtpPort in
            let store = try MailStore(path: nil)
            let model = AddAccountModel(
                store: store, secrets: RecordingSecrets(), resolver: FixedDoH(answers: [:]),
                collections: found, probe: { _ in URL(string: "https://example.org/dav/") })
            model.email = "jk@example.org"
            await model.discover()
            model.cardDAV = "  "
            model.password = FakeIMAPServer.password
            model.imap = local(imapPort)
            model.smtp = local(smtpPort)
            let account = try await model.connect()
            #expect(try store.accounts().first?.cardDAV == nil)
            #expect(try store.accounts().first?.cardDAVOff == true)

            let asked = Mutex(0)
            let sync = offlineSync(
                store: store, secrets: InMemorySecretStore(), resolver: FixedDoH(answers: [:]),
                probe: { _ in
                    asked.withLock { $0 += 1 }
                    return URL(string: "https://example.org/dav/")
                })
            await sync.refreshContacts(of: account.id)
            #expect(asked.withLock { $0 } == 0)
            #expect(try store.accounts().first?.cardDAV == nil)
        }
    }

    @Test func offDomainCardDAVNeedsConfirmation() async throws {
        let resolver = FixedDoH(answers: [
            "_carddavs._tcp.example.org": [(target: "dav.provider.example", port: 443, priority: 0)]
        ])
        let model = AddAccountModel(
            store: try MailStore(path: nil), secrets: RecordingSecrets(), resolver: resolver,
            collections: found, probe: { url in
                url.host() == "dav.provider.example" ? URL(string: "https://dav.provider.example/dav/") : nil
            })
        model.email = "jk@example.org"
        await model.discover()
        #expect(model.cardDAV == "https://dav.provider.example/dav/")
        #expect(model.hostsNeedingConfirmation == ["dav.provider.example"])
        model.password = "secret"
        model.imap = local(1)
        model.smtp = local(2)
        await #expect(throws: AddAccountError.serversNotConfirmed) { _ = try await model.connect() }

        model.cardDAV = "https://contacts.example.org/"
        #expect(!model.needsServerConfirmation)
        model.cardDAV = "https://DAV.provider.example/other/"
        #expect(model.needsServerConfirmation)
        model.confirmServers()
        #expect(!model.needsServerConfirmation)
    }

    @Test func nothingFoundAndLeftOffIsSavedOff() async throws {
        try await withFakes { imapPort, smtpPort in
            let store = try MailStore(path: nil)
            let model = AddAccountModel(
                store: store, secrets: RecordingSecrets(), resolver: FixedDoH(answers: [:]), collections: found, probe: noProbe)
            model.email = "jk@example.org"
            await model.discover()
            #expect(!model.calendarOn)
            #expect(!model.contactsOn)
            model.password = FakeIMAPServer.password
            model.imap = local(imapPort)
            model.smtp = local(smtpPort)
            let account = try await model.connect()
            #expect(account.calDAVOff)
            #expect(account.cardDAVOff)
            #expect(try store.accounts().first?.calDAVOff == true)
        }
    }

    // Switched on with nothing to fill in: a later lookup may still find one.
    @Test func switchedOnBlankWhereNothingWasFoundStaysDiscoverable() async throws {
        try await withFakes { imapPort, smtpPort in
            let store = try MailStore(path: nil)
            let model = AddAccountModel(
                store: store, secrets: RecordingSecrets(), resolver: FixedDoH(answers: [:]), collections: found, probe: noProbe)
            model.email = "jk@example.org"
            await model.discover()
            #expect(model.cardDAV.isEmpty)
            model.contactsOn = true
            model.password = FakeIMAPServer.password
            model.imap = local(imapPort)
            model.smtp = local(smtpPort)
            let account = try await model.connect()
            #expect(try store.accounts().first?.cardDAVOff == false)

            let asked = Mutex(0)
            let sync = offlineSync(
                store: store, secrets: InMemorySecretStore(), resolver: FixedDoH(answers: [:]),
                probe: { _ in
                    asked.withLock { $0 += 1 }
                    return nil
                })
            await sync.refreshContacts(of: account.id)
            #expect(asked.withLock { $0 } > 0)
        }
    }

    @Test func calDAVIsDiscoveredAndSaved() async throws {
        try await withFakes { imapPort, smtpPort in
            let store = try MailStore(path: nil)
            let resolver = FixedDoH(answers: [
                "_caldavs._tcp.example.org": [(target: "cal.example.org", port: 443, priority: 0)]
            ])
            let model = AddAccountModel(
                store: store, secrets: RecordingSecrets(), resolver: resolver,
                collections: found, probe: { url in url.host() == "cal.example.org" ? URL(string: "https://cal.example.org/dav/") : nil })
            model.email = "jk@example.org"
            await model.discover()
            #expect(model.calDAV == "https://cal.example.org/dav/")
            #expect(!model.needsServerConfirmation)
            model.password = FakeIMAPServer.password
            model.imap = local(imapPort)
            model.smtp = local(smtpPort)
            let account = try await model.connect()
            #expect(try store.accounts().first?.calDAV == "https://cal.example.org/dav/")
            #expect(try store.accounts().first?.calDAVOff == false)
            #expect(account.calDAV == "https://cal.example.org/dav/")
        }
    }

    @Test func emptyCalDAVSavesNoneAndStaysOff() async throws {
        try await withFakes { imapPort, smtpPort in
            let store = try MailStore(path: nil)
            let model = AddAccountModel(
                store: store, secrets: RecordingSecrets(), resolver: FixedDoH(answers: [:]),
                collections: found, probe: { _ in URL(string: "https://example.org/dav/") })
            model.email = "jk@example.org"
            await model.discover()
            #expect(model.calDAV == "https://example.org/dav/")
            model.calDAV = " "
            model.password = FakeIMAPServer.password
            model.imap = local(imapPort)
            model.smtp = local(smtpPort)
            _ = try await model.connect()
            #expect(try store.accounts().first?.calDAV == nil)
            #expect(try store.accounts().first?.calDAVOff == true)
        }
    }

    // The lookup asks without a password and only learns the server speaks DAV: Connect asks with it,
    // and what has no calendar or address book behind it is saved off (#60).
    @Test func aDAVAddressWithNothingBehindItIsSavedOff() async throws {
        try await withFakes { imapPort, smtpPort in
            let store = try MailStore(path: nil)
            let asked = Mutex<[DAVService]>([])
            let model = AddAccountModel(
                store: store, secrets: RecordingSecrets(), resolver: FixedDoH(answers: [:]),
                collections: { service, _, _, password in
                    asked.withLock { $0.append(service) }
                    return service == .cardDAV && password.reveal() == FakeIMAPServer.password
                },
                probe: { _ in URL(string: "https://example.org/dav/") })
            model.email = "jk@example.org"
            await model.discover()
            #expect(model.calDAV == "https://example.org/dav/")
            #expect(model.cardDAV == "https://example.org/dav/")
            model.password = FakeIMAPServer.password
            model.imap = local(imapPort)
            model.smtp = local(smtpPort)
            let account = try await model.connect()
            #expect(Set(asked.withLock { $0 }) == [.calDAV, .cardDAV])
            // Kept, so turning the calendar on later uses it.
            #expect(account.calDAV == "https://example.org/dav/")
            #expect(account.calDAVOff)
            #expect(account.cardDAV == "https://example.org/dav/")
            #expect(!account.cardDAVOff)
            #expect(try store.accounts().first?.calDAVOff == true)
        }
    }

    // A check that could not tell (a timeout, a refusal) turns nothing off: sync reports it (review of #60).
    @Test func aDAVAddressThatCouldNotBeAskedStaysOn() async throws {
        try await withFakes { imapPort, smtpPort in
            let store = try MailStore(path: nil)
            let model = AddAccountModel(
                store: store, secrets: RecordingSecrets(), resolver: FixedDoH(answers: [:]),
                collections: { _, _, _, _ in nil }, probe: { _ in URL(string: "https://example.org/dav/") })
            model.email = "jk@example.org"
            await model.discover()
            model.password = FakeIMAPServer.password
            model.imap = local(imapPort)
            model.smtp = local(smtpPort)
            let account = try await model.connect()
            #expect(account.calDAV == "https://example.org/dav/")
            #expect(!account.calDAVOff)
            #expect(account.cardDAV == "https://example.org/dav/")
            #expect(!account.cardDAVOff)
        }
    }

    @Test func offDomainCalDAVNeedsConfirmation() async throws {
        let resolver = FixedDoH(answers: [
            "_caldavs._tcp.example.org": [(target: "cal.provider.example", port: 443, priority: 0)]
        ])
        let model = AddAccountModel(
            store: try MailStore(path: nil), secrets: RecordingSecrets(), resolver: resolver,
            collections: found, probe: { url in
                url.host() == "cal.provider.example" ? URL(string: "https://cal.provider.example/dav/") : nil
            })
        model.email = "jk@example.org"
        await model.discover()
        #expect(model.calDAV == "https://cal.provider.example/dav/")
        #expect(model.hostsNeedingConfirmation == ["cal.provider.example"])
        model.password = "secret"
        model.imap = local(1)
        model.smtp = local(2)
        await #expect(throws: AddAccountError.serversNotConfirmed) { _ = try await model.connect() }

        model.calDAV = "https://calendar.example.org/"
        #expect(!model.needsServerConfirmation)
        model.calDAV = "https://CAL.provider.example/other/"
        #expect(model.needsServerConfirmation)
        model.confirmServers()
        #expect(!model.needsServerConfirmation)
    }

    @Test func whatTheLookupFindsIsSwitchedOn() async throws {
        let model = AddAccountModel(
            store: try MailStore(path: nil), secrets: RecordingSecrets(), resolver: FixedDoH(answers: [:]),
            collections: found, probe: { _ in URL(string: "https://example.org/dav/") })
        model.email = "jk@example.org"
        await model.discover()
        #expect(model.calendarOn)
        #expect(model.contactsOn)

        let nothing = AddAccountModel(
            store: try MailStore(path: nil), secrets: RecordingSecrets(), resolver: FixedDoH(answers: [:]),
            collections: found, probe: noProbe)
        nothing.email = "jk@example.org"
        await nothing.discover()
        #expect(!nothing.calendarOn)
        #expect(!nothing.contactsOn)
        nothing.calDAV = "https://cal.example.org/"
        #expect(nothing.calendarOn)
        #expect(!nothing.contactsOn)
    }

    @Test func aSwitchTurnedOffKeepsTheAddressAndSavesItOff() async throws {
        try await withFakes { imapPort, smtpPort in
            let store = try MailStore(path: nil)
            let asked = Mutex<[DAVService]>([])
            let model = AddAccountModel(
                store: store, secrets: RecordingSecrets(), resolver: FixedDoH(answers: [:]),
                collections: { service, _, _, _ in
                    asked.withLock { $0.append(service) }
                    return true
                },
                probe: { _ in URL(string: "https://example.org/dav/") })
            model.email = "jk@example.org"
            await model.discover()
            model.calendarOn = false
            model.password = FakeIMAPServer.password
            model.imap = local(imapPort)
            model.smtp = local(smtpPort)
            let account = try await model.connect()
            #expect(account.calDAV == "https://example.org/dav/")
            #expect(account.calDAVOff)
            #expect(!account.cardDAVOff)
            #expect(asked.withLock { $0 } == [.cardDAV])
            #expect(try store.accounts().first?.calDAVOff == true)
        }
    }

    @Test func anOffDomainAddressSwitchedOffNeedsNoConfirmation() async throws {
        let resolver = FixedDoH(answers: [
            "_caldavs._tcp.example.org": [(target: "cal.provider.example", port: 443, priority: 0)]
        ])
        let model = AddAccountModel(
            store: try MailStore(path: nil), secrets: RecordingSecrets(), resolver: resolver,
            collections: found, probe: { url in
                url.host() == "cal.provider.example" ? URL(string: "https://cal.provider.example/dav/") : nil
            })
        model.email = "jk@example.org"
        await model.discover()
        #expect(model.needsServerConfirmation)
        model.calendarOn = false
        #expect(!model.needsServerConfirmation)
    }

    // Never allowed, so never kept: turning the calendar on later looks it up again and asks.
    @Test func anOffDomainAddressSwitchedOffIsNotKept() async throws {
        try await withFakes { imapPort, smtpPort in
            let store = try MailStore(path: nil)
            let resolver = FixedDoH(answers: [
                "_caldavs._tcp.example.org": [(target: "cal.provider.example", port: 443, priority: 0)]
            ])
            let model = AddAccountModel(
                store: store, secrets: RecordingSecrets(), resolver: resolver, collections: found,
                probe: { url in
                    url.host() == "cal.provider.example" ? URL(string: "https://cal.provider.example/dav/") : nil
                })
            model.email = "jk@example.org"
            await model.discover()
            model.calendarOn = false
            model.password = FakeIMAPServer.password
            model.imap = local(imapPort)
            model.smtp = local(smtpPort)
            let account = try await model.connect()
            #expect(account.calDAV == nil)
            #expect(account.calDAVOff)
            #expect(try store.accounts().first?.calDAV == nil)
        }
    }
}
