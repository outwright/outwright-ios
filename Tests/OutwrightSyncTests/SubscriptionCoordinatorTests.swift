// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightFakes
import OutwrightModel
import OutwrightStore
import Testing

@testable import OutwrightSync

@Suite struct SubscriptionCoordinatorTests {
    func coordinator(_ h: SubscriptionHarness) -> SyncCoordinator {
        let clock = h.clock
        return SyncCoordinator(
            store: h.store, secrets: h.secrets, now: { clock.now }, phoneZone: { stockholm },
            davSession: URLSession(configuration: .ephemeral), probe: { _ in nil })
    }

    /// A refresh fetches the subscribed calendars with no account at all, and keeps a failure with
    /// the subscription.
    @Test func refreshAllRunsSubscriptionsWithoutAccounts() async throws {
        try await withSubscription { h in
            try h.store.removeAccount(h.account.id)
            let sync = coordinator(h)
            await sync.refreshAll()
            #expect(try h.titled("Review").count == 1)
            h.feed.answer(404)
            h.clock.advance(days: 1)
            await sync.refreshAll()
            let failure = try h.subscription().failure
            #expect(failure == .unpublished)
        }
    }

    @Test func refreshOneIsForced() async throws {
        try await withSubscription { h in
            let sync = coordinator(h)
            await sync.refreshSubscription(h.cal)
            await sync.refreshSubscription(h.cal)
            #expect(h.feed.count == 2)
        }
    }

    @Test func previewReadsNameAndCount() async throws {
        try await withSubscription { h in
            let address = try #require(try h.secrets.subscriptionAddress(try h.subscription().key)?.reveal())
            let url = try #require(SubscriptionSyncer.address(address))
            let preview = try await coordinator(h).previewSubscription(url)
            #expect(preview == SubscriptionPreview(name: "Work", events: 3))
            h.feed.answer(404)
            await #expect(throws: SyncError.subscription(.unpublished)) {
                try await coordinator(h).previewSubscription(url)
            }
        }
    }

    @Test func refreshNowWaitsForARunningFetchThenFetches() async throws {
        try await withSubscription { h in
            let sync = coordinator(h)
            h.feed.state.delay.withLock { $0 = .milliseconds(300) }
            let background = Task { await sync.refreshSubscriptions(force: true) }
            try await Task.sleep(for: .milliseconds(100))
            await sync.refreshSubscription(h.cal)
            await background.value
            #expect(h.feed.count == 2)
        }
    }

    @Test func subscriptionsAreFetchedSideBySide() async throws {
        try await withSubscription { h in
            let address = try #require(try h.secrets.subscriptionAddress(try h.subscription().key))
            for index in 0..<5 {
                let key = UUID()
                _ = try h.store.addSubscription(key: key, host: "127.0.0.1", name: "More \(index)", color: nil)
                try h.secrets.setSubscriptionAddress(address, for: key)
            }
            h.feed.state.delay.withLock { $0 = .milliseconds(300) }
            await coordinator(h).refreshSubscriptions(force: true)
            #expect(h.feed.count == 6)
            let most = h.feed.state.busy.withLock { $0.most }
            #expect(most > 1 && most <= SyncCoordinator.subscriptionsAtOnce)
        }
    }
}
