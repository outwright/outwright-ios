// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightGraph
import OutwrightIMAP
import OutwrightModel
import OutwrightNet
import OutwrightSetup
import GRDB
@testable import OutwrightStore
import Synchronization
import Testing

@testable import OutwrightSync

/// A provider with OAuth accounts, registered under a client id of its own.
struct ClientProvider: Provider {
    let id: ProviderID
    let tokens: (any TokenRefreshing)? = nil
    let graphBase: URL? = nil
    let oauthClientID: String?
}

/// Secrets in memory that refuse a password for one account, as a keychain that fails would.
final class RefusingSecretStore: SecretStore {
    let inner = InMemorySecretStore()
    let refused: AccountID

    init(refusing refused: AccountID) { self.refused = refused }

    func password(for account: AccountID) throws(SyncError) -> Secret? { try inner.password(for: account) }
    func setPassword(_ secret: Secret, for account: AccountID) throws(SyncError) {
        guard account != refused else { throw .keychain(-25_300) }
        try inner.setPassword(secret, for: account)
    }
    func refreshToken(for account: AccountID) throws(SyncError) -> Secret? { try inner.refreshToken(for: account) }
    func setRefreshToken(_ secret: Secret, for account: AccountID) throws(SyncError) {
        try inner.setRefreshToken(secret, for: account)
    }
    func remove(for account: AccountID) throws(SyncError) { try inner.remove(for: account) }
    func subscriptionAddress(_ key: UUID) throws(SyncError) -> Secret? { try inner.subscriptionAddress(key) }
    func setSubscriptionAddress(_ secret: Secret, for key: UUID) throws(SyncError) {
        try inner.setSubscriptionAddress(secret, for: key)
    }
    func removeSubscriptionAddress(_ key: UUID) throws(SyncError) { try inner.removeSubscriptionAddress(key) }
    func setupMemory() throws(SyncError) -> Secret? { try inner.setupMemory() }
    func setSetupMemory(_ secret: Secret) throws(SyncError) { try inner.setSetupMemory(secret) }
}

func setupAccount(_ email: String, auth: AccountAuth = .password, provider: ProviderID = .ownServer) -> Account {
    Account(
        id: AccountID(), displayName: "Owner", email: email, colorIndex: 2,
        imap: MailEndpoint(host: "imap.example.org", port: 993, security: "tls"),
        smtp: MailEndpoint(host: "smtp.example.org", port: 465, security: "tls"),
        user: email, signature: "-- \nOwner", sortOrder: 1, calDAV: "https://dav.example.org/",
        auth: auth, provider: provider)
}

/// An account as JSON with sorted keys, to compare whole values.
func encoded(_ account: Account) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try #require(String(bytes: try encoder.encode(account), encoding: .utf8))
}

let cloud = ProviderID(raw: "cloud")

func accountItem(_ label: String) -> SetupItem { SetupItem(kind: .account, label: label) }

@Suite struct AccountsSetupPartTests {
    /// The sending device: a password account and an OAuth account with its refresh token.
    struct Sender {
        let store: MailStore
        let secrets = InMemorySecretStore()
        let password = setupAccount("pat@example.org")
        let oauth = setupAccount("olle@example.org", auth: .oauth, provider: cloud)

        init() throws {
            store = try MailStore(path: nil)
            try store.save(password)
            try store.save(oauth)
            try secrets.setPassword(Secret("hunter2"), for: password.id)
            try secrets.setRefreshToken(Secret("refresh-1"), for: oauth.id)
        }

        func content(clientID: String? = "client-a") async throws -> Data {
            let providers = ProviderSet([OwnServerProvider(), ClientProvider(id: cloud, oauthClientID: clientID)])
            return try await AccountsSetupPart(store: store, secrets: secrets, providers: providers).export()
        }
    }

    func receiver(
        store: MailStore, secrets: any SecretStore, clientID: String? = "client-a", withCloud: Bool = true,
        lastError: SyncError? = nil
    ) -> AccountsSetupPart {
        let cloudProvider: [any Provider] = withCloud ? [ClientProvider(id: cloud, oauthClientID: clientID)] : []
        return AccountsSetupPart(
            store: store, secrets: secrets, providers: ProviderSet([OwnServerProvider()] + cloudProvider),
            lastError: { _ in lastError })
    }

    @Test func accountsMoveWithTheirSecrets() async throws {
        let sender = try Sender()
        let content = try await sender.content()
        let store = try MailStore(path: nil)
        let secrets = InMemorySecretStore()
        let part = receiver(store: store, secrets: secrets)

        #expect(try part.summary(of: content).map(\.label).sorted() == ["olle@example.org", "pat@example.org"])
        let report = await part.importContent(content, version: part.version)

        #expect(report.added.count == 2)
        #expect(report.skipped.isEmpty)
        #expect(report.signInAgain.isEmpty)
        let restored = try store.accounts()
        #expect(try restored.map(encoded).sorted() == [sender.password, sender.oauth].map(encoded).sorted())
        #expect(try secrets.password(for: sender.password.id)?.reveal() == "hunter2")
        #expect(try secrets.refreshToken(for: sender.oauth.id)?.reveal() == "refresh-1")
    }

    @Test func notificationSwitchesMoveWithAddedAccountsOnly() async throws {
        let sender = try Sender()
        try sender.store.setNotifiesNewMail(true, for: sender.password.id)
        let providers = ProviderSet([OwnServerProvider(), ClientProvider(id: cloud, oauthClientID: "client-a")])
        // The OAuth account is on through push, which the store does not know.
        let oauthID = sender.oauth.id
        let content = try await AccountsSetupPart(
            store: sender.store, secrets: sender.secrets, providers: providers,
            pushEnabled: { $0 == oauthID }
        ).export()

        let store = try MailStore(path: nil)
        let part = receiver(store: store, secrets: InMemorySecretStore())
        _ = await part.importContent(content, version: 1)
        #expect(try store.notifiesNewMail(sender.password.id))
        #expect(try store.notifiesNewMail(sender.oauth.id))

        // An account the device already has keeps its own switch.
        let other = try MailStore(path: nil)
        let own = setupAccount("pat@example.org")
        try other.save(own)
        _ = await receiver(store: other, secrets: InMemorySecretStore()).importContent(content, version: 1)
        #expect(try !other.notifiesNewMail(own.id))
        #expect(try !other.notifiesNewMail(sender.password.id))
    }

    @Test func aSwitchThatCannotBeSetIsReported() async throws {
        let sender = try Sender()
        try sender.store.setNotifiesNewMail(true, for: sender.password.id)
        let content = try await sender.content()
        let store = try MailStore(path: nil)
        try await store.queue.write { try $0.execute(sql: "DROP TABLE new_mail_notice") }

        let report = await receiver(store: store, secrets: InMemorySecretStore()).importContent(content, version: 1)

        #expect(report.added.count == 2)
        #expect(report.notificationsOff == [accountItem("pat@example.org")])
        #expect(try store.accounts().count == 2)
    }

    @Test func accountsWithoutASwitchStayOff() async throws {
        let sender = try Sender()
        let store = try MailStore(path: nil)
        _ = await receiver(store: store, secrets: InMemorySecretStore())
            .importContent(try await sender.content(), version: 1)
        #expect(try store.newMailNoticeAccounts().isEmpty)
    }

    @Test func existingAddressIsSkipped() async throws {
        let sender = try Sender()
        let content = try await sender.content()
        let store = try MailStore(path: nil)
        try store.save(setupAccount("PAT@example.org"))
        let secrets = InMemorySecretStore()

        let report = await receiver(store: store, secrets: secrets).importContent(content, version: 1)

        #expect(report.skipped == [SetupSkip(item: accountItem("pat@example.org"), reason: .alreadyHere)])
        #expect(report.added == [accountItem("olle@example.org")])
        #expect(try secrets.password(for: sender.password.id) == nil)
        #expect(try store.accounts().count == 2)
    }

    @Test func providerMissingIsSkipped() async throws {
        let content = try await Sender().content()
        let store = try MailStore(path: nil)

        let report = await receiver(store: store, secrets: InMemorySecretStore(), withCloud: false)
            .importContent(content, version: 1)

        #expect(report.skipped == [SetupSkip(item: accountItem("olle@example.org"), reason: .notInThisBuild)])
        #expect(try store.accounts().map(\.email) == ["pat@example.org"])
    }

    @Test func otherClientIDAsksToSignInAgain() async throws {
        let sender = try Sender()
        let content = try await sender.content(clientID: "client-a")
        let store = try MailStore(path: nil)
        let secrets = InMemorySecretStore()

        let part = receiver(store: store, secrets: secrets, clientID: "client-b")
        let report = await part.importContent(content, version: 1)

        let olle = accountItem("olle@example.org")
        #expect(report.added.contains(olle))
        #expect(report.signInAgain == [olle])
        #expect(try secrets.refreshToken(for: sender.oauth.id) == nil)
        #expect(try store.accounts().count == 2)
    }

    @Test func failedAccountRollsBack() async throws {
        let sender = try Sender()
        let content = try await sender.content()
        let store = try MailStore(path: nil)
        let secrets = RefusingSecretStore(refusing: sender.password.id)

        let report = await receiver(store: store, secrets: secrets).importContent(content, version: 1)

        #expect(report.skipped == [SetupSkip(item: accountItem("pat@example.org"), reason: .failed)])
        #expect(report.added == [accountItem("olle@example.org")])
        #expect(try store.accounts().map(\.email) == ["olle@example.org"])
    }

    @Test func restoredAccountsGoAfterTheDevicesOwn() async throws {
        let sender = try Sender()
        let content = try await sender.content()
        let store = try MailStore(path: nil)
        var own = setupAccount("own@example.org")
        own.sortOrder = 5
        try store.save(own)

        _ = await receiver(store: store, secrets: InMemorySecretStore()).importContent(content, version: 1)

        let bundleOrder = try sender.store.accounts().map(\.email)
        #expect(try store.accounts().map(\.email) == ["own@example.org"] + bundleOrder)
    }

    @Test func accountThatCannotBeRemovedIsReportedAsHere() async throws {
        let sender = try Sender()
        let content = try await sender.content()
        let store = try MailStore(path: nil)
        try await store.queue.write { database in
            try database.execute(
                sql: "CREATE TRIGGER keep_accounts BEFORE DELETE ON account BEGIN SELECT RAISE(ABORT, 'kept'); END")
        }
        let secrets = RefusingSecretStore(refusing: sender.password.id)

        let report = await receiver(store: store, secrets: secrets).importContent(content, version: 1)

        let pat = accountItem("pat@example.org")
        #expect(report.skipped.isEmpty)
        #expect(report.added.contains(pat))
        #expect(report.signInAgain == [pat])
        #expect(try store.accounts().map(\.email).contains("pat@example.org"))
    }

    @Test func newerPartIsNotInThisBuild() async throws {
        let content = try await Sender().content()
        let store = try MailStore(path: nil)
        let part = receiver(store: store, secrets: InMemorySecretStore())

        let report = await part.importContent(content, version: part.version + 1)

        #expect(report.added.isEmpty)
        #expect(report.skipped.map(\.reason) == [.notInThisBuild])
        #expect(try store.accounts().isEmpty)
    }

    /// The part's content comes from an opened file: arbitrary bytes and arbitrary JSON are read
    /// without a trap, and nothing half-read is kept.
    @Test func arbitraryContentIsReadWithoutATrap() async throws {
        let valid = try await Sender().content()
        var random = SystemRandomNumberGenerator()
        let store = try MailStore(path: nil)
        let parts: [any SetupPart] = [
            receiver(store: store, secrets: InMemorySecretStore()),
            SubscriptionsSetupPart(store: store, secrets: InMemorySecretStore())
        ]
        for round in 0..<300 {
            var bytes: [UInt8]
            if round.isMultiple(of: 2) {
                let count = Int.random(in: 0...512, using: &random)
                bytes = (0..<count).map { _ in UInt8.random(in: 0...255, using: &random) }
            } else {
                bytes = [UInt8](valid)
                for _ in 0..<Int.random(in: 1...8, using: &random) {
                    guard !bytes.isEmpty else { break }
                    let position = Int.random(in: 0..<bytes.count, using: &random)
                    bytes[position] = UInt8.random(in: 0...255, using: &random)
                }
            }
            for part in parts {
                _ = try? part.summary(of: Data(bytes))
                _ = await part.importContent(Data(bytes), version: part.version)
            }
        }
        for account in try store.accounts() {
            #expect(!account.email.isEmpty)
        }
    }

    /// A device restored from an iCloud or Finder backup has its accounts but not their secrets
    /// (the keychain stays with the old phone): the file fills them in and changes nothing else.
    @Test func anAccountHereWithoutItsSecretGetsItFilledIn() async throws {
        let sender = try Sender()
        let content = try await sender.content()
        let store = try MailStore(path: nil)
        var password = sender.password
        password.displayName = "Chosen here"
        try store.save(password)
        try store.save(sender.oauth)
        let secrets = InMemorySecretStore()

        let report = await receiver(store: store, secrets: secrets).importContent(content, version: 1)

        #expect(Set(report.restored) == [accountItem("pat@example.org"), accountItem("olle@example.org")])
        #expect(report.added.isEmpty)
        #expect(report.skipped.isEmpty)
        #expect(try secrets.password(for: sender.password.id)?.reveal() == "hunter2")
        #expect(try secrets.refreshToken(for: sender.oauth.id)?.reveal() == "refresh-1")
        #expect(try store.accounts().first { $0.id == sender.password.id }?.displayName == "Chosen here")
        #expect(try store.accounts().count == 2)
    }

    @Test func anAccountHereWithItsSecretIsLeftAsItIs() async throws {
        let sender = try Sender()
        let content = try await sender.content()
        let store = try MailStore(path: nil)
        try store.save(sender.password)
        let secrets = InMemorySecretStore()
        try secrets.setPassword(Secret("chosen here"), for: sender.password.id)

        let report = await receiver(store: store, secrets: secrets).importContent(content, version: 1)

        #expect(report.restored.isEmpty)
        #expect(report.skipped == [SetupSkip(item: accountItem("pat@example.org"), reason: .alreadyHere)])
        #expect(try secrets.password(for: sender.password.id)?.reveal() == "chosen here")
    }

    /// A token issued to another client id is never filled in: the owner signs in again as before.
    @Test func aTokenForAnotherClientIsNotFilledIn() async throws {
        let sender = try Sender()
        let content = try await sender.content(clientID: "client-a")
        let store = try MailStore(path: nil)
        try store.save(sender.oauth)
        let secrets = InMemorySecretStore()

        let report = await receiver(store: store, secrets: secrets, clientID: "client-b")
            .importContent(content, version: 1)

        #expect(report.restored.isEmpty)
        #expect(report.skipped.contains(SetupSkip(item: accountItem("olle@example.org"), reason: .alreadyHere)))
        #expect(try secrets.refreshToken(for: sender.oauth.id) == nil)
    }

    /// The same address under another id is another account: nothing of it is filled in.
    @Test func theSameAddressUnderAnotherIdIsNotFilledIn() async throws {
        let sender = try Sender()
        let content = try await sender.content()
        let store = try MailStore(path: nil)
        let own = setupAccount("pat@example.org")
        try store.save(own)
        let secrets = InMemorySecretStore()

        let report = await receiver(store: store, secrets: secrets).importContent(content, version: 1)

        #expect(report.restored.isEmpty)
        #expect(try secrets.password(for: own.id) == nil)
    }
}

/// Differences: an account on the device whose secret differs from the file's, for the owner to choose.
extension AccountsSetupPartTests {
    @Test func aChangedPasswordIsADifference() async throws {
        let sender = try Sender()
        let content = try await sender.content()
        let store = try MailStore(path: nil)
        try store.save(sender.password)
        try store.save(sender.oauth)
        let secrets = InMemorySecretStore()
        try secrets.setPassword(Secret("chosen here"), for: sender.password.id)
        try secrets.setRefreshToken(Secret("refresh-1"), for: sender.oauth.id)
        let part = receiver(store: store, secrets: secrets)

        let differences = await part.differences(in: content)

        #expect(differences.map(\.kind) == [.accountSecret])
        #expect(differences.map(\.label) == ["pat@example.org"])
        #expect(differences.map(\.id) == ["password:pat@example.org"])
        #expect(!differences.contains { "\($0)".contains("hunter2") || "\($0)".contains("chosen here") })
    }

    @Test func theSamePasswordIsNoDifference() async throws {
        let sender = try Sender()
        let content = try await sender.content()
        let store = try MailStore(path: nil)
        try store.save(sender.password)
        let secrets = InMemorySecretStore()
        try secrets.setPassword(Secret("hunter2"), for: sender.password.id)

        #expect(await receiver(store: store, secrets: secrets).differences(in: content).isEmpty)
    }

    /// Today's rule stays: a secret the device lacks is filled in without asking.
    @Test func aMissingPasswordIsFilledInNotADifference() async throws {
        let sender = try Sender()
        let content = try await sender.content()
        let store = try MailStore(path: nil)
        try store.save(sender.password)
        let secrets = InMemorySecretStore()
        let part = receiver(store: store, secrets: secrets)

        #expect(await part.differences(in: content).isEmpty)
        let report = await part.importContent(content, version: 1, replacing: [])
        #expect(report.restored.contains(accountItem("pat@example.org")))
        #expect(try secrets.password(for: sender.password.id)?.reveal() == "hunter2")
    }

    @Test func anAccountWhoseProviderIsMissingHasNoDifference() async throws {
        let sender = try Sender()
        let content = try await sender.content()
        let store = try MailStore(path: nil)
        try store.save(sender.oauth)
        let secrets = InMemorySecretStore()
        try secrets.setRefreshToken(Secret("refresh-here"), for: sender.oauth.id)
        let part = receiver(store: store, secrets: secrets, withCloud: false)

        #expect(await part.differences(in: content).isEmpty)
        _ = await part.importContent(content, version: 1, replacing: ["password:olle@example.org"])
        #expect(try secrets.refreshToken(for: sender.oauth.id)?.reveal() == "refresh-here")
    }

    /// A token issued to another client id is no choice: the device's stays.
    @Test func aTokenForAnotherClientIsNoDifference() async throws {
        let sender = try Sender()
        let content = try await sender.content(clientID: "client-a")
        let store = try MailStore(path: nil)
        try store.save(sender.oauth)
        let secrets = InMemorySecretStore()
        try secrets.setRefreshToken(Secret("refresh-here"), for: sender.oauth.id)
        let part = receiver(store: store, secrets: secrets, clientID: "client-b")

        #expect(await part.differences(in: content).isEmpty)
        _ = await part.importContent(content, version: 1, replacing: ["password:olle@example.org"])
        #expect(try secrets.refreshToken(for: sender.oauth.id)?.reveal() == "refresh-here")
    }

    /// The same address added by hand on this device, under an id of its own: the owner may still
    /// take the file's password for it.
    @Test func theSameAddressUnderAnotherIdCanTakeTheFilesPassword() async throws {
        let sender = try Sender()
        let content = try await sender.content()
        let store = try MailStore(path: nil)
        let own = setupAccount("Pat@Example.org")
        try store.save(own)
        let secrets = InMemorySecretStore()
        try secrets.setPassword(Secret("chosen here"), for: own.id)
        let part = receiver(store: store, secrets: secrets)

        // Its user name was typed in another case here, which is the server details' own question.
        #expect(await part.differences(in: content).map(\.id) == ["password:pat@example.org", "servers:pat@example.org"])
        let report = await part.importContent(content, version: 1, replacing: ["password:pat@example.org"])

        #expect(report.replaced == [accountItem("pat@example.org")])
        #expect(try secrets.password(for: own.id)?.reveal() == "hunter2")
        #expect(try store.accounts().filter { $0.email.lowercased() == "pat@example.org" }.map(\.id) == [own.id])
    }
}

extension AccountsSetupPartTests {
    /// The keychain refuses the file's password: nothing is replaced and the device's stays.
    @Test func aRefusedReplacementKeepsTheDevicesSecret() async throws {
        let sender = try Sender()
        let content = try await sender.content()
        let store = try MailStore(path: nil)
        try store.save(sender.password)
        // The file's other account is here already, so nothing else changes.
        try store.save(sender.oauth)
        let secrets = RefusingSecretStore(refusing: sender.password.id)
        try secrets.inner.setPassword(Secret("chosen here"), for: sender.password.id)
        try secrets.inner.setRefreshToken(Secret("refresh-1"), for: sender.oauth.id)

        let report = await receiver(store: store, secrets: secrets)
            .importContent(content, version: 1, replacing: ["password:pat@example.org"])

        #expect(report.replaced.isEmpty)
        #expect(report.skipped.contains(SetupSkip(item: accountItem("pat@example.org"), reason: .failed)))
        #expect(!report.changedAnything)
        #expect(try secrets.password(for: sender.password.id)?.reveal() == "chosen here")
    }

    /// The device's sign-in is refused: the owner may take the file's token instead.
    @Test(arguments: [SyncError.needsSignIn(AccountID(raw: UUID())), .imap(.authenticationFailed)])
    func replacingARefusedSignInTakesTheFilesRefreshToken(_ refusal: SyncError) async throws {
        let sender = try Sender()
        let content = try await sender.content(clientID: "client-a")
        let store = try MailStore(path: nil)
        try store.save(sender.oauth)
        let secrets = InMemorySecretStore()
        try secrets.setRefreshToken(Secret("refresh-here"), for: sender.oauth.id)
        let part = receiver(store: store, secrets: secrets, clientID: "client-a", lastError: refusal)

        let differences = await part.differences(in: content)
        #expect(differences.map(\.id) == ["password:olle@example.org"])
        // A token rotates, so an answer about it is never remembered.
        #expect(differences.allSatisfy { $0.state.isEmpty })
        let report = await part.importContent(content, version: 1, replacing: ["password:olle@example.org"])

        #expect(report.replaced == [accountItem("olle@example.org")])
        #expect(try secrets.refreshToken(for: sender.oauth.id)?.reveal() == "refresh-1")
    }
}

/// A refresh token rotates on renewal, so another one than the file's tells nothing: an OAuth
/// account is a difference only when this device's sign-in does not work.
extension AccountsSetupPartTests {
    @Test(arguments: [nil, SyncError.imap(.net(.timeout)), .oauth(.transport)])
    func aWorkingSignInWithAnotherTokenIsNoDifference(_ lastError: SyncError?) async throws {
        let sender = try Sender()
        let content = try await sender.content(clientID: "client-a")
        let store = try MailStore(path: nil)
        try store.save(sender.oauth)
        let secrets = InMemorySecretStore()
        try secrets.setRefreshToken(Secret("refresh-rotated"), for: sender.oauth.id)
        let part = receiver(store: store, secrets: secrets, lastError: lastError)

        #expect(await part.differences(in: content).isEmpty)
        let report = await part.importContent(content, version: 1, replacing: ["password:olle@example.org"])
        #expect(report.replaced.isEmpty)
        #expect(try secrets.refreshToken(for: sender.oauth.id)?.reveal() == "refresh-rotated")
    }

    /// A password account still differs by its password, whatever its sign-in last did.
    @Test func aPasswordAccountDiffersByItsPasswordAlone() async throws {
        let sender = try Sender()
        let content = try await sender.content()
        let store = try MailStore(path: nil)
        try store.save(sender.password)
        let secrets = InMemorySecretStore()
        try secrets.setPassword(Secret("chosen here"), for: sender.password.id)

        let differences = await receiver(store: store, secrets: secrets).differences(in: content)
        #expect(differences.map(\.id) == ["password:pat@example.org"])
    }
}
