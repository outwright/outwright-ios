// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
import OutwrightIMAP
public import OutwrightModel
public import OutwrightStore

/// What the servers are asked for mail the phone does not hold: words, and/or mail from (or to or
/// copied to) any of `people`, and/or only mail from before `before`.
public struct ServerQuery: Hashable, Sendable {
    public var text: String
    public var people: Set<String>
    /// For `people`: from them, or to or copied to them; nil asks for both.
    public var direction: PersonDirection?
    public var before: Date?

    public init(text: String, people: Set<String> = [], direction: PersonDirection? = nil, before: Date? = nil) {
        self.text = text
        self.people = people
        self.direction = direction
        self.before = before
    }

    /// Nothing to ask: no words, no people and no age.
    public var searchesNothing: Bool { searches.isEmpty }

    /// Most addresses one query asks about.
    static let maxPeople = 5

    /// The SEARCHes a folder is asked: one per address and header, or one without people.
    var searches: [IMAPSearch] {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let wordsOrNil = words.isEmpty ? nil : words
        let addresses = people.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }.sorted().prefix(Self.maxPeople)
        guard !addresses.isEmpty else {
            return wordsOrNil == nil && before == nil ? [] : [IMAPSearch(text: wordsOrNil, before: before)]
        }
        return addresses.flatMap { address -> [IMAPSearch] in
            let from = IMAPSearch(text: wordsOrNil, from: address, before: before)
            let to = IMAPSearch(text: wordsOrNil, to: address, before: before)
            let cc = IMAPSearch(text: wordsOrNil, cc: address, before: before)
            switch direction {
            case .from: return [from]
            case .to: return [to, cc]
            case nil: return [from, to, cc]
            }
        }
    }
}

/// Asking the server for mail the phone does not hold (older than the sync window).
extension AccountSyncer {
    static let searchedKinds: Set<FolderKind> = [.inbox, .sent, .archive, .other]

    /// Searches the account's mail folders on the server (`SEARCH TEXT`) and brings in the
    /// headers of up to `limit` matches it did not hold, newest first. Returns their ids.
    public func searchServer(_ text: String, limit: Int) async throws(SyncError) -> [MessageID] {
        try await searchServer(ServerQuery(text: text), limit: limit)
    }

    /// Searches the account's mail folders on the server for `query` and brings in the headers of up
    /// to `limit` matches it did not hold, newest first. Returns their ids.
    public func searchServer(_ query: ServerQuery, limit: Int) async throws(SyncError) -> [MessageID] {
        let searches = query.searches
        guard !searches.isEmpty, limit > 0 else {
            return []
        }
        return try await exclusive { () async throws(SyncError) in
            try await withMain { client async throws(SyncError) in
                let folders = try stored { try store.folders(account.id) }
                    .filter { Self.searchedKinds.contains($0.kind) }
                    .prefix(Self.maxFolders)
                var found: [MessageID] = []
                for folder in folders where found.count < limit {
                    found += try await searchFolder(folder, searches, limit: limit - found.count, client)
                }
                return found
            }
        }
    }

    private func searchFolder(
        _ folder: Folder, _ searches: [IMAPSearch], limit: Int, _ client: IMAPClient
    ) async throws(SyncError) -> [MessageID] {
        let status: FolderStatus
        do {
            status = try await client.select(folder.path)
        } catch {
            // A folder made here and not on the server yet: nothing to search, as in a sync of it.
            switch error {
            case .folderMissing, .no:
                if folder.uidValidity == 0 {
                    return []
                }
            default:
                break
            }
            throw .imap(error)
        }
        if folder.uidValidity == 0 {
            // Not opened on this phone yet (its first sync may still be to come): searched all the same.
            try adoptUIDValidity(folder.id, status.uidValidity)
        } else if status.uidValidity != folder.uidValidity {
            // Renumbered: the numbers held here mean nothing now, as in a sync of the folder.
            try stored { try store.resetFolder(folder.id, uidValidity: status.uidValidity) }
        }
        var hits = Set<UInt32>()
        for search in searches {
            hits.formUnion(try await imap { try await client.search(search) })
        }
        let local = try stored { try store.folderIndex(folder.id) }
        let missing = Array(hits.subtracting(try notNew(folder.id, local)).sorted(by: >).prefix(limit))
        guard !missing.isEmpty else {
            return []
        }
        var builder = RowBuilder(
            account: account, folder: folder, store: store,
            correspondents: try stored { try store.knownSenders(account.id) },
            overrides: try stored { try store.overrides() })
        let summaries = try await imap { try await client.summaries(uids: missing) }
        let rows = summaries.filter { !$0.flags.contains("\\Deleted") }.map { builder.row($0) }
        return try stored { try store.upsert(rows) }
    }
}
