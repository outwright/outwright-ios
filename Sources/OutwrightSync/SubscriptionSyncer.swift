// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import CryptoKit
public import Foundation
import OutwrightDAV
public import OutwrightModel
public import OutwrightStore

/// What a published calendar holds, shown before the owner subscribes to it.
public struct SubscriptionPreview: Sendable, Equatable {
    /// Its `X-WR-CALNAME`.
    public var name: String?
    /// Its calendar objects (events by UID).
    public var events: Int

    public init(name: String?, events: Int) {
        self.name = name
        self.events = events
    }
}

/// Keeps a subscribed calendar in step with its published file: one fetch, the file cut into calendar
/// objects by UID, and those kept or dropped as a CalDAV listing's would be. Needs no account login.
/// A failure is stored with the subscription (the held events stay) and thrown; a run cut short by
/// cancellation records nothing.
public struct SubscriptionSyncer: Sendable {
    /// The least time between two fetches of one subscription, unless the owner asks.
    public static let minimumInterval: TimeInterval = 30 * 60

    let store: MailStore
    let secrets: any SecretStore
    let client: FeedClient
    let now: @Sendable () -> Date
    let phoneZone: @Sendable () -> TimeZone

    public init(
        store: MailStore, secrets: any SecretStore, session: URLSession, now: @escaping @Sendable () -> Date,
        phoneZone: @escaping @Sendable () -> TimeZone
    ) {
        self.store = store
        self.secrets = secrets
        client = FeedClient(session: session)
        self.now = now
        self.phoneZone = phoneZone
    }

    public func sync(_ subscription: CalendarSubscription, force: Bool) async throws(SyncError) {
        let time = now()
        if !force, let fetched = subscription.fetchedAt, time.timeIntervalSince(fetched) < Self.minimumInterval {
            return
        }
        do throws(SubscriptionFailure) {
            try await run(subscription.id, key: subscription.key, at: time)
        } catch {
            // Cut short (the background time ran out): nothing is recorded, the next run starts over.
            guard !Task.isCancelled else { return }
            try stored { try store.setSubscriptionFailure(subscription.id, error, at: time) }
            throw .subscription(error)
        }
    }

    /// Fetches and reads `url` once, keeping nothing.
    public func preview(_ url: URL) async throws(SyncError) -> SubscriptionPreview {
        let answer: FeedAnswer
        do {
            answer = try await client.fetch(url, etag: nil, lastModified: nil)
        } catch {
            throw .subscription(Self.failure(error))
        }
        guard case let .body(body, _, _) = answer else { throw .subscription(.server) }
        do {
            let split = try ICalendarFeed.split(body)
            return SubscriptionPreview(name: split.name, events: split.objects.count)
        } catch {
            throw .subscription(error == .tooLarge ? .tooLarge : .notCalendar)
        }
    }

    /// The address the owner typed, trimmed, `webcal://` read as `https://`; nil unless HTTPS.
    public static func address(_ text: String) -> URL? {
        FeedClient.address(text)
    }

    private func run(_ cal: CalendarID, key: UUID, at time: Date) async throws(SubscriptionFailure) {
        guard let text = (try? secrets.subscriptionAddress(key))?.reveal(), let url = URL(string: text) else {
            throw .noAddress
        }
        let zone = phoneZone()
        let window = CalendarWindow.window(now: time, zone: zone)
        let start = CalendarWindow.day(window.lowerBound, zone: zone)
        let moved = try local { try store.windowListedFrom(cal) } != start
        let last = try local { try store.subscriptionValidators(cal) }
        let answer: FeedAnswer
        do {
            answer = try await client.fetch(
                url, etag: moved ? nil : last.etag, lastModified: moved ? nil : last.lastModified)
        } catch {
            throw Self.failure(error)
        }
        guard case let .body(body, etag, lastModified) = answer else {
            try local { try store.setSubscriptionFetched(cal, at: time, validators: last) }
            return
        }
        let validators = SubscriptionValidators(etag: etag, lastModified: lastModified, bodyHash: Self.digest(body))
        if !moved, validators.bodyHash == last.bodyHash {
            try local { try store.setSubscriptionFetched(cal, at: time, validators: validators) }
            return
        }
        let split: FeedSplit
        do {
            split = try ICalendarFeed.split(body)
        } catch {
            throw error == .tooLarge ? .tooLarge : .notCalendar
        }
        try keep(split, in: cal, window: window, zone: zone, moved: moved)
        try local { try store.setWindowListedFrom(start, for: cal) }
        try local { try store.setSubscriptionFetched(cal, at: time, validators: validators) }
    }

    /// Keeps the objects that changed (all of them when the window moved), refuses the unreadable,
    /// and drops what the file no longer has.
    private func keep(
        _ split: FeedSplit, in cal: CalendarID, window: ClosedRange<Date>, zone: TimeZone, moved: Bool
    ) throws(SubscriptionFailure) {
        var held = try local { try store.remoteETags(cal) }
        for (href, skip) in try local({ try store.skippedEvents(cal) }) { held[href] = skip.etag }
        for object in split.objects where moved || held[object.href] != object.etag {
            guard !Task.isCancelled else { throw .server }
            try local {
                try CalendarObjects.keep(
                    href: object.href, etag: object.etag, data: object.data, scheduleTag: nil, in: cal,
                    window: window, zone: zone, store: store)
            }
        }
        for object in split.refused where held[object.href] != object.etag {
            try local { try store.setSkippedEvent(href: object.href, etag: object.etag, refused: true, in: cal) }
        }
        let present = Set(split.objects.map(\.href) + split.refused.map(\.href))
        let gone = held.keys.filter { !present.contains($0) }
        if !gone.isEmpty {
            try local { try store.removeRemote(hrefs: gone, in: cal) }
            try local { try store.removeSkippedEvents(hrefs: gone, in: cal) }
        }
    }

    /// Runs a store call; its failure is the server's problem as far as the owner can tell.
    private func local<T, E: Error>(_ body: () throws(E) -> T) throws(SubscriptionFailure) -> T {
        do {
            return try body()
        } catch {
            throw .server
        }
    }

    static func failure(_ error: DAVError) -> SubscriptionFailure {
        switch error {
        case .net: .unreachable
        case .unauthorized: .unshared
        case .notFound: .unpublished
        case .tooLarge: .tooLarge
        default: .server
        }
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
