// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import OutwrightModel

extension AccountSyncer {
    /// Sends the queued changes, then brings the folder's last 90 days in step with the server.
    /// New mail comes in batches, each a turn of its own, so opening a message (a body fetch)
    /// waits for one batch at most and not for the whole folder. A cancelled task fetches no
    /// further batch; the next sync brings in the rest.
    public func sync(_ folder: FolderID) async throws(SyncError) {
        try await bringIn(folder, sendingQueue: true)
    }

    /// A push's update: the Inbox's mail as `sync` brings it in (the folder list first when the
    /// store has none), without sending the queued changes and without the invitations' intake,
    /// both left to the app.
    public func fetchInbox() async throws(SyncError) {
        try await bringIn(try await inboxFolder().id, sendingQueue: false)
    }

    private func bringIn(_ folder: FolderID, sendingQueue: Bool) async throws(SyncError) {
        keepsQueuedFlags = !sendingQueue
        defer { keepsQueuedFlags = false }
        let (refusal, first) = try await exclusive { () async throws(SyncError) in
            try await withMain { client async throws(SyncError) in
                let refusal = sendingQueue ? try await runQueue(client) : nil
                return (refusal, try await syncMessages(folder, client))
            }
        }
        var next = first
        while let fetch = next, !Task.isCancelled {
            next = try await exclusive { () async throws(SyncError) in
                try await withMain { client async throws(SyncError) in
                    try await fetchBatch(fetch, client)
                }
            }
        }
        guard sendingQueue else { return }
        await takeNewInvitations(folder)
        if let refusal {
            throw refusal
        }
    }
}
