// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightFakes
import OutwrightModel
import OutwrightNet
import OutwrightSync
import Testing

@testable import OutwrightStore
@testable import OutwrightUI

/// A published calendar on loopback that always answers the synthetic feed.
@MainActor
func withFeed(_ body: (String) async throws -> Void) async throws {
    let server = FakeHTTPServer { _ in FakeHTTPResponse(status: 200, body: SyntheticFeed.work) }
    let port = try await server.start()
    defer { server.stop() }
    try await body("http://127.0.0.1:\(port)/s3cr3t/calendar.ics")
}

@MainActor @Suite struct SubscriptionsTests {
    @Test func checkReadsNameAndCount() async throws {
        let box = try Mailbox()
        let app = AppModel(store: box.store, sync: offlineSync(store: box.store, secrets: InMemorySecretStore()))
        try await withFeed { address in
            let preview = try await app.checkSubscription(address)
            #expect(preview == SubscriptionPreview(name: "Work", events: 3))
        }
        await #expect(throws: SubscriptionAddError.badAddress) {
            try await app.checkSubscription("http://example.org/c.ics")
        }
    }

    @Test func addStoresAddressOnlyInKeychain() async throws {
        var box = try Mailbox()
        _ = try box.addAccount("anna@example.org")
        let secrets = InMemorySecretStore()
        let app = AppModel(store: box.store, sync: offlineSync(store: box.store, secrets: secrets))
        try await withFeed { address in
            let cal = try await app.addSubscription(address, name: "Jobb", color: nil)
            let held = try #require(app.subscriptions().first)
            #expect(held.id == cal && held.calendar.name == "Jobb" && held.host == "127.0.0.1")
            let kept = try secrets.subscriptionAddress(held.key)?.reveal()
            #expect(kept == address)
            #expect(held.fetchedAt != nil && held.failure == nil)
        }
    }

    @Test func removalForgetsAddress() async throws {
        var box = try Mailbox()
        try box.addAccount("anna@example.org")
        let secrets = InMemorySecretStore()
        let app = AppModel(store: box.store, sync: offlineSync(store: box.store, secrets: secrets))
        try await withFeed { address in
            let first = try await app.addSubscription(address, name: "One", color: nil)
            let key = try #require(app.subscriptions().first?.key)
            try app.removeSubscription(first)
            #expect(app.subscriptions().isEmpty)
            #expect(try secrets.subscriptionAddress(key) == nil)
        }
    }

    @Test func removingAnAccountKeepsSubscriptions() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let secrets = InMemorySecretStore()
        let app = AppModel(store: box.store, sync: offlineSync(store: box.store, secrets: secrets))
        try await withFeed { address in
            _ = try await app.addSubscription(address, name: "One", color: nil)
            let key = try #require(app.subscriptions().first?.key)
            try await app.removeAccount(anna.id)
            #expect(app.subscriptions().map(\.calendar.name) == ["One"])
            #expect(try secrets.subscriptionAddress(key)?.reveal() == address)
        }
    }

    @Test func renameAndRecolour() async throws {
        var box = try Mailbox()
        _ = try box.addAccount("anna@example.org")
        let app = AppModel(store: box.store, sync: offlineSync(store: box.store, secrets: InMemorySecretStore()))
        try await withFeed { address in
            let cal = try await app.addSubscription(address, name: "One", color: nil)
            try app.updateSubscription(cal, name: "Ett", color: 0x2E9E6B)
            let held = try #require(app.subscriptions().first)
            #expect(held.calendar.name == "Ett" && held.calendar.color == 0x2E9E6B)
        }
    }

    @Test func anUnreadableSubscriptionIsNotRemoved() async throws {
        var box = try Mailbox()
        try box.addAccount("anna@example.org")
        let secrets = InMemorySecretStore()
        let app = AppModel(store: box.store, sync: offlineSync(store: box.store, secrets: secrets))
        try await withFeed { address in
            let cal = try await app.addSubscription(address, name: "One", color: nil)
            let key = try #require(app.subscriptions().first?.key)
            try box.store.breakSubscriptions()
            #expect(throws: SubscriptionAddError.store) { try app.removeSubscription(cal) }
            let kept = try secrets.subscriptionAddress(key)
            #expect(kept != nil)
        }
    }
}
