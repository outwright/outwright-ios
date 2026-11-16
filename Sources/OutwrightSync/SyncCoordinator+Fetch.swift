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
