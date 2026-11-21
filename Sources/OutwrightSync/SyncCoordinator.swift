// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
import OutwrightDAV
import OutwrightGraph
public import OutwrightModel
public import OutwrightStore
import Synchronization
public import OutwrightNet

/// Keeps every account of the store in step: a refresh of all folders on request, the Inbox
/// watched (IDLE) while the app is in front, bodies fetched on request or ahead of time.
public actor SyncCoordinator {
    static let prefetchLimit = 100

    let store: MailStore
    public nonisolated let secrets: any SecretStore
    /// How every account signs in; one token source per account, shared by all its syncers.
    public nonisolated let credentials: CredentialProvider
    let now: @Sendable () -> Date
    /// The phone's time zone now, read after the system's cached zone is reset.
    let phoneZone: @Sendable () -> TimeZone
    let backoff: ClosedRange<Duration>
    /// How long after a change is queued its account's queue is sent (more changes made meanwhile
    /// go with it).
    let actionDelay: Duration
    let idleTimeout: Duration
    var syncers: [AccountID: (account: Account, syncer: AccountSyncer)] = [:]
    var watchers: [AccountID: Task<Void, Never>] = [:]
    /// The contacts and calendars synced on coming to the front, until `stopForeground`.
    var frontRefresh: Task<Void, Never>?
    var locks: [AccountID: AccountLock] = [:]
    /// The last failure of each account, cleared when it next succeeds.
    public internal(set) var lastErrors: [AccountID: SyncError] = [:]
    /// Accounts whose Inbox has been looked at in this process (whether or not the server answered):
    /// until then an empty list is mail still on its way.
    var inboxFetched: Set<AccountID> = []
    /// How many failures to reach each account's servers came in a row.
    var unreachableInARow: [AccountID: Int] = [:]
    /// The latest cue to send each account's queue; an earlier one that wakes finds itself
    /// replaced and leaves the sending to it.
    var kicks: [AccountID: Int] = [:]
    private let queueWatch = Mutex<Task<Void, Never>?>(nil)
    var contactSyncers: [AccountID: (account: Account, syncer: any ContactSyncing)] = [:]
    /// Where each provider's Graph is (a fake in tests).
    let graphBases: [ProviderID: URL]
    /// The providers this build carries; nil: every one. An account of another is kept, never synced.
    let available: Set<ProviderID>?
    /// Accounts whose CardDAV address was looked for in this process.
    var discoveryTried: Set<AccountID> = []
    var calendarSyncers: [AccountID: (account: Account, syncer: any CalendarSyncing)] = [:]
    /// Accounts whose CalDAV address was looked for in this process.
    var calDAVDiscoveryTried: Set<AccountID> = []
    /// Subscribed calendars being fetched now: one fetch of each at a time.
    var subscriptionRuns: [CalendarID: Task<Void, Never>] = [:]
    /// The phone's notifications, where the events' reminders go.
    public nonisolated let reminders: any Reminders
    /// The protections this build carries, handed to each account's syncer.
    let protections: [any MailProtection]
    /// The phone's notifications, where local new-mail notices go.
    public nonisolated let newMail: any NewMailNotices
    /// Where each protocol's sync and each send is noted for the diagnostics (nil: nowhere).
    public nonisolated let journal: DiagnosticsJournal?
    /// What each account's protocol last noted, and when: a failure the same as the last one is
    /// noted again only after `journalRepeat`.
    var journaled: [JournalKey: (code: String?, at: Date)] = [:]
    /// The latest reschedule of the reminders; each waits for the one before it, so they never interleave.
    var reminderTurn: Task<Void, Never>?
    let resolver: any DoHResolving
    let davSession: URLSession
    let probe: @Sendable (URL) async -> URL?
    /// The iPhone's Contacts, for the accounts that save their contacts there; nil saves nothing.
    let phoneContacts: (any PhoneContacts)?
    /// The words of the reply mails sent for the owner's answers to invitations.
    let meetingWording: MeetingWording
    /// Accounts whose refused access to the phone's Contacts has been told since the setting last
    /// changed.
    var phoneDenialTold: Set<AccountID> = []

    /// `tokens` renews each OAuth provider's tokens; an OAuth account whose provider has none
    /// cannot sign in. `graphBases` is where each provider's Graph is. `available` names the
    /// providers this build carries (nil: all); another's accounts are kept and not synced.
    /// `probe` asks a `/.well-known/carddav` or `/.well-known/caldav` address without credentials (by
    /// default over `davSession`). `phoneZone` is the zone events are laid out in (the phone's).
    /// `meetingWording` is how the reply to an invitation is worded (the app's language).
    public init(
        store: MailStore, secrets: any SecretStore, tokens: [ProviderID: any TokenRefreshing] = [:],
        available: Set<ProviderID>? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        phoneZone: @escaping @Sendable () -> TimeZone = { .current },
        backoff: ClosedRange<Duration> = .seconds(2) ... .seconds(60), actionDelay: Duration = .seconds(1),
        idleTimeout: Duration = AccountSyncer.idleTimeout, resolver: any DoHResolving = CloudflareDoH(),
        davSession: URLSession = HTTPSession.shared, probe: (@Sendable (URL) async -> URL?)? = nil,
        phoneContacts: (any PhoneContacts)? = nil, reminders: any Reminders = SystemReminders(),
        graphBases: [ProviderID: URL] = [:], meetingWording: MeetingWording = .english,
        newMail: any NewMailNotices = SystemNewMailNotices(), protections: [any MailProtection] = [],
        journal: DiagnosticsJournal? = nil
    ) {
        self.journal = journal
        self.protections = protections
        self.newMail = newMail
        self.meetingWording = meetingWording
        self.phoneContacts = phoneContacts
        self.reminders = reminders
        self.graphBases = graphBases
        self.available = available
        self.store = store
        self.secrets = secrets
        self.credentials = CredentialProvider(secrets: secrets, tokens: tokens)
        self.resolver = resolver
        self.davSession = davSession
        self.probe = probe ?? { await WellKnown.probe($0, session: davSession) }
        self.now = now
        self.phoneZone = phoneZone
        self.backoff = backoff
        self.actionDelay = actionDelay
        self.idleTimeout = idleTimeout
        let queued = store.queuedActions()
        queueWatch.withLock {
            $0 = Task { [weak self] in
                for await account in queued {
                    await self?.kick(account)
                }
            }
        }
    }

    deinit {
        queueWatch.withLock { $0?.cancel() }
    }

    /// Folders, then every folder's messages (Sent first, so the Inbox is sorted knowing whom
    /// the owner writes to), then the contacts and the calendars (their CardDAV and CalDAV addresses
    /// looked for first, once per process, when the account has none), for all accounts at once, and
    /// beside them the subscribed calendars; then the reminders. On a new day the events are laid
    /// out again first. A cancelled task (background time that ran out) stops before the next account
    /// or folder.
    public func refreshAll() async {
        guard !Task.isCancelled else {
            return
        }
        reexpandIfNewDay()
        let current = await currentSyncers()
        // Side by side with the accounts: the subscribed calendars belong to none of them, and a slow
        // published calendar holds up no account.
        async let subscriptions: Void = refreshSubscriptions(force: false)
        await withTaskGroup(of: (AccountID, SyncError?).self) { group in
            for (id, syncer) in current {
                group.addTask {
                    let mail = await Self.refresh(syncer)
                    await self.journalSync(id, .mail, mail)
                    await self.inboxWasFetched(id)
                    let contacts = await self.refreshContacts(id)
                    let calendars = await self.refreshCalendars(id)
                    // Only the first failure is recorded: the others would be lost from the log.
                    if mail != nil, let contacts {
                        syncLog.error("Contact sync failed: \(caseName(contacts), privacy: .public)")
                    }
                    if mail ?? contacts != nil, let calendars {
                        syncLog.error("Calendar sync failed: \(caseName(calendars), privacy: .public)")
                    }
                    return (id, mail ?? contacts ?? calendars)
                }
            }
            // A run cut short tells nothing about the account: what it last failed with stays.
            for await (id, error) in group where !Task.isCancelled {
                record(id, error)
            }
        }
        await subscriptions
        sweepPhoneExports()
        await rescheduleReminders()
    }

    /// Watches each account's Inbox until `stopForeground`, opening the connection again after
    /// a failure, waiting 2 seconds at first and twice as long each time up to a minute. Beside it
    /// each account's contacts and calendars are synced once (what changed elsewhere while the app
    /// was away shows without a pull), then the reminders are planned again. Called again while in
    /// front, it does the same for the accounts that came since (one added or restored).
    public func startForeground() async {
        // What failed to reach a server before says nothing about the network now.
        unreachableInARow = [:]
        let current = await currentSyncers()
        let fresh = current.filter { watchers[$0.0] == nil }
        for (id, syncer) in fresh {
            watchers[id] = Task { await self.watch(id, syncer) }
        }
        let previous = frontRefresh
        guard previous == nil || !fresh.isEmpty else {
            return
        }
        let accounts = (previous == nil ? current : fresh).map(\.0)
        // One task for `stopForeground` to cancel and wait for, the earlier sync's included.
        frontRefresh = Task {
            await withTaskCancellationHandler {
                await self.refreshContactsAndCalendars(accounts)
                await previous?.value
            } onCancel: {
                previous?.cancel()
            }
        }
    }

    public func stopForeground() async {
        let refresh = frontRefresh
        frontRefresh = nil
        refresh?.cancel()
        await refresh?.value
        let tasks = watchers
        watchers = [:]
        for task in tasks.values {
            task.cancel()
        }
        // An IDLE ends at once, without waiting for an answer to its DONE (a server that
        // stopped answering would hold the watcher, and the return to the front, for minutes).
        for id in tasks.keys {
            await syncers[id]?.syncer.closeIdler()
        }
        for (id, task) in tasks {
            await task.value
            await syncers[id]?.syncer.disconnect()
        }
    }

    /// The phone is on another network: the connections may be dead without a word (the old
    /// network's address is gone, or its NAT forgot them), so the watching starts again on new
    /// ones. Nothing in the background, where nothing is watched.
    public func networkChanged() async {
        guard !watchers.isEmpty else {
            return
        }
        await stopForeground()
        await startForeground()
    }

    // MARK: - Running

    /// A change was queued for `account`: its queue is sent `actionDelay` from now, with whatever
    /// else is queued by then.
    private func kick(_ account: AccountID) {
        let turn = (kicks[account] ?? 0) &+ 1
        kicks[account] = turn
        let delay = actionDelay
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            await self?.sendQueue(account, turn: turn)
        }
    }

    private func sendQueue(_ account: AccountID, turn: Int) async {
        guard kicks[account] == turn,
              let syncer = await currentSyncers().first(where: { $0.0 == account })?.1
        else {
            return
        }
        // An invitation moved out of Junk goes in the calendar with the move, and to the server below.
        await syncer.retakeInvitations(waitingForCalendars: false)
        // An edit made offline moves its reminder now, not once the server has answered.
        await rescheduleReminders()
        var failure: SyncError?
        do {
            try await syncer.runActions()
        } catch {
            failure = error
        }
        do {
            try await contactSyncer(for: account)?.runChanges()
        } catch {
            failure = failure ?? error
        }
        do {
            try await calendarSyncer(for: account)?.runChanges()
        } catch {
            failure = failure ?? error
        }
        record(account, failure)
        await rescheduleReminders()
    }

    /// A syncer per account in the store. A changed connection gets a new syncer (sharing the
    /// account's lock, so it waits for the old one's operation, which is stopped); a new display
    /// name is handed to the syncer there is; a removed account loses its syncer and watcher.
    func currentSyncers() async -> [(AccountID, AccountSyncer)] {
        guard let accounts = try? store.accounts().filter(isAvailable) else {
            return syncers.map { ($0.key, $0.value.syncer) }
        }
        let ids = Set(accounts.map(\.id))
        for (id, entry) in syncers where !ids.contains(id) {
            watchers.removeValue(forKey: id)?.cancel()
            syncers[id] = nil
            locks[id] = nil
            lastErrors[id] = nil
            inboxFetched.remove(id)
            credentials.forget(id)
            unreachableInARow[id] = nil
            await entry.syncer.retire()
            await contactSyncers.removeValue(forKey: id)?.syncer.retire()
            await calendarSyncers.removeValue(forKey: id)?.syncer.retire()
        }
        for account in accounts {
            if let entry = syncers[account.id], Self.sameConnection(entry.account, account) {
                if entry.account.displayName != account.displayName {
                    syncers[account.id] = (account, entry.syncer)
                    await entry.syncer.update(account)
                }
                continue
            }
            let lock = locks[account.id] ?? AccountLock()
            locks[account.id] = lock
            let syncer = AccountSyncer(
                account: account, store: store, credentials: credentials, now: now, phoneZone: phoneZone,
                lock: lock,
                idleTimeout: idleTimeout, protections: protections, journal: journal)
            let old = syncers[account.id]
            syncers[account.id] = (account, syncer)
            if let old {
                watchers.removeValue(forKey: account.id)?.cancel()
                await old.syncer.retire()
            }
        }
        return accounts.compactMap { account in syncers[account.id].map { (account.id, $0.syncer) } }
    }

    private static func sameConnection(_ first: Account, _ second: Account) -> Bool {
        first.imap == second.imap && first.smtp == second.smtp && first.user == second.user
            && first.email == second.email
    }
}

extension SyncCoordinator {
    /// Folders, then every folder's messages, Sent first; the first failure.
    private static func refresh(_ syncer: AccountSyncer) async -> SyncError? {
        guard !Task.isCancelled else {
            return nil
        }
        do {
            try await syncer.syncFolders()
        } catch {
            return error
        }
        let folders: [Folder]
        do {
            let account = await syncer.account.id
            folders = try stored { try syncer.store.folders(account) }
        } catch {
            return error
        }
        let order: [FolderKind] = [.sent, .inbox, .drafts]
        let sorted = folders.sorted { first, second in
            (order.firstIndex(of: first.kind) ?? order.count) < (order.firstIndex(of: second.kind) ?? order.count)
        }
        var firstError: SyncError?
        for folder in sorted {
            guard !Task.isCancelled else {
                break
            }
            do {
                try await syncer.sync(folder.id)
            } catch {
                firstError = firstError ?? error
                if error.breaksConnection {
                    break
                }
            }
        }
        return firstError
    }
}

extension SyncCoordinator {
    /// Whether this build carries the account's provider.
    func isAvailable(_ account: Account) -> Bool {
        available?.contains(account.provider) ?? true
    }

    /// Where the account's provider has its Graph.
    func graphBase(_ account: Account) -> URL? {
        graphBases[account.provider]
    }
}
