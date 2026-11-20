// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import OutwrightModel

/// Mail fetched on demand: bodies and server search.
extension SyncCoordinator {
    /// Bodies of the newest Inbox messages that have none, on Wi-Fi only.
    public func prefetchInboxBodies(onWiFi: Bool) async {
        guard onWiFi else {
            return
        }
        for (id, syncer) in await currentSyncers() {
            do {
                try await syncer.prefetchInbox(limit: Self.prefetchLimit)
            } catch where !error.isUnreachable {
                record(id, error)
            } catch {
                // The watcher beside it decides whether the server can be reached.
            }
        }
    }

    public func fetchBody(_ message: MessageID) async throws(SyncError) {
        guard let row = try stored({ try store.message(message) }),
              let syncer = await currentSyncers().first(where: { $0.0 == row.accountID })?.1
        else {
            throw .store("noSuchMessage")
        }
        try await syncer.fetchBody(message)
    }

    /// Mail on the servers that matches `text` and is not held here (older than the window),
    /// brought in as headers. Accounts that fail are left out; their error is recorded.
    public func searchServer(_ text: String, limit: Int = 50) async -> [MessageID] {
        await searchServer(ServerQuery(text: text), limit: limit)
    }

    public func searchServer(_ query: ServerQuery, limit: Int = 50) async -> [MessageID] {
        var found: [MessageID] = []
        for (id, syncer) in await currentSyncers() where found.count < limit {
            do {
                found += try await syncer.searchServer(query, limit: limit - found.count)
            } catch {
                record(id, error)
            }
        }
        return found
    }
}

/// What editing folders needs to know from the server.
extension SyncCoordinator {
    /// How many messages the server holds in the folder and its subfolders; nil when it can't be
    /// asked now (offline, or the server failed).
    public func serverMessageCount(inTreeOf folder: FolderID) async -> Int? {
        for account in (try? store.accounts()) ?? [] {
            guard let found = try? store.folders(account.id).first(where: { $0.id == folder }) else {
                continue
            }
            guard let syncer = await currentSyncers().first(where: { $0.0 == account.id })?.1 else {
                return nil
            }
            return try? await syncer.messageCount(inTreeOf: found)
        }
        return nil
    }

    /// Where the account's new top-level folders go (`INBOX.` on a server that keeps every folder
    /// under the Inbox), as its last folder sync found it (in this launch or an earlier one), else
    /// as the stored folders show it.
    public func folderPrefix(for account: AccountID) async -> String {
        if let syncer = await currentSyncers().first(where: { $0.0 == account })?.1,
           let found = await syncer.folderPrefix {
            return found
        }
        if let kept = (try? store.folderPrefix(account)) ?? nil {
            return kept
        }
        return AccountSyncer.storedPrefix((try? store.folders(account)) ?? [])
    }
}
