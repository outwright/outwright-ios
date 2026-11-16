// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightModel
import Testing

@testable import OutwrightSync

/// An account whose provider the build does not carry is kept, and never synced.
@Suite struct ProviderAvailabilityTests {
    @Test func accountOfMissingProviderIsNotSynced() async throws {
        try await withHarness { h in
            var gone = h.account
            gone.provider = ProviderID(raw: "gone")
            try h.store.save(gone)
            let coordinator = SyncCoordinator(
                store: h.store, secrets: h.secrets, available: [.ownServer], resolver: FakeDoH(),
                davSession: URLSession(configuration: .ephemeral), probe: { _ in nil }, reminders: RecordingReminders())
            #expect(await coordinator.currentSyncers().isEmpty)
            #expect(try h.store.accounts().map(\.provider.raw) == ["gone"])
        }
    }

    @Test func everyProviderIsAvailableWhenNoneAreNamed() async throws {
        try await withHarness { h in
            var other = h.account
            other.provider = ProviderID(raw: "other")
            try h.store.save(other)
            let coordinator = offlineCoordinator(store: h.store, secrets: h.secrets)
            #expect(await coordinator.currentSyncers().count == 1)
        }
    }

    @Test func providersGiveTheirTokensAndGraph() throws {
        struct Stub: Provider {
            let id = ProviderID(raw: "stub")
            let tokens: (any TokenRefreshing)? = nil
            let graphBase: URL? = URL(string: "https://graph.example.org/v1/")
        }
        let set = ProviderSet([OwnServerProvider(), Stub()])
        #expect(set.ids == [.ownServer, ProviderID(raw: "stub")])
        #expect(set.graphBases[ProviderID(raw: "stub")] == URL(string: "https://graph.example.org/v1/"))
        #expect(set.tokens.isEmpty)
    }
}
