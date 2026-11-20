// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightModel
import OutwrightStore

/// A moved message's row, once the server has taken the move.
extension ActionRunner {
    func settle(_ id: MessageID, movedTo destination: Folder, newUID: UInt32?, by pending: PendingAction)
        throws(SyncError) {
        // Settle only a row still waiting in that folder from this move: a move queued since
        // takes it on (it may be back in this folder on a later visit, with a number of its
        // own). The changes queued in the folder learn the number this move gave it.
        // Read from the store: a move queued while this run was under way counts too.
        let movedSince = try stored { try store.pendingActions() }.contains { later in
            guard later.id > pending.id, later.action.target == id else { return false }
            switch later.action {
            case .move, .moveTo, .delete: return true
            default: return false
            }
        }
        if !movedSince, let row = try stored({ try store.message(id) }), row.folderID == destination.id,
           row.uid == 0 {
            try stored { try store.settleMove(id, newUID: newUID) }
        } else if let newUID {
            try stored { try store.carryUID(newUID, of: id, in: destination.id, after: pending.id) }
        }
    }

    /// The message's uid in `destination` when it is already there (a move whose answer was lost);
    /// nil when it isn't, can't be told (no Message-ID), or the server has no such folder.
    mutating func alreadyIn(_ destination: Folder, header: String?) async throws(SyncError) -> UInt32? {
        guard let header, !header.isEmpty else { return nil }
        do {
            if case let .found(_, uid) = try await search(header, in: destination) { return uid }
        } catch {
            if error.breaksConnection { throw error }
            selected = nil
        }
        return nil
    }
}
