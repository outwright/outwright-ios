// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
import OutwrightIMAP
import OutwrightMIME
public import OutwrightModel
import OutwrightNet
public import OutwrightStore

/// Keeps one account's store in step with its IMAP server: folders, the last 90 days of
/// headers in each folder, bodies on request, and the owner's queued changes.
///
/// Operations run one at a time on a connection of their own; IDLE has a second one, so a
/// change can be sent while the Inbox is watched.
public actor AccountSyncer {
    static let window: TimeInterval = 90 * 86_400
    /// Short, so a connection a mobile network dropped without a word is found within minutes.
    public static let idleTimeout: Duration = .seconds(9 * 60)
    static let batch = 200
    static let maxFolders = 1_000
    static let madeWhenMissing: [(FolderKind, String)] = [
        (.sent, "Sent"), (.drafts, "Drafts"), (.trash, "Trash"), (.junk, "Junk"), (.archive, "Archive")
    ]

    public internal(set) var account: Account
    let store: MailStore
    let credentials: CredentialProvider
    let now: @Sendable () -> Date
    /// The phone's time zone now: what an invitation from mail is laid out in.
    let phoneZone: @Sendable () -> TimeZone
    var main: IMAPClient?
    var idler: IMAPClient?
    let lock: AccountLock
    let idleTimeout: Duration
    /// The protections the build carries, for what is sent and saved.
    let protections: [any MailProtection]
    let journal: DiagnosticsJournal?
    /// Counts `disconnect`s, so an operation does not open again what was closed under it.
    var generation = 0
    /// Replaced by another syncer for the account: does nothing more.
    var retired = false
    /// A push's fetch runs without sending the queue: the server's flags then leave the messages
    /// with changes still queued alone (the server has not heard of them yet).
    var keepsQueuedFlags = false
    /// Where a new top-level folder goes (the personal namespace's prefix), as the last folder
    /// sync found it; nil before one.
    public internal(set) var folderPrefix: String?

    public init(
        account: Account, store: MailStore, secrets: any SecretStore,
        now: @escaping @Sendable () -> Date = { Date() }, phoneZone: @escaping @Sendable () -> TimeZone = { .current },
        protections: [any MailProtection] = []
    ) {
        self.init(
            account: account, store: store, credentials: CredentialProvider(secrets: secrets), now: now,
            phoneZone: phoneZone, lock: AccountLock(), protections: protections)
    }

    /// `journal`: where each send's outcome is noted (nil: nowhere).
    public init(
        account: Account, store: MailStore, credentials: CredentialProvider,
        now: @escaping @Sendable () -> Date = { Date() }, phoneZone: @escaping @Sendable () -> TimeZone = { .current },
        protections: [any MailProtection] = [], journal: DiagnosticsJournal? = nil
    ) {
        self.init(
            account: account, store: store, credentials: credentials, now: now, phoneZone: phoneZone,
            lock: AccountLock(), protections: protections, journal: journal)
    }

    init(
        account: Account, store: MailStore, credentials: CredentialProvider, now: @escaping @Sendable () -> Date,
        phoneZone: @escaping @Sendable () -> TimeZone = { .current }, lock: AccountLock,
        idleTimeout: Duration = AccountSyncer.idleTimeout, protections: [any MailProtection] = [],
        journal: DiagnosticsJournal? = nil
    ) {
        self.journal = journal
        self.protections = protections
        self.idleTimeout = idleTimeout
        self.phoneZone = phoneZone
        self.account = account
        self.store = store
        self.credentials = credentials
        self.now = now
        self.lock = lock
    }

    // MARK: - Public operations

    /// Reads the server's folders into the store. Known folders keep their id, messages and
    /// favourite mark. An account without an archive gets a local `Archive`, made on the
    /// server the first time something is archived.
    public func syncFolders() async throws(SyncError) {
        _ = try await exclusive { () async throws(SyncError) in
            try await withMain { client async throws(SyncError) in
                try await refreshFolders(client)
            }
        }
    }

    /// Fetches and keeps a message's whole body, without marking it read.
    public func fetchBody(_ message: MessageID) async throws(SyncError) {
        try await exclusive { () async throws(SyncError) in
            try await fetchBodies([message])
        }
    }

    /// Sends the queued changes in order. A change the server refuses stays queued (with any
    /// later change to the same message) and its error is thrown once the rest are done.
    public func runActions() async throws(SyncError) {
        try await exclusive { () async throws(SyncError) in
            let pending = try stored { try store.pendingActions() }
            guard pending.contains(where: { $0.accountID == account.id }) else {
                return
            }
            try await withMain { client async throws(SyncError) in
                if let refusal = try await runQueue(client) {
                    throw refusal
                }
            }
        }
    }

    /// Waits on the Inbox (IDLE, on its own connection) for up to 9 minutes; true when it changed.
    public func idleInbox() async throws(SyncError) -> Bool {
        guard !retired else {
            throw .imap(.net(.closed))
        }
        let inbox = try await inboxFolder()
        let opened = generation
        let client: IMAPClient
        if let idler {
            client = idler
        } else {
            client = try await connect(since: opened)
            idler = client
        }
        do {
            _ = try await client.select(inbox.path)
            return try await client.idle(timeout: idleTimeout)
        } catch {
            if SyncError.imap(error).breaksConnection {
                if idler === client {
                    idler = nil
                }
                await client.logout()
            }
            throw .imap(error)
        }
    }

    /// Logs out of the main connection and closes the IDLE one (which may be waiting on a server
    /// that stopped answering); the next operation opens them again.
    public func disconnect() async {
        generation &+= 1
        let (kept, watching) = (main, idler)
        main = nil
        idler = nil
        await watching?.close()
        if let kept {
            await Self.logOut(kept)
        }
    }

    /// LOGOUT, closed after two seconds without an answer (a server that stopped answering).
    static func logOut(_ client: IMAPClient) async {
        let deadline = Task {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled {
                await client.close()
            }
        }
        await client.logout()
        deadline.cancel()
    }

    /// Closes the IDLE connection at once; an IDLE on it fails.
    func closeIdler() async {
        let watching = idler
        idler = nil
        await watching?.close()
    }

    // MARK: - Internal operations

    /// Folders first when the store has none, then the Inbox.
    func syncInbox() async throws(SyncError) {
        try await sync(try await inboxFolder().id)
    }

    func inboxFolder() async throws(SyncError) -> Folder {
        if let inbox = try stored({ try store.folders(account.id) }).first(where: { $0.kind == .inbox }) {
            return inbox
        }
        try await syncFolders()
        guard let inbox = try stored({ try store.folders(account.id) }).first(where: { $0.kind == .inbox }) else {
            throw .store("noSuchFolder")
        }
        return inbox
    }

    /// Bodies for up to `limit` messages of the Inbox that have none yet, newest first; among them an
    /// invitation held whose intake has not run yet (it failed) is taken again.
    func prefetchInbox(limit: Int) async throws(SyncError) {
        let inbox = try await inboxFolder()
        try await exclusive { () async throws(SyncError) in
            let query = InboxQuery(scope: .folder(inbox.id), inboxClass: nil, filter: .all)
            let rows = try stored { try store.messages(query, limit: limit) }
            try await fetchBodies(rows.filter { (!$0.hasBody || $0.isInvitation) && $0.uid > 0 }.map(\.id))
        }
    }

    func fetchBodies(_ ids: [MessageID]) async throws(SyncError) {
        let folders = try stored { try store.folders(account.id) }
        var wanted: [(row: MessageRow, folder: Folder)] = []
        var held: [(row: MessageRow, folder: Folder)] = []
        for id in ids {
            guard let row = try stored({ try store.message(id) }), row.accountID == account.id else {
                throw .store("noSuchMessage")
            }
            if row.hasBody {
                // Only one the intake never ran for (it failed): one waiting for a calendar sync is
                // taken again by that sync, and taken now it would count as having waited.
                if row.isInvitation, let folder = folders.first(where: { $0.id == row.folderID }),
                    !(try stored { try store.hasInvitationRecord(row.id) }) {
                    held.append((row, folder))
                }
                continue
            }
            guard row.uid > 0, let folder = folders.first(where: { $0.id == row.folderID }) else {
                throw .store("notOnServer")
            }
            wanted.append((row, folder))
        }
        var bodies: [FetchedBody] = []
        for (row, folder) in held {
            if let data = try stored({ try store.body(row.id) }) {
                bodies.append(FetchedBody(row: row, data: data, folder: folder))
            }
        }
        // The bodies fetched before a failure still go to the intake, oldest first.
        defer { takeInvitations(bodies) }
        guard !wanted.isEmpty else {
            return
        }
        try await withMain { client async throws(SyncError) in
            var selected: String?
            for (row, folder) in wanted {
                if selected != folder.path {
                    _ = try await imap { try await client.select(folder.path) }
                    selected = folder.path
                }
                let data = try await imap { try await client.body(uid: row.uid) }
                let opened = try stored { try store.setBody(data, for: row.id) }
                await learn(from: opened, in: folder)
                bodies.append(FetchedBody(row: row, data: data, folder: folder, opened: opened))
            }
        }
    }

    /// What each protection learns from a message just stored (its keys, say).
    private func learn(from opened: OpenedMessage?, in folder: Folder) async {
        guard let opened else { return }
        for hook in protections {
            await hook.learn(from: opened.message, facts: opened.facts, folder: folder.kind, account: account)
        }
    }

    func runQueue(_ client: IMAPClient) async throws(SyncError) -> SyncError? {
        let pending = try stored { try store.pendingActions() }.filter { $0.accountID == account.id }
        guard !pending.isEmpty else {
            return nil
        }
        let opened = generation
        var runner = ActionRunner(
            account: account, store: store, client: client, credentials: credentials, now: now(),
            folders: try stored { try store.folders(account.id) }, protections: protections,
            mayContinue: { await self.isCurrent(opened) })
        runner.journal = journal
        let first = try await runner.run(pending)
        // What those actions queued in turn (filing a sent message) goes in the same run.
        let last = pending.map(\.id).max() ?? 0
        let followUps = try stored { try store.pendingActions() }.filter { $0.accountID == account.id && $0.id > last }
        guard !followUps.isEmpty else {
            return first
        }
        let second = try await runner.run(followUps)
        // A folder refusal is kept in the store for the owner: any other error is told first.
        return [first, second].compactMap { $0 }.first { !$0.isFolderRefusal } ?? first ?? second
    }
}

/// Signing in and holding the connections.
extension AccountSyncer {
    // MARK: - Connections

    static func endpoint(_ endpoint: MailEndpoint) -> ServerEndpoint? {
        TransportSecurity(rawValue: endpoint.security).map {
            ServerEndpoint(host: endpoint.host, port: endpoint.port, security: $0)
        }
    }

    private func connect() async throws(SyncError) -> IMAPClient {
        guard let endpoint = Self.endpoint(account.imap) else {
            throw .imap(.net(.io("Unknown transport security")))
        }
        return try await credentials.connect(endpoint, account: account)
    }

    /// A connection opened while nothing disconnected the account (generation `opened`); one
    /// that comes up after a `disconnect` or a retirement is logged out, not kept.
    private func connect(since opened: Int) async throws(SyncError) -> IMAPClient {
        let client = try await connect()
        guard opened == generation, !retired else {
            await Self.logOut(client)
            throw .imap(.net(.closed))
        }
        return client
    }

    /// Runs `body` on the main connection. A kept connection that turns out to be closed (the
    /// server let it go while it was unused) is opened again and `body` run once more.
    func withMain<T>(_ body: (IMAPClient) async throws(SyncError) -> T) async throws(SyncError) -> T {
        let reused = main != nil
        let opened = generation
        let client: IMAPClient
        if let main {
            client = main
        } else {
            client = try await connect(since: opened)
            main = client
        }
        do {
            return try await body(client)
        } catch {
            guard error.breaksConnection else {
                throw error
            }
            await drop(client)
            guard reused, opened == generation, !retired else {
                throw error
            }
        }
        let fresh = try await connect(since: opened)
        main = fresh
        do {
            return try await body(fresh)
        } catch {
            if error.breaksConnection {
                await drop(fresh)
            }
            throw error
        }
    }

    private func drop(_ client: IMAPClient) async {
        if main === client {
            main = nil
        }
        await client.logout()
    }

    /// Runs `body` with no other operation of this account in between, by this syncer or any
    /// other the account has (a SELECT of another folder would pull the rug from under it; two
    /// queues run at once could send a message twice).
    func exclusive<T>(_ body: () async throws(SyncError) -> T) async throws(SyncError) -> T {
        // A task cancelled while it waits gets no turn.
        guard await lock.acquire() else {
            throw .imap(.net(.closed))
        }
        guard !retired else {
            await lock.release()
            throw .imap(.net(.closed))
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
