// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightIMAP
import OutwrightModel

/// Bringing a folder's flags in step by mod-sequence (RFC 7162): QRESYNC, CONDSTORE alone, or
/// the full reconcile where neither can be trusted.
extension AccountSyncer {
    /// What a folder's SELECT said, beside what was remembered of it.
    struct Resync {
        /// The HIGHESTMODSEQ saved by the last reconcile written; nil when there is none to trust.
        var remembered: UInt64?
        /// Whether the SELECT carried a QRESYNC point.
        var asked: Bool
        var status: FolderStatus
        var changes: ResyncChanges
    }

    /// The point to ask a QRESYNC SELECT from: the folder's UIDVALIDITY and remembered modseq, and
    /// the span of uids held. Nil for a folder never selected, with no modseq remembered, or with
    /// nothing held (without a span the server would answer for the whole folder, for nothing).
    func resyncPoint(_ folder: Folder, remembered: UInt64?, held: [UInt32: MessageID]) -> QResyncPoint? {
        guard folder.uidValidity != 0, let remembered, let span = Self.span(held) else {
            return nil
        }
        return QResyncPoint(uidValidity: folder.uidValidity, modSeq: remembered, known: span)
    }

    /// The lowest to the highest uid held; nil when nothing is.
    static func span(_ held: [UInt32: MessageID]) -> ClosedRange<UInt32>? {
        held.keys.min().flatMap { low in held.keys.max().map { low...$0 } }
    }

    /// Brings the held messages in step and then remembers the SELECT's HIGHESTMODSEQ. Any
    /// failure forgets the remembered one, so the next sync reconciles in full rather than asking
    /// again from a point whose answer failed.
    func reconcile(
        _ folder: FolderID, _ local: [UInt32: MessageID], _ client: IMAPClient, _ since: Resync
    ) async throws(SyncError) {
        do {
            try await reconcileChanges(folder, local, client, since)
            try stored { try store.setHighestModSeq(folder, since.status.highestModSeq) }
        } catch {
            try? store.setHighestModSeq(folder, nil)
            throw error
        }
    }

    private func reconcileChanges(
        _ folder: FolderID, _ local: [UInt32: MessageID], _ client: IMAPClient, _ since: Resync
    ) async throws(SyncError) {
        // A modseq that went back (a server restored from a backup) says nothing about what
        // changed since ours: only the full reconcile can be trusted then.
        guard let remembered = since.remembered, let current = since.status.highestModSeq,
              current >= remembered
        else {
            try await fullReconcile(folder, local, client)
            return
        }
        switch await client.resyncMode {
        case .qresync where since.asked:
            guard current != remembered else {
                return
            }
            try removeVanished(since.changes.vanished, held: local, folder: folder)
            try applyFlags(since.changes.flags, held: local, folder: folder)
        case .condstore:
            if current != remembered {
                let span = Self.span(local)
                let changed = try await imap { try await client.changedFlags(since: remembered, within: span) }
                try applyFlags(changed, held: local, folder: folder)
            }
            // Under CONDSTORE alone an expunge need not raise HIGHESTMODSEQ: ask which are left.
            guard !local.isEmpty else {
                return
            }
            let present = try await imap { try await client.presentUIDs(Array(local.keys)) }
            let gone = local.keys.filter { !present.contains($0) }
            if !gone.isEmpty {
                try stored { try store.removeMessages(folder: folder, uids: gone) }
            }
        default:
            try await fullReconcile(folder, local, client)
        }
    }

    /// The held messages among `ranges` go.
    func removeVanished(
        _ ranges: [ClosedRange<UInt32>], held: [UInt32: MessageID], folder: FolderID
    ) throws(SyncError) {
        let gone = held.keys.filter { uid in ranges.contains { $0.contains(uid) } }
        if !gone.isEmpty {
            try stored { try store.removeMessages(folder: folder, uids: gone) }
        }
    }

    /// The server's flags for held messages: `\Deleted` ones go, the others take read and flagged
    /// from it; in a push's fetch (`keepsQueuedFlags`) not those with a change of the owner's still
    /// queued, which the server has not heard of yet. Uids not held are ignored.
    func applyFlags(
        _ flags: [UInt32: Set<String>], held: [UInt32: MessageID], folder: FolderID
    ) throws(SyncError) {
        let deleted = flags.compactMap { uid, set in set.contains("\\Deleted") && held[uid] != nil ? uid : nil }
        if !deleted.isEmpty {
            try stored { try store.removeMessages(folder: folder, uids: deleted) }
        }
        let queued = keepsQueuedFlags ? Set(try stored { try store.pendingActions() }.map(\.action.target)) : []
        for (uid, set) in flags where !set.contains("\\Deleted") {
            guard let id = held[uid], !queued.contains(id), let row = try stored({ try store.message(id) }) else {
                continue
            }
            let read = set.contains("\\Seen")
            let flagged = set.contains("\\Flagged")
            if row.isRead != read || row.isFlagged != flagged {
                try stored { try store.updateFlags(id, isRead: read, isFlagged: flagged) }
            }
        }
    }
}
