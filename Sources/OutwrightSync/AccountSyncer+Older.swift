// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightIMAP
public import OutwrightModel
import OutwrightStore

/// Mail older than the sync window, fetched when the owner scrolls to the end of a list.
extension AccountSyncer {
    /// The first stretch looked at before the day the folder is held back to; each stretch with
    /// too little in it is followed by one twice as long, and past this the rest is taken whole.
    static let olderSpan: TimeInterval = 30 * 86_400
    static let olderSpanLimit: TimeInterval = 50 * 365 * 86_400

    /// Brings in the headers of the folder's mail from before what is held, newest stretch
    /// first, until at least `atLeast` messages came or nothing older is left. Returns whether
    /// older mail is left on the server.
    public func fetchOlder(_ id: FolderID, atLeast: Int) async throws(SyncError) -> Bool {
        try await exclusive { () async throws(SyncError) in
            try await withMain { client async throws(SyncError) in
                try await fetchOlder(id, atLeast: max(1, atLeast), client)
            }
        }
    }

    private func fetchOlder(_ id: FolderID, atLeast: Int, _ client: IMAPClient) async throws(SyncError) -> Bool {
        guard let folder = try stored({ try store.folders(account.id) }).first(where: { $0.id == id }),
              folder.uidValidity != 0
        else {
            return false
        }
        let status = try await imap { try await client.select(folder.path) }
        guard status.uidValidity == folder.uidValidity else {
            // Renumbered: the next synchronisation starts the folder over.
            return true
        }
        var end = try stored { try store.heldSince(id) } ?? now().addingTimeInterval(-Self.window)
        let local = try stored { try store.folderIndex(id) }
        var left = Set(try await imap { try await client.uids(since: nil, before: end) })
            .subtracting(try notNew(id, local))
        guard !left.isEmpty else {
            return false
        }
        var builder = RowBuilder(
            account: account, folder: folder, store: store,
            correspondents: try stored { try store.knownSenders(account.id) },
            overrides: try stored { try store.overrides() })
        var span = Self.olderSpan
        var fetched = 0
        while true {
            let start = span > Self.olderSpanLimit ? nil : end.addingTimeInterval(-span)
            let found = try await imap { try await client.uids(since: start, before: end) }
            let wanted = Set(found).intersection(left).sorted(by: >)
            for part in stride(from: 0, to: wanted.count, by: Self.batch) {
                let uids = Array(wanted[part..<min(part + Self.batch, wanted.count)])
                let summaries = try await imap { try await client.summaries(uids: uids) }
                let rows = summaries.filter { !$0.flags.contains("\\Deleted") }.map { builder.row($0) }
                _ = try stored { try store.upsert(rows) }
            }
            left.subtract(wanted)
            fetched += wanted.count
            guard let start else {
                try stored { try store.setHeldSince(id, .distantPast) }
                return false
            }
            try stored { try store.setHeldSince(id, start) }
            if left.isEmpty {
                return false
            }
            if fetched >= atLeast {
                return true
            }
            end = start
            span *= 2
        }
    }
}
