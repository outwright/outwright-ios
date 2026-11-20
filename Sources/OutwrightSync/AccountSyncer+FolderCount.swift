// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightIMAP
public import OutwrightModel

/// What deleting a folder would take with it on the server.
extension AccountSyncer {
    /// Where new top-level folders go, read from the stored folders: `INBOX` and its delimiter when
    /// every folder the server has, but the Inbox, is under it (as `madePrefix` reads a listing).
    static func storedPrefix(_ folders: [Folder]) -> String {
        guard let delimiter = folders.first(where: { $0.kind == .inbox })?.delimiter, !delimiter.isEmpty else {
            return ""
        }
        let prefix = "INBOX" + delimiter
        let others = folders.filter { $0.kind != .inbox && $0.uidValidity != 0 }
        return !others.isEmpty && others.allSatisfy({ $0.path.uppercased().hasPrefix(prefix) }) ? prefix : ""
    }

    /// How many messages the server holds in the folder and every folder under it.
    public func messageCount(inTreeOf folder: Folder) async throws(SyncError) -> Int {
        try await exclusive { () async throws(SyncError) -> Int in
            try await withMain { client async throws(SyncError) -> Int in
                let listed = try await imap { try await client.listFolders() }
                let tree = listed.filter { each in
                    each.selectable
                        && FolderQueue.remainder(of: each.path, under: folder.path, delimiter: each.delimiter) != nil
                }.prefix(Self.maxFolders)
                // The server has no folder there yet (a rename of it still queued): nothing to tell.
                guard !tree.isEmpty else {
                    throw .imap(.folderMissing(folder.path))
                }
                var total = 0
                for each in tree {
                    let count = try await imap { try await client.messageCount(each.path) }
                    let (sum, overflow) = total.addingReportingOverflow(count)
                    total = overflow ? .max : sum
                }
                return total
            }
        }
    }
}
