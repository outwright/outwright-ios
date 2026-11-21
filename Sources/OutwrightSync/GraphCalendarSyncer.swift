// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
import OutwrightGraph
public import OutwrightModel
public import OutwrightStore
public import OutwrightNet

/// Keeps a Graph account's calendars in step with Graph, as `CalendarSyncer` does for
/// CalDAV: the owner's queued changes first, then the calendar list, then every calendar. Each sync
/// lists the window's `calendarView` and the calendar's events (for the series masters' change keys);
/// an event is fetched again only when its version moved. A single event's version is its change key;
/// a series' is its series event's change key with its exceptions' ids and change keys in the window, so a
/// moved or cancelled occurrence refetches it. An event's `href` is `me/events/<id>`; its held server
/// copy is its JSON as Graph sent it. Each step runs under the account's lock.
public actor GraphCalendarSyncer {
    public internal(set) var account: Account
    let store: MailStore
    let credentials: CredentialProvider
    let lock: AccountLock
    let base: URL
    let session: URLSession
    let now: @Sendable () -> Date
    let phoneZone: @Sendable () -> TimeZone
    /// Replaced by another syncer for the account: does nothing more.
    var retired = false

    public init(
        account: Account, store: MailStore, credentials: CredentialProvider, base: URL,
        session: URLSession = HTTPSession.shared, now: @escaping @Sendable () -> Date = Date.init,
        phoneZone: @escaping @Sendable () -> TimeZone = { .current }
    ) {
        self.init(
            account: account, store: store, credentials: credentials, lock: AccountLock(), base: base,
            session: session, now: now, phoneZone: phoneZone)
    }

    init(
        account: Account, store: MailStore, credentials: CredentialProvider, lock: AccountLock, base: URL,
        session: URLSession, now: @escaping @Sendable () -> Date, phoneZone: @escaping @Sendable () -> TimeZone
    ) {
        self.account = account
        self.store = store
        self.credentials = credentials
        self.lock = lock
        self.base = base
        self.session = session
        self.now = now
        self.phoneZone = phoneZone
    }

    func retire() {
        retired = true
    }

    // MARK: - Public operations

    /// Sends the queued changes, then brings every calendar in step (also when Graph failed a change).
    /// A calendar that fails is skipped and its error thrown once the others are done.
    public func sync() async throws(SyncError) {
        guard let client = try await client() else {
            return
        }
        var firstError: SyncError?
        do {
            let calendars = try await exclusive { () async throws(SyncError) in
                do throws(SyncError) {
                    try await runQueue(client)
                } catch {
                    guard Self.isServerTrouble(error) else { throw error }
                    firstError = error
                }
                return try await listCalendars(client)
            }
            for (calendar, local) in calendars {
                do {
                    try await exclusive { () async throws(SyncError) in
                        try await syncCalendar(calendar, local, client)
                    }
                } catch {
                    firstError = firstError ?? error
                    guard Self.isServerTrouble(error) else { break }
                }
            }
        } catch {
            firstError = error
        }
        if let firstError {
            throw firstError
        }
    }

    /// Sends the queued changes only.
    public func runChanges() async throws(SyncError) {
        guard let client = try await client() else {
            return
        }
        try await exclusive { () async throws(SyncError) in
            try await runQueue(client)
        }
    }

    // MARK: - Calendars

    /// Graph's calendars (its default one first, so it is the account's first), stored, paired with
    /// their ids here.
    private func listCalendars(_ client: GraphClient) async throws(SyncError) -> [(GraphCalendar, CalendarID)] {
        let remote = try await graph { () async throws(GraphError) in try await client.calendars() }
        let ordered = remote.filter(\.isDefault) + remote.filter { !$0.isDefault }
        try stored {
            try store.replaceCalendars(
                ordered.map { (href: $0.path, name: $0.name, color: $0.color, isReadOnly: !$0.canEdit) },
                for: account.id)
        }
        let local = try stored { try store.calendars(account.id) }
        let ids = Dictionary(local.map { ($0.href, $0.id) }, uniquingKeysWith: { first, _ in first })
        return ordered.compactMap { calendar in ids[calendar.path].map { (calendar, $0) } }
    }

    /// Stores the calendar's new and changed events in the window and drops the ones gone from it.
    private func syncCalendar(
        _ calendar: GraphCalendar, _ local: CalendarID, _ client: GraphClient
    ) async throws(SyncError) {
        let zone = phoneZone()
        let window = CalendarWindow.window(now: now(), zone: zone)
        let versions = try await versions(calendar, window, client)
        let held = try stored { try store.remoteETags(local) }
        let skipped = try stored { try store.skippedEvents(local) }
        for (href, version) in versions.sorted(by: { $0.key < $1.key }) {
            guard held[href] != version.tag, skipped[href]?.etag != version.tag else { continue }
            let fetched = try await graph { () async throws(GraphError) in
                version.isSeries ? try await client.series(id: version.id) : try await client.event(id: version.id)
            }
            guard let fetched else { continue }
            guard let series = GraphEventMapping.series(fetched.data, ownEmail: account.email) else {
                try stored { try store.setSkippedEvent(href: href, etag: version.tag, refused: true, in: local) }
                continue
            }
            // Listed for the window yet with no occurrence in it as laid out here: not fetched until it changes.
            let laidOut = Recurrence.occurrences(
                series, from: window.lowerBound, to: window.upperBound, phoneZone: zone)
            guard !laidOut.isEmpty else {
                try stored { try store.removeRemote(hrefs: [href], in: local) }
                try stored { try store.setSkippedEvent(href: href, etag: version.tag, refused: false, in: local) }
                continue
            }
            _ = try stored {
                try store.upsertRemote(
                    href: href, etag: version.tag, ics: fetched.data, series: series, in: local, window: window,
                    phoneZone: zone, scheduleTag: nil)
            }
            try stored { try store.removeSkippedEvents(hrefs: [href], in: local) }
        }
        let removed = held.keys.filter { versions[$0] == nil }
        if !removed.isEmpty {
            try stored { try store.removeRemote(hrefs: removed, in: local) }
        }
        try stored { try store.removeSkippedEvents(hrefs: skipped.keys.filter { versions[$0] == nil }, in: local) }
    }

    /// What one event in the window is now.
    struct Version {
        let id: String
        let isSeries: Bool
        let tag: String
    }

    /// The version of every single event and series with an occurrence in the window, by href.
    private func versions(
        _ calendar: GraphCalendar, _ window: ClosedRange<Date>, _ client: GraphClient
    ) async throws(SyncError) -> [String: Version] {
        let view = try await graph { () async throws(GraphError) in
            try await client.calendarView(calendar, from: window.lowerBound, to: window.upperBound)
        }
        var found: [String: Version] = [:]
        var exceptions: [String: [String]] = [:]
        var occurrences: [String: [String]] = [:]
        for stub in view {
            if let seriesID = stub.seriesID {
                occurrences[seriesID, default: []].append(stub.id)
                if stub.type == "exception" { exceptions[seriesID, default: []].append(stub.id + ":" + stub.changeKey) }
            } else {
                found[Self.href(stub.id)] = Version(id: stub.id, isSeries: false, tag: stub.changeKey)
            }
        }
        // A series' own change key is asked for alone; with its exceptions' keys and (hashed) the ids of
        // its occurrences in the window, so a cancelled occurrence moves its version too.
        let keys = try await changeKeys(of: Array(occurrences.keys), client)
        for (seriesID, ids) in occurrences {
            guard let key = keys[seriesID] else { continue }
            let tag = ([key] + (exceptions[seriesID] ?? []).sorted() + [Self.digest(ids.sorted())])
                .joined(separator: "|")
            found[Self.href(seriesID)] = Version(id: seriesID, isSeries: true, tag: tag)
        }
        return found
    }

    /// Graph's limit of requests at once per mailbox.
    static let requestsAtOnce = 4

    /// One series' change key as Graph answered it.
    private struct KeyAnswer: Sendable {
        let id: String
        let key: Result<String?, GraphError>
    }

    /// The change key of each series Graph still has, asked for `requestsAtOnce` at a time. A child
    /// answers a named struct built once, never a tuple returned from both a `do` and its `catch`:
    /// optimized builds of Swift 6.3 and 6.4 lose that tuple and free the group under a running child
    /// (swiftlang/swift#92698).
    private func changeKeys(of ids: [String], _ client: GraphClient) async throws(SyncError) -> [String: String] {
        let answers = await withTaskGroup(of: KeyAnswer.self) { group in
            var answers: [KeyAnswer] = []
            var next = ids.makeIterator()
            func ask(_ id: String) {
                group.addTask {
                    let key: Result<String?, GraphError>
                    do throws(GraphError) {
                        key = .success(try await client.changeKey(of: id))
                    } catch {
                        key = .failure(error)
                    }
                    return KeyAnswer(id: id, key: key)
                }
            }
            for _ in 0..<Self.requestsAtOnce {
                guard let id = next.next() else { break }
                ask(id)
            }
            for await answer in group {
                answers.append(answer)
                if let id = next.next() { ask(id) }
            }
            return answers
        }
        var keys: [String: String] = [:]
        for answer in answers {
            keys[answer.id] = try await graph { () throws(GraphError) in try answer.key.get() }
        }
        return keys
    }

    /// FNV-1a 64 of the ids, in hex: a short stand-in for a long list.
    static func digest(_ ids: [String]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in ids.joined(separator: "\n").utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    static func href(_ id: String) -> String {
        "me/events/" + id
    }
}

extension GraphCalendarSyncer: GraphSyncing {}
