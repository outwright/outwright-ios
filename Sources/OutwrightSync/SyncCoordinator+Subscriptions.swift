// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
public import OutwrightModel

extension SyncCoordinator {
    var subscriptionSyncer: SubscriptionSyncer {
        SubscriptionSyncer(store: store, secrets: secrets, session: davSession, now: now, phoneZone: phoneZone)
    }

    /// How many subscribed calendars are fetched at once.
    static let subscriptionsAtOnce = 4

    /// Fetches the subscribed calendars, a few side by side, each not fetched in the last
    /// `SubscriptionSyncer.minimumInterval` (every one with `force`). A failure is kept with its
    /// subscription.
    public func refreshSubscriptions(force: Bool) async {
        let held = (try? store.subscriptions()) ?? []
        await withTaskGroup(of: Void.self) { group in
            for (index, subscription) in held.enumerated() {
                if index >= Self.subscriptionsAtOnce { await group.next() }
                guard !Task.isCancelled else { break }
                group.addTask { await self.fetch(subscription, force: force) }
            }
        }
    }

    /// Fetches one subscribed calendar now (the owner asked): after a fetch already under way.
    public func refreshSubscription(_ cal: CalendarID) async {
        guard let subscription = ((try? store.subscriptions()) ?? []).first(where: { $0.id == cal }) else {
            return
        }
        await fetch(subscription, force: true)
    }

    /// Fetches and reads a published calendar once, keeping nothing.
    public func previewSubscription(_ url: URL) async throws(SyncError) -> SubscriptionPreview {
        try await subscriptionSyncer.preview(url)
    }

    /// One fetch of a subscription at a time: an unforced one finds the running fetch enough, a forced
    /// one waits for it and fetches again.
    private func fetch(_ subscription: CalendarSubscription, force: Bool) async {
        while let running = subscriptionRuns[subscription.id] {
            await running.value
            // A finished fetch leaves the slot, whoever notices it first.
            if subscriptionRuns[subscription.id] == running { subscriptionRuns[subscription.id] = nil }
            guard force else { return }
        }
        let syncer = subscriptionSyncer
        let run = Task<Void, Never> { _ = try? await syncer.sync(subscription, force: force) }
        subscriptionRuns[subscription.id] = run
        await withTaskCancellationHandler {
            await run.value
        } onCancel: {
            run.cancel()
        }
        if subscriptionRuns[subscription.id] == run { subscriptionRuns[subscription.id] = nil }
    }
}
