// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightModel
import OutwrightStore

/// The queued changes a folder made here and refused by the server leaves behind.
extension ActionRunner {
    /// Gives up every delete still queued in this run that would take `folder`, restoring it.
    mutating func giveUpDeletes(of folder: FolderID) throws(SyncError) {
        for pending in queue where !folderRun.settled.contains(pending.id) {
            guard case let .deleteFolder(_, paths) = pending.action, paths.contains(where: { $0.id == folder })
            else { continue }
            _ = try refuse(pending, gaveUp: true)
            folderRun.settled.insert(pending.id)
        }
    }

    /// After an undone create, the queued changes the store repointed (or dropped) are taken as
    /// the store has them now.
    mutating func repoint(after refused: PendingAction) throws(SyncError) {
        guard let index = queue.firstIndex(where: { $0.id == refused.id }) else { return }
        let current = Dictionary(try stored { try store.pendingActions() }.map { ($0.id, $0) }) { first, _ in first }
        for pending in queue[queue.index(after: index)...] where !folderRun.settled.contains(pending.id) {
            guard let now = current[pending.id] else {
                folderRun.settled.insert(pending.id)
                continue
            }
            if now.sourceFolderID != pending.sourceFolderID || now.sourceUID != pending.sourceUID {
                folderRun.repointed[pending.id] = now
            }
        }
    }
}
