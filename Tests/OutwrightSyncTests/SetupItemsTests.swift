// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightModel
import OutwrightNet
import OutwrightSetup
import OutwrightStore
import Testing

@testable import OutwrightSync

/// A keychain that is locked: every read and write fails.
final class LockedSecretStore: SecretStore {
    static let locked = SyncError.keychain(-25_308)
    func password(for account: AccountID) throws(SyncError) -> Secret? { throw Self.locked }
    func setPassword(_ secret: Secret, for account: AccountID) throws(SyncError) { throw Self.locked }
    func refreshToken(for account: AccountID) throws(SyncError) -> Secret? { throw Self.locked }
    func setRefreshToken(_ secret: Secret, for account: AccountID) throws(SyncError) { throw Self.locked }
    func remove(for account: AccountID) throws(SyncError) { throw Self.locked }
    func subscriptionAddress(_ key: UUID) throws(SyncError) -> Secret? { throw Self.locked }
    func setSubscriptionAddress(_ secret: Secret, for key: UUID) throws(SyncError) { throw Self.locked }
    func removeSubscriptionAddress(_ key: UUID) throws(SyncError) { throw Self.locked }
}

@Suite struct SetupItemsTests {
    @Test func accountsAndCalendarsAreListedWithoutTheKeychain() async throws {
        let store = try MailStore(path: nil)
        try store.save(setupAccount("pat@example.org"))
        _ = try store.addSubscription(key: UUID(), host: "cal.example.org", name: "Holidays", color: 0x2E9E6B)
        let locked = LockedSecretStore()

        let accounts = AccountsSetupPart(store: store, secrets: locked, providers: ProviderSet([OwnServerProvider()]))
        #expect(await accounts.items() == [SetupItem(kind: .account, label: "pat@example.org")])
        let calendars = SubscriptionsSetupPart(store: store, secrets: locked)
        #expect(await calendars.items() == [SetupItem(kind: .calendar, label: "Holidays")])
    }

    @Test func theExchangeListsWhatTheFileWouldCarry() async throws {
        let store = try MailStore(path: nil)
        let secrets = InMemorySecretStore()
        let account = setupAccount("pat@example.org")
        try store.save(account)
        try secrets.setPassword(Secret("hunter2"), for: account.id)
        let key = UUID()
        _ = try store.addSubscription(key: key, host: "cal.example.org", name: "Holidays", color: 0x2E9E6B)
        try secrets.setSubscriptionAddress(Secret("https://cal.example.org/s3cret/holidays.ics"), for: key)
        let exchange = SetupExchange(
            parts: [
                AccountsSetupPart(store: store, secrets: secrets, providers: ProviderSet([OwnServerProvider()])),
                SubscriptionsSetupPart(store: store, secrets: secrets)
            ], device: "Test phone", parameters: quick)

        let passphrase = try Passphrase.generate()
        let carried = try await exchange.export(passphrase: passphrase).items
        #expect(await exchange.items() == carried)
        #expect(carried.count == 2)
    }
}
