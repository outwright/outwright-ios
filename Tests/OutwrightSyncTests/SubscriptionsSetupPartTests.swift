// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightModel
import OutwrightNet
import OutwrightSetup
import OutwrightStore
import Testing

@testable import OutwrightSync

@Suite struct SubscriptionsSetupPartTests {
    static let address = "https://cal.example.org/s3cret/holidays.ics"

    /// The part's JSON from a device with one subscribed calendar, and its key.
    func content() async throws -> (Data, UUID) {
        let store = try MailStore(path: nil)
        let secrets = InMemorySecretStore()
        let key = UUID()
        _ = try store.addSubscription(key: key, host: "cal.example.org", name: "Holidays", color: 0x2E9E6B)
        try secrets.setSubscriptionAddress(Secret(Self.address), for: key)
        return (try await SubscriptionsSetupPart(store: store, secrets: secrets).export(), key)
    }

    /// A calendar here without its address (the keychain did not come back with the phone's backup)
    /// gets the address filled in; its name and colour stay as the device has them.
    @Test func aCalendarHereWithoutItsAddressGetsItFilledIn() async throws {
        let (content, key) = try await content()
        let store = try MailStore(path: nil)
        _ = try store.addSubscription(key: key, host: "cal.example.org", name: "Renamed here", color: 0x112233)
        let secrets = InMemorySecretStore()
        let part = SubscriptionsSetupPart(store: store, secrets: secrets)

        let report = await part.importContent(content, version: part.version)

        #expect(report.restored == [SetupItem(kind: .calendar, label: "Holidays")])
        #expect(report.added.isEmpty)
        #expect(report.skipped.isEmpty)
        #expect(try secrets.subscriptionAddress(key)?.reveal() == Self.address)
        let held = try store.subscriptions()
        #expect(held.map(\.calendar.name) == ["Renamed here"])
        #expect(held.map(\.calendar.color) == [0x112233])
    }

    @Test func aCalendarHereWithItsAddressIsLeftAsItIs() async throws {
        let (content, key) = try await content()
        let store = try MailStore(path: nil)
        _ = try store.addSubscription(key: key, host: "cal.example.org", name: "Holidays", color: 0x2E9E6B)
        let secrets = InMemorySecretStore()
        try secrets.setSubscriptionAddress(Secret("https://cal.example.org/other.ics"), for: key)
        let part = SubscriptionsSetupPart(store: store, secrets: secrets)

        let report = await part.importContent(content, version: part.version)

        #expect(report.restored.isEmpty)
        #expect(report.skipped.map(\.reason) == [.alreadyHere])
        #expect(try secrets.subscriptionAddress(key)?.reveal() == "https://cal.example.org/other.ics")
    }
}
