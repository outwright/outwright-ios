// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightDAV
import OutwrightFakes
import OutwrightModel
import OutwrightNet
import OutwrightStore
import Synchronization
import Testing

@testable import OutwrightSync

/// What a feed server answers, and what it was asked.
final class FeedState: Sendable {
    let response = Mutex(FakeHTTPResponse(status: 200, body: SyntheticFeed.work))
    let requests = Mutex<[FakeHTTPRequest]>([])
    /// How long each answer takes.
    let delay = Mutex<Duration>(.zero)
    /// Requests being answered now, and the most there were at once.
    let busy = Mutex((now: 0, most: 0))
}

/// A published calendar on loopback: what it answers can change between fetches.
final class FeedServer: Sendable {
    let state = FeedState()
    let server: FakeHTTPServer

    init() {
        let state = state
        server = FakeHTTPServer { request in
            state.requests.withLock { $0.append(request) }
            state.busy.withLock { $0.now += 1; $0.most = max($0.most, $0.now) }
            let wait = state.delay.withLock { $0 }
            if wait > .zero { try? await Task.sleep(for: wait) }
            state.busy.withLock { $0.now -= 1 }
            return state.response.withLock { $0 }
        }
    }

    func answer(_ status: Int, _ body: Data = Data(), headers: [String: String] = [:]) {
        state.response.withLock { $0 = FakeHTTPResponse(status: status, body: body, headers: headers) }
    }

    var count: Int { state.requests.withLock { $0.count } }
    var last: FakeHTTPRequest? { state.requests.withLock { $0.last } }
}

struct SubscriptionHarness {
    let feed: FeedServer
    let store: MailStore
    let secrets: InMemorySecretStore
    let account: Account
    let clock: CalendarClock
    let cal: CalendarID

    func syncer() -> SubscriptionSyncer {
        let clock = clock
        return SubscriptionSyncer(
            store: store, secrets: secrets, session: URLSession(configuration: .ephemeral), now: { clock.now },
            phoneZone: { stockholm })
    }

    func subscription() throws -> CalendarSubscription {
        try #require(try store.subscriptions().first)
    }

    func sync(force: Bool = true) async throws {
        try await syncer().sync(try subscription(), force: force)
    }

    func occurrences() throws -> [CalendarEvent] {
        try store.occurrences(
            from: clock.now.addingTimeInterval(-400 * 86_400), to: clock.now.addingTimeInterval(1_000 * 86_400), in: nil)
    }

    func titled(_ title: String) throws -> [CalendarEvent] {
        try occurrences().filter { $0.occurrence.details.title == title }
    }
}

/// A store with an account (no CalDAV) and one subscription whose address points at a feed server.
func withSubscription(address: Bool = true, _ body: (SubscriptionHarness) async throws -> Void) async throws {
    let feed = FeedServer()
    let port = try await feed.server.start()
    defer { feed.server.stop() }
    let store = try MailStore(path: nil)
    let account = Account(
        id: AccountID(), displayName: "Jörgen", email: "jk@example.org", colorIndex: 0,
        imap: MailEndpoint(host: "127.0.0.1", port: 1, security: "plainLoopbackOnly"),
        smtp: MailEndpoint(host: "127.0.0.1", port: 1, security: "plainLoopbackOnly"),
        user: "jk@example.org", signature: "", sortOrder: 0)
    try store.save(account)
    let key = UUID()
    let cal = try store.addSubscription(key: key, host: "127.0.0.1", name: "Work", color: nil)
    let secrets = InMemorySecretStore()
    if address {
        try secrets.setSubscriptionAddress(Secret("http://127.0.0.1:\(port)/s3cr3t-path/calendar.ics"), for: key)
    }
    try await body(
        SubscriptionHarness(feed: feed, store: store, secrets: secrets, account: account, clock: CalendarClock(), cal: cal))
}

private func utc(_ text: String) throws -> Date {
    try #require(ISO8601DateFormatter().date(from: text))
}

private func expectFailure(_ failure: SubscriptionFailure, _ body: () async throws -> Void) async {
    do {
        try await body()
        Issue.record("expected \(failure)")
    } catch {
        #expect(error as? SyncError == .subscription(failure))
    }
}

@Suite struct SubscriptionSyncTests {
    @Test func firstFetchShowsEvents() async throws {
        try await withSubscription { h in
            try await h.sync()
            let standups = try h.titled("Standup").map(\.occurrence.start)
            // 09:00 W. Europe on either side of the October change.
            #expect(standups.contains(try utc("2026-10-02T07:00:00Z")))
            #expect(standups.contains(try utc("2026-11-13T08:00:00Z")))
            #expect(!standups.contains(try utc("2026-10-16T07:00:00Z")))
            #expect(!standups.contains(try utc("2026-11-06T08:00:00Z")))
            #expect(try h.titled("Standup moved").map(\.occurrence.start) == [try utc("2026-11-06T12:00:00Z")])
            #expect(try h.titled("Conference").first?.occurrence.allDayStart == 20_261_120)
            #expect(try h.titled("Broken").isEmpty)
            #expect(try h.occurrences().allSatisfy { !$0.isEditable && !$0.isInvitation })
            #expect(try h.subscription().fetchedAt == fixedNow)
        }
    }

    @Test func alarmsIgnored() async throws {
        try await withSubscription { h in
            try await h.sync()
            #expect(try h.titled("Review").first?.occurrence.details.reminder == nil)
        }
    }

    @Test func unchangedBodyKeepsEvents() async throws {
        try await withSubscription { h in
            try await h.sync()
            let before = try h.occurrences()
            h.clock.advance(days: 0.1)
            try await h.sync()
            #expect(try h.occurrences() == before)
            #expect(try h.subscription().fetchedAt == h.clock.now)
            #expect(h.feed.count == 2)
        }
    }

    @Test func changedBodyMovesAndRemoves() async throws {
        try await withSubscription { h in
            try await h.sync()
            let moved = SyntheticFeed.review.replacingOccurrences(of: "20261110T1", with: "20261112T1")
            h.feed.answer(200, SyntheticFeed.feed([SyntheticFeed.standup, SyntheticFeed.standupMoved, moved]))
            try await h.sync()
            #expect(try h.titled("Review").map(\.occurrence.start) == [try utc("2026-11-12T09:00:00Z")])
            #expect(try h.titled("Conference").isEmpty)
        }
    }

    @Test func etagThen304() async throws {
        try await withSubscription { h in
            h.feed.answer(200, SyntheticFeed.work, headers: ["ETag": "\"a\""])
            try await h.sync()
            h.feed.answer(304)
            try await h.sync()
            let last = try #require(h.feed.last)
            #expect(last.headers["if-none-match"] == "\"a\"")
            #expect(try h.titled("Review").count == 1)
        }
    }

    @Test func failuresRecordedEventsKept() async throws {
        try await withSubscription { h in
            try await h.sync()
            h.feed.answer(404)
            await expectFailure(.unpublished) { try await h.sync() }
            #expect(try h.subscription().failure == .unpublished)
            #expect(try h.titled("Review").count == 1)
            h.feed.answer(401)
            await expectFailure(.unshared) { try await h.sync() }
            #expect(try h.subscription().failure == .unshared)
        }
    }

    @Test func htmlBodyKeepsEvents() async throws {
        try await withSubscription { h in
            try await h.sync()
            h.feed.answer(200, Data("<html><body>Sign in</body></html>".utf8))
            await expectFailure(.notCalendar) { try await h.sync() }
            #expect(try h.titled("Review").count == 1)
        }
    }

    @Test func emptyCalendarRemovesEvents() async throws {
        try await withSubscription { h in
            try await h.sync()
            h.feed.answer(200, SyntheticFeed.feed([]))
            try await h.sync()
            #expect(try h.occurrences().isEmpty)
        }
    }

    @Test func oversizedBody() async throws {
        try await withSubscription { h in
            h.feed.answer(200, Data(count: DAVLimits.responseBytes + 1))
            await expectFailure(.tooLarge) { try await h.sync() }
        }
    }

    @Test func withinIntervalSkipsFetch() async throws {
        try await withSubscription { h in
            try await h.sync()
            h.clock.advance(days: 10.0 / 1_440)
            try await h.sync(force: false)
            #expect(h.feed.count == 1)
            h.clock.advance(days: 25.0 / 1_440)
            try await h.sync(force: false)
            #expect(h.feed.count == 2)
        }
    }

    @Test func windowMoveRereadsUnchangedFile() async throws {
        try await withSubscription { h in
            let far = SyntheticFeed.event([
                "UID:far", "DTSTAMP:20260901T000000Z", "DTSTART:20290106T100000Z", "SUMMARY:Far"
            ])
            h.feed.answer(200, SyntheticFeed.feed([SyntheticFeed.review, far]))
            try await h.sync()
            #expect(try h.titled("Far").isEmpty)
            h.clock.advance(days: 92)
            try await h.sync()
            #expect(try h.titled("Far").count == 1)
        }
    }

    @Test func addressNeverStored() async throws {
        try await withSubscription { h in
            h.feed.answer(404)
            var thrown = ""
            do {
                try await h.sync()
            } catch {
                thrown = String(describing: error)
            }
            let held = String(describing: try h.store.subscriptions())
            let hrefs = try h.store.calendars(h.account.id).map(\.href).joined()
            for text in [thrown, held, hrefs] {
                #expect(!text.contains("s3cr3t-path"))
            }
            #expect(!thrown.isEmpty)
        }
    }

    @Test func noAddress() async throws {
        try await withSubscription(address: false) { h in
            await expectFailure(.noAddress) { try await h.sync() }
            #expect(h.feed.count == 0)
            let failure = try h.subscription().failure
            #expect(failure == .noAddress)
        }
    }

    @Test func cancelledSyncRecordsNothing() async throws {
        try await withSubscription { h in
            h.feed.state.delay.withLock { $0 = .milliseconds(300) }
            let subscription = try h.subscription()
            let syncer = h.syncer()
            let run = Task { try await syncer.sync(subscription, force: true) }
            try await Task.sleep(for: .milliseconds(50))
            run.cancel()
            _ = await run.result
            let after = try h.subscription()
            #expect(after.failure == nil && after.fetchedAt == nil)
        }
    }
}
