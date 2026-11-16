// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightModel
import OutwrightGraph
import OutwrightStore

extension SyncCoordinator {
    /// Looks for the account's CardDAV address when it has none (once per process), then syncs
    /// its contacts and brings the phone's copy of them in step. Returns the failure, if any. A
    /// Graph account's contacts come through Graph: no CardDAV address is looked for.
    func refreshContacts(_ id: AccountID) async -> SyncError? {
        guard !Task.isCancelled else {
            return nil
        }
        let discovery = await discoverCardDAV(id)
        var failure: SyncError?
        do {
            try await contactSyncer(for: id)?.sync()
        } catch {
            failure = error
        }
        if let phone = refreshPhoneExport(id) {
            failure = failure ?? phone
        }
        return discovery ?? failure
    }

    /// The silent discovery for an account with neither a confirmed nor a found address, unless the
    /// owner chose none. An
    /// address on the account's own domain or mail hosts is used; one elsewhere waits in
    /// `cardDAVUnconfirmed` for the owner, and no password goes there. A save that fails is
    /// returned, and the account is looked at again on the next refresh.
    private func discoverCardDAV(_ id: AccountID) async -> SyncError? {
        guard !discoveryTried.contains(id), let account = storedAccount(id), account.contactsVia == .cardDAV,
            account.cardDAV == nil,
            account.cardDAVUnconfirmed == nil, !account.cardDAVOff
        else {
            return nil
        }
        discoveryTried.insert(id)
        guard let found = await DAVDiscovery.find(.cardDAV, for: account, resolver: resolver, probe: probe),
            var current = storedAccount(id), current.cardDAV == nil, current.cardDAVUnconfirmed == nil,
            !current.cardDAVOff
        else {
            return nil
        }
        if found.offDomain {
            current.cardDAVUnconfirmed = found.url
        } else {
            current.cardDAV = found.url
        }
        do {
            try store.save(current)
            return nil
        } catch {
            discoveryTried.remove(id)
            return .store(String(describing: error))
        }
    }

    private func storedAccount(_ id: AccountID) -> Account? {
        (try? store.accounts())?.first { $0.id == id && isAvailable($0) }
    }

    /// The account's contact syncer (Graph or CardDAV, as the account's contacts come), made anew
    /// when its protocol, contact source, login, address or mail hosts changed (sharing the
    /// account's lock); nil for an account no longer stored, or over Graph with no Graph address.
    func contactSyncer(for id: AccountID) async -> (any ContactSyncing)? {
        guard let account = storedAccount(id) else {
            return nil
        }
        if let entry = contactSyncers[id], Self.sameContacts(entry.account, account) {
            return entry.syncer
        }
        let lock = locks[id] ?? AccountLock()
        locks[id] = lock
        let syncer: any ContactSyncing
        if account.contactsVia == .graph {
            guard let base = graphBase(account) else { return nil }
            syncer = GraphContactSyncer(
                account: account, store: store, credentials: credentials, lock: lock, base: base, session: davSession)
        } else {
            syncer = ContactSyncer(account: account, store: store, secrets: secrets, lock: lock, session: davSession)
        }
        let old = contactSyncers[id]
        contactSyncers[id] = (account, syncer)
        await old?.syncer.retire()
        return syncer
    }

    private static func sameContacts(_ first: Account, _ second: Account) -> Bool {
        first.cardDAV == second.cardDAV && first.cardDAVOff == second.cardDAVOff
            && first.contactsVia == second.contactsVia && first.auth == second.auth
            && first.provider == second.provider && first.user == second.user
            && first.email == second.email
            && first.imap.host == second.imap.host && first.smtp.host == second.smtp.host
    }
}

/// What the coordinator asks of an account's contact sync, CardDAV or Graph.
protocol ContactSyncing: Actor {
    func sync() async throws(SyncError)
    func runChanges() async throws(SyncError)
    func retire()
}

extension ContactSyncer: ContactSyncing {}
extension GraphContactSyncer: ContactSyncing {}
