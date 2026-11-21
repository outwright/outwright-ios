// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
import OutwrightDAV
public import OutwrightModel
public import OutwrightStore
public import OutwrightNet

/// The span of time the store holds events for.
public enum CalendarWindow {
    /// A year back to two years ahead of the start of today on the phone.
    public static func window(now: Date, zone: TimeZone) -> ClosedRange<Date> {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let today = calendar.startOfDay(for: now)
        let from = calendar.date(byAdding: .year, value: -1, to: today) ?? today.addingTimeInterval(-365 * 86_400)
        let to = calendar.date(byAdding: .year, value: 2, to: today) ?? today.addingTimeInterval(730 * 86_400)
        return from...max(from, to)
    }

    /// yyyymmdd of an instant on the phone.
    public static func day(_ date: Date, zone: TimeZone) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return (parts.year ?? 0) * 10_000 + (parts.month ?? 0) * 100 + (parts.day ?? 0)
    }
}

/// Keeps one account's calendars in step with its CalDAV server: the owner's queued changes first,
/// then the calendar list, then every calendar's events: a time-range listing of the window when the
/// window has moved, else sync-collection (or the listing again where the server has none). Each step
/// runs under the account's lock, between the mail operations.
public actor CalendarSyncer {
    public internal(set) var account: Account
    let store: MailStore
    let secrets: any SecretStore
    let lock: AccountLock
    let session: URLSession
    let now: @Sendable () -> Date
    let phoneZone: @Sendable () -> TimeZone
    /// The words of the reply mails the app sends for the owner's answers.
    let meetingWording: MeetingWording
    /// Replaced by another syncer for the account: does nothing more.
    var retired = false
    /// A sync token slot holding a ctag (for a calendar without sync-collection) starts so.
    static let ctagPrefix = "ctag:"

    public init(
        account: Account, store: MailStore, secrets: any SecretStore, session: URLSession = HTTPSession.shared,
        now: @escaping @Sendable () -> Date = Date.init, phoneZone: @escaping @Sendable () -> TimeZone = { .current },
        meetingWording: MeetingWording = .english
    ) {
        self.init(
            account: account, store: store, secrets: secrets, lock: AccountLock(), session: session, now: now,
            phoneZone: phoneZone, meetingWording: meetingWording)
    }

    init(
        account: Account, store: MailStore, secrets: any SecretStore, lock: AccountLock, session: URLSession,
        now: @escaping @Sendable () -> Date, phoneZone: @escaping @Sendable () -> TimeZone,
        meetingWording: MeetingWording = .english
    ) {
        self.account = account
        self.store = store
        self.secrets = secrets
        self.lock = lock
        self.session = session
        self.now = now
        self.phoneZone = phoneZone
        self.meetingWording = meetingWording
    }

    func retire() {
        retired = true
    }

    // MARK: - Public operations

    /// Sends the queued changes, then brings every calendar in step (also when the server failed a
    /// change). A calendar that fails is skipped and its error thrown once the others are done.
    public func sync() async throws(SyncError) {
        guard let client = try client() else {
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
            for (remote, local) in calendars {
                do {
                    try await exclusive { () async throws(SyncError) in
                        try await syncCalendar(remote, local, client)
                    }
                } catch {
                    firstError = firstError ?? error
                    if case .dav(.net) = error { break }
                    if case .dav(.unauthorized) = error { break }
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
        guard let client = try client() else {
            return
        }
        try await exclusive { () async throws(SyncError) in
            try await runQueue(client)
        }
    }

    // MARK: - Calendars

    /// The server's calendars that hold events, stored, paired with their ids here.
    private func listCalendars(_ client: CalDAVClient) async throws(SyncError) -> [(RemoteCalendar, CalendarID)] {
        let remote = try await dav { () async throws(DAVError) in try await client.calendars() }.filter(\.holdsEvents)
        // Whether the server answers invitations itself (RFC 6638 › 2); not known this round, the
        // last answer stands.
        if let schedules = try? await client.schedules() {
            try stored { try store.setServerSchedules(schedules, for: account.id) }
        }
        try stored {
            try store.replaceCalendars(
                remote.map { calendar in
                    (
                        href: calendar.href.absoluteString, name: calendar.name, color: Self.color(calendar.color),
                        isReadOnly: calendar.isReadOnly
                    )
                }, for: account.id)
        }
        let local = try stored { try store.calendars(account.id) }
        let ids = Dictionary(local.map { ($0.href, $0.id) }, uniquingKeysWith: { first, _ in first })
        return remote.compactMap { calendar in ids[calendar.href.absoluteString].map { (calendar, $0) } }
    }

    /// 0xRRGGBB of `#RRGGBB`.
    static func color(_ text: String?) -> Int? {
        guard let text, text.hasPrefix("#") else { return nil }
        return Int(text.dropFirst(), radix: 16)
    }

    private func syncCalendar(
        _ remote: RemoteCalendar, _ local: CalendarID, _ client: CalDAVClient
    ) async throws(SyncError) {
        let zone = phoneZone()
        let span = Span(window: CalendarWindow.window(now: now(), zone: zone), zone: zone)
        let window = span.window
        let start = CalendarWindow.day(window.lowerBound, zone: zone)
        let token = try stored { try store.syncToken(local) }
        let listedFrom = try stored { try store.windowListedFrom(local) }
        let held = Held(
            known: try stored { try store.remoteETags(local) }, skipped: try stored { try store.skippedEvents(local) })
        let ctag = remote.ctag.map { Self.ctagPrefix + $0 }
        let usesTokens = remote.offersSyncCollection && token?.hasPrefix(Self.ctagPrefix) != true
        var diff: CalendarDiff
        if listedFrom != start {
            diff = try await listing(remote, window, held, moved: true, client)
        } else if usesTokens, token != nil {
            if let token, token == remote.syncToken {
                return
            }
            do {
                diff = held.diff(try await client.changes(remote.href, since: token))
            } catch .tokenInvalid {
                diff = try await listing(remote, window, held, moved: false, client)
            } catch {
                throw .dav(error)
            }
        } else {
            if let ctag, ctag == token {
                return
            }
            diff = try await listing(remote, window, held, moved: false, client)
        }
        if diff.token == nil {
            diff.token = remote.offersSyncCollection ? remote.syncToken : ctag
        }
        try await apply(diff, remote, local, span, client)
        try stored { try store.setWindowListedFrom(start, for: local) }
    }

    /// The server's time-range listing of the window, against what is held.
    private func listing(
        _ remote: RemoteCalendar, _ window: ClosedRange<Date>, _ held: Held, moved: Bool, _ client: CalDAVClient
    ) async throws(SyncError) -> CalendarDiff {
        let server = try await dav { () async throws(DAVError) in
            try await client.etags(remote.href, from: window.lowerBound, to: window.upperBound)
        }
        return held.diff(server, moved: moved)
    }

    /// Fetches the changed objects and stores them, drops the removed ones, then keeps the token. An
    /// object the server did not hand over (gone meanwhile, past the size cap) is not removed; one past
    /// the cap is remembered as refused.
    private func apply(
        _ diff: CalendarDiff, _ remote: RemoteCalendar, _ local: CalendarID, _ span: Span, _ client: CalDAVClient
    ) async throws(SyncError) {
        let objects = try await dav { () async throws(DAVError) in
            try await client.fetch(remote.href, hrefs: diff.fetch)
        }
        for object in objects.found {
            try keep(object, in: local, span)
        }
        // Past the size cap: counted as refused, the copy held (if any) kept.
        for href in objects.oversized.map(\.absoluteString) {
            try stored {
                try store.setSkippedEvent(href: href, etag: diff.etags[href] ?? "", refused: true, in: local)
            }
        }
        if !diff.removed.isEmpty {
            try stored { try store.removeRemote(hrefs: diff.removed, in: local) }
        }
        try stored { try store.removeSkippedEvents(hrefs: diff.forgotten, in: local) }
        try stored { try store.setSyncToken(diff.token, for: local) }
    }

    /// Stores an object as the server has it (`CalendarObjects.keep`).
    private func keep(_ object: RemoteResource, in local: CalendarID, _ span: Span) throws(SyncError) {
        try CalendarObjects.keep(
            href: object.href.absoluteString, etag: object.etag, data: object.data, scheduleTag: object.scheduleTag,
            in: local, window: span.window, zone: span.zone, store: store)
    }

    /// The window events are held for, and the phone's zone they are laid out in.
    struct Span {
        let window: ClosedRange<Date>
        let zone: TimeZone
    }

    /// What a calendar's sync found: the objects to fetch, the hrefs gone, the skipped hrefs to forget,
    /// the token to keep.
    struct CalendarDiff {
        var fetch: [URL]
        /// The ETag each object to fetch was listed with.
        var etags: [String: String]
        var removed: [String]
        var forgotten: [String]
        var token: String?
    }

    // MARK: - Running

    /// A client for the account's CalDAV address, or nil when it has none or the owner turned the
    /// calendar off. Credentials go only where `DAVTrust` allows.
    private func client() throws(SyncError) -> CalDAVClient? {
        guard !account.calDAVOff, let text = account.calDAV, let context = URL(string: text), context.host() != nil
        else {
            return nil
        }
        guard let secret = try secrets.password(for: account.id) else {
            throw .noPassword
        }
        return CalDAVClient(
            context: context, credentials: DAVCredentials(user: account.user, password: secret.reveal()),
            trustedHosts: DAVTrust.hosts(for: context, of: account), session: session)
    }

    /// Runs `body` with no other operation of this account in between.
    func exclusive<T>(_ body: () async throws(SyncError) -> T) async throws(SyncError) -> T {
        // A task cancelled while it waits gets no turn.
        guard await lock.acquire() else {
            throw .dav(.net)
        }
        guard !retired else {
            await lock.release()
            throw .dav(.net)
        }
        do {
            let result = try await body()
            await lock.release()
            return result
        } catch {
            await lock.release()
            throw error
        }
    }
}

extension CalendarSyncer {
    /// The calendar's objects held as events, and those the server has that are not kept, by href.
    struct Held {
        let known: [String: String]
        let skipped: [String: (etag: String, refused: Bool)]

        /// What differs from a listing of the window. An object skipped before is fetched again only
        /// when its ETag changed, or (when it had no occurrence in the window) when the window moved.
        func diff(_ server: [URL: String], moved: Bool) -> CalendarDiff {
            let listed = Set(server.keys.map(\.absoluteString))
            let wanted = server.filter { href, etag in
                let key = href.absoluteString
                if known[key] == etag { return false }
                guard let skip = skipped[key], skip.etag == etag else { return true }
                return moved && !skip.refused
            }
            return CalendarDiff(
                fetch: Array(wanted.keys),
                etags: Dictionary(
                    wanted.map { ($0.key.absoluteString, $0.value) }, uniquingKeysWith: { _, last in last }),
                removed: known.keys.filter { !listed.contains($0) },
                forgotten: skipped.keys.filter { !listed.contains($0) }, token: nil)
        }

        /// What sync-collection reported: the changed objects not held at that ETag already.
        func diff(_ changes: CollectionChanges) -> CalendarDiff {
            let fetch = changes.changed.filter { change in
                let key = change.href.absoluteString
                return change.etag.isEmpty || (known[key] != change.etag && skipped[key]?.etag != change.etag)
            }
            let removed = changes.removed.map(\.absoluteString)
            let etags = Dictionary(
                fetch.map { ($0.href.absoluteString, $0.etag) }, uniquingKeysWith: { _, last in last })
            return CalendarDiff(
                fetch: fetch.map(\.href), etags: etags, removed: removed, forgotten: removed, token: changes.token)
        }
    }
}
