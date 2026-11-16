// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
import OutwrightGraph
public import OutwrightModel
public import OutwrightStore

/// Keeps a Graph account's contact folders in step with Graph, as `ContactSyncer`
/// does for CardDAV: the owner's queued changes first, then every folder. A folder is listed
/// whole and compared by ETag. A contact's `href` is `<folder path>/contacts/<id>`; its held
/// server copy is the contact's JSON as Graph sent it. Each step runs under the account's lock.
public actor GraphContactSyncer {
    public internal(set) var account: Account
    let store: MailStore
    let credentials: CredentialProvider
    let lock: AccountLock
    let base: URL
    let session: URLSession
    /// Replaced by another syncer for the account: does nothing more.
    var retired = false
    /// The contact addresses stored mail was last sorted against; nil before the first sort.
    var sortedFor: Set<String>?

    public init(
        account: Account, store: MailStore, credentials: CredentialProvider, base: URL,
        session: URLSession = .shared
    ) {
        self.init(
            account: account, store: store, credentials: credentials, lock: AccountLock(), base: base,
            session: session)
    }

    init(
        account: Account, store: MailStore, credentials: CredentialProvider, lock: AccountLock,
        base: URL, session: URLSession = .shared
    ) {
        self.account = account
        self.store = store
        self.credentials = credentials
        self.lock = lock
        self.base = base
        self.session = session
    }

    func retire() {
        retired = true
    }

    // MARK: - Public operations

    /// Sends the queued changes, then brings every folder in step (also when the server failed a
    /// change). A folder that fails is skipped and its error thrown once the others are done.
    public func sync() async throws(SyncError) {
        guard let client = try await client() else {
            return
        }
        var firstError: SyncError?
        do {
            let books = try await exclusive { () async throws(SyncError) in
                do throws(SyncError) {
                    try await runQueue(client)
                } catch {
                    guard Self.isServerTrouble(error) else { throw error }
                    firstError = error
                }
                return try await listBooks(client)
            }
            for (folder, local) in books {
                do {
                    try await exclusive { () async throws(SyncError) in
                        try await syncBook(folder, local, client)
                    }
                } catch {
                    firstError = firstError ?? error
                    guard Self.isServerTrouble(error) else { break }
                }
            }
        } catch {
            firstError = error
        }
        try finish(firstError)
    }

    /// Sends the queued changes only.
    public func runChanges() async throws(SyncError) {
        guard let client = try await client() else {
            return
        }
        var failure: SyncError?
        do {
            try await exclusive { () async throws(SyncError) in
                try await runQueue(client)
            }
        } catch {
            failure = error
        }
        try finish(failure)
    }

    /// Sorts stored mail again whatever step failed, then throws the first failure.
    private func finish(_ failure: SyncError?) throws(SyncError) {
        do {
            try resort()
        } catch {
            throw failure ?? error
        }
        if let failure {
            throw failure
        }
    }

    // MARK: - Folders

    /// The account's folders, stored as address books, paired with their ids here.
    private func listBooks(_ client: GraphClient) async throws(SyncError) -> [(GraphFolder, AddressBookID)] {
        let folders = try await graph { () async throws(GraphError) in try await client.folders() }
        try stored {
            try store.replaceAddressBooks(
                folders.map { (href: $0.path, name: $0.name, isReadOnly: false) }, for: account.id)
        }
        let local = try stored { try store.addressBooks(account.id) }
        let ids = Dictionary(local.map { ($0.href, $0.id) }, uniquingKeysWith: { first, _ in first })
        return folders.compactMap { folder in ids[folder.path].map { (folder, $0) } }
    }

    /// Stores the folder's new and changed contacts and drops the ones Graph no longer lists.
    private func syncBook(
        _ folder: GraphFolder, _ local: AddressBookID, _ client: GraphClient
    ) async throws(SyncError) {
        let contacts = try await graph { () async throws(GraphError) in try await client.contacts(in: folder) }
        let known = try stored { try store.remoteETags(local) }
        var listed: Set<String> = []
        for contact in contacts {
            let href = Self.href(contact.id, in: folder)
            listed.insert(href)
            guard known[href] != contact.etag else { continue }
            _ = try stored {
                try store.upsertRemote(
                    href: href, etag: contact.etag, vcard: contact.json,
                    details: GraphContactMapping.details(contact.fields), photo: nil, in: local)
            }
        }
        let removed = known.keys.filter { !listed.contains($0) }
        if !removed.isEmpty {
            try stored { try store.removeRemote(hrefs: removed, in: local) }
        }
    }

    static func href(_ id: String, in folder: GraphFolder) -> String {
        folder.path + "/contacts/" + id
    }

    // MARK: - Mail

    /// When the account's contact addresses changed, stored mail from contacts moves to Focused.
    private func resort() throws(SyncError) {
        let emails = try stored { try store.contactEmails(account.id) }
        guard emails != sortedFor else {
            return
        }
        _ = try stored { try store.focusContactsMail(account.id) }
        sortedFor = emails
    }
}

extension GraphContactSyncer: GraphSyncing {}
