// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
public import OutwrightModel
import OutwrightNet
import OutwrightStore
public import OutwrightSync

/// Why a subscribed calendar could not be checked, added or changed.
public enum SubscriptionAddError: Error, Sendable, Equatable {
    /// Not an HTTPS (or `webcal`) address with a host.
    case badAddress
    case failed(SubscriptionFailure)
    case keychain
    case store
}

extension AppModel {
    /// The subscribed calendars, which belong to no account.
    public func subscriptions() -> [CalendarSubscription] {
        (try? store.subscriptions()) ?? []
    }

    /// Fetches and reads the address once: its name and how many events it holds.
    public func checkSubscription(_ text: String) async throws(SubscriptionAddError) -> SubscriptionPreview {
        guard let url = SubscriptionSyncer.address(text) else { throw .badAddress }
        do {
            return try await sync.previewSubscription(url)
        } catch {
            throw Self.addError(error)
        }
    }

    /// Keeps the address in the keychain and the subscription in the store, then fetches it.
    public func addSubscription(
        _ text: String, name: String, color: Int?
    ) async throws(SubscriptionAddError) -> CalendarID {
        guard let url = SubscriptionSyncer.address(text), let host = url.host() else { throw .badAddress }
        let key = UUID()
        do {
            try sync.secrets.setSubscriptionAddress(Secret(url.absoluteString), for: key)
        } catch {
            throw .keychain
        }
        let cal: CalendarID
        do {
            cal = try store.addSubscription(key: key, host: host, name: name, color: color)
        } catch {
            try? sync.secrets.removeSubscriptionAddress(key)
            throw .store
        }
        await sync.refreshSubscription(cal)
        return cal
    }

    public func updateSubscription(_ cal: CalendarID, name: String, color: Int) throws(SubscriptionAddError) {
        do {
            try store.updateSubscription(cal, name: name, color: color)
        } catch {
            throw .store
        }
    }

    /// Fetches the subscription now.
    public func refreshSubscription(_ cal: CalendarID) async {
        await sync.refreshSubscription(cal)
    }

    /// Forgets the address, then the subscription and its events.
    public func removeSubscription(_ cal: CalendarID) throws(SubscriptionAddError) {
        let all: [CalendarSubscription]
        do {
            all = try store.subscriptions()
        } catch {
            throw .store
        }
        guard let held = all.first(where: { $0.id == cal }) else { throw .store }
        do {
            try sync.secrets.removeSubscriptionAddress(held.key)
        } catch {
            throw .keychain
        }
        do {
            _ = try store.removeSubscription(cal)
        } catch {
            throw .store
        }
    }

    private static func addError(_ error: SyncError) -> SubscriptionAddError {
        if case let .subscription(failure) = error { return .failed(failure) }
        return .failed(.server)
    }
}
