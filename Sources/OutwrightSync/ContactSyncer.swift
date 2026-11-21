// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
import OutwrightDAV
public import OutwrightModel
public import OutwrightStore
public import OutwrightNet

/// Keeps one account's address books in step with its CardDAV server: the owner's queued
/// changes first, then every book by sync-collection (or ETags where the server has none).
/// Each step runs under the account's lock, between the mail operations.
public actor ContactSyncer {
    public internal(set) var account: Account
    let store: MailStore
    let secrets: any SecretStore
    let lock: AccountLock
    let session: URLSession
    /// Replaced by another syncer for the account: does nothing more.
    var retired = false
    /// The contact addresses stored mail was last sorted against; nil before the first sort.
    var sortedFor: Set<String>?
    /// A sync token slot holding a ctag (for a book without sync-collection) starts so.
    static let ctagPrefix = "ctag:"

    public init(
        account: Account, store: MailStore, secrets: any SecretStore, session: URLSession = HTTPSession.shared
    ) {
        self.init(account: account, store: store, secrets: secrets, lock: AccountLock(), session: session)
    }

    init(account: Account, store: MailStore, secrets: any SecretStore, lock: AccountLock, session: URLSession) {
        self.account = account
        self.store = store
        self.secrets = secrets
        self.lock = lock
        self.session = session
    }

    func retire() {
        retired = true
    }

    // MARK: - Public operations

    /// Sends the queued changes, then brings every address book in step (also when the server
    /// failed a change). A book that fails is skipped and its error thrown once the others are done.
    public func sync() async throws(SyncError) {
        guard let client = try client() else {
            return
        }
        var firstError: SyncError?
        do {
            let books = try await exclusive { () async throws(SyncError) in
                do throws(SyncError) {
                    try await runQueue(client)
                } catch {
                    // The server's trouble with one change does not keep its changes from coming in.
                    guard Self.isServerTrouble(error) else { throw error }
                    firstError = error
                }
                return try await listBooks(client)
            }
            for (remote, local) in books {
                do {
                    try await exclusive { () async throws(SyncError) in
                        try await syncBook(remote, local, client)
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
        try finish(firstError)
    }

    /// Sends the queued changes only.
    public func runChanges() async throws(SyncError) {
        guard let client = try client() else {
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

    /// Sorts stored mail again whatever step failed (the owner's own edits change the contacts
    /// too), then throws the first failure.
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

    // MARK: - Books

    /// The server's books, stored, paired with their ids here.
    private func listBooks(_ client: CardDAVClient) async throws(SyncError) -> [(RemoteAddressBook, AddressBookID)] {
        let remote = try await dav { () async throws(DAVError) in try await client.addressBooks() }
        try stored {
            try store.replaceAddressBooks(
                remote.map { (href: $0.href.absoluteString, name: $0.name, isReadOnly: $0.isReadOnly) },
                for: account.id)
        }
        let local = try stored { try store.addressBooks(account.id) }
        let ids = Dictionary(local.map { ($0.href, $0.id) }, uniquingKeysWith: { first, _ in first })
        return remote.compactMap { book in ids[book.href.absoluteString].map { (book, $0) } }
    }

    private func syncBook(
        _ remote: RemoteAddressBook, _ local: AddressBookID, _ client: CardDAVClient
    ) async throws(SyncError) {
        let token = try stored { try store.syncToken(local) }
        let known = try stored { try store.remoteETags(local) }
        var diff: BookDiff
        if remote.offersSyncCollection, token?.hasPrefix(Self.ctagPrefix) != true {
            if let token, token == remote.syncToken {
                return
            }
            do {
                let changes = try await client.changes(remote.href, since: token)
                let fetch = changes.changed.filter { $0.etag.isEmpty || known[$0.href.absoluteString] != $0.etag }
                diff = BookDiff(
                    fetch: fetch.map(\.href), removed: changes.removed.map(\.absoluteString), token: changes.token)
            } catch .tokenInvalid {
                diff = try await etagDiff(remote, known, client)
                diff.token = remote.syncToken
            } catch {
                throw .dav(error)
            }
        } else {
            let ctag = remote.ctag.map { Self.ctagPrefix + $0 }
            if let ctag, ctag == token, !remote.offersSyncCollection {
                return
            }
            diff = try await etagDiff(remote, known, client)
            diff.token = remote.offersSyncCollection ? remote.syncToken : ctag
        }
        try await apply(diff, remote, local, client)
    }

    /// What differs between the ETags held and the server's listing of the book.
    private func etagDiff(
        _ remote: RemoteAddressBook, _ known: [String: String], _ client: CardDAVClient
    ) async throws(SyncError) -> BookDiff {
        let server = try await dav { () async throws(DAVError) in try await client.etags(remote.href) }
        let keys = Set(server.keys.map(\.absoluteString))
        let fetch = server.filter { known[$0.key.absoluteString] != $0.value }.map(\.key)
        return BookDiff(fetch: fetch, removed: known.keys.filter { !keys.contains($0) }, token: nil)
    }

    /// Fetches the changed cards and stores them, drops the removed ones, then keeps the token.
    /// A card the server did not hand over (gone meanwhile, past the size cap) is not removed.
    private func apply(
        _ diff: BookDiff, _ remote: RemoteAddressBook,
        _ local: AddressBookID, _ client: CardDAVClient
    ) async throws(SyncError) {
        // A card the server left out (past the size cap) is not removed, and the token still moves
        // on: it is fetched again when it next changes, never deleted here.
        let cards = try await dav { () async throws(DAVError) in
            try await client.cards(remote.href, hrefs: diff.fetch)
        }
        for card in cards {
            try keep(card, in: local)
        }
        if !diff.removed.isEmpty {
            try stored { try store.removeRemote(hrefs: diff.removed, in: local) }
        }
        try stored { try store.setSyncToken(diff.token, for: local) }
    }

    /// Stores a card as the server has it. Groups are not contacts: they are left on the server
    /// untouched and not stored. A card that cannot be read is skipped.
    private func keep(_ card: RemoteCard, in book: AddressBookID) throws(SyncError) {
        guard let parsed = Self.parse(card.data), !parsed.isGroup else {
            return
        }
        let fields = parsed.fields
        _ = try stored {
            try store.upsertRemote(
                href: card.href.absoluteString, etag: card.etag, vcard: card.data,
                details: ContactMapping.details(fields), photo: fields.photo, in: book)
        }
    }

    /// What a book's sync found: the cards to fetch, the hrefs gone, the token to keep.
    struct BookDiff {
        var fetch: [URL]
        var removed: [String]
        var token: String?
    }

    static func parse(_ data: Data) -> VCard? {
        (try? VCardReader.cards(data))?.first
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

    // MARK: - Running

    /// A client for the account's CardDAV address, or nil when it has none or the owner turned the
    /// contacts off. Credentials go only where `DAVTrust` allows.
    private func client() throws(SyncError) -> CardDAVClient? {
        guard !account.cardDAVOff, let text = account.cardDAV, let context = URL(string: text),
            context.host() != nil
        else {
            return nil
        }
        guard let secret = try secrets.password(for: account.id) else {
            throw .noPassword
        }
        return CardDAVClient(
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
