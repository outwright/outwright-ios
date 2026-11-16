// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightMIME
import OutwrightModel
import OutwrightStore

/// A message's body with what the intake needs alongside it.
struct FetchedBody {
    let row: MessageRow
    let data: Data
    let folder: Folder
    /// The message as opened when it was stored, so it is not opened twice; nil: open it from `data`.
    var opened: OpenedMessage?
}

/// Invitations in fetched mail, handed to the intake.
extension AccountSyncer {
    /// The account's held invitations not yet taken (an intake that failed, or one waiting for the
    /// account's calendars) go to the intake again, oldest first so a cancellation follows what it
    /// cancels: after a calendar sync. At most `limit`. Without `waitingForCalendars` (after a move),
    /// only those with no record: one moved out of Junk.
    public func retakeInvitations(limit: Int = 100, waitingForCalendars: Bool = true) async {
        _ = try? await exclusive { () async throws(SyncError) in
            let ids = try stored {
                try store.invitationsAwaitingIntake(
                    account.id, limit: limit, waitingForCalendars: waitingForCalendars)
            }
            guard !ids.isEmpty else {
                return
            }
            let folders = try stored { try store.folders(account.id) }
            var bodies: [FetchedBody] = []
            for id in ids {
                guard let row = try stored({ try store.message(id) }),
                    let folder = folders.first(where: { $0.id == row.folderID }),
                    let data = try stored({ try store.body(id) })
                else { continue }
                bodies.append(FetchedBody(row: row, data: data, folder: folder))
            }
            takeInvitations(bodies)
        }
    }

    /// The bodies go to the intake oldest first (by the message's date, then its UID), whatever
    /// order they were fetched in: an update or a cancellation follows the invitation it changes.
    func takeInvitations(_ bodies: [FetchedBody]) {
        let ordered = bodies.sorted { ($0.row.date, $0.row.uid) < ($1.row.date, $1.row.uid) }
        for body in ordered {
            takeInvitation(body.row, body.data, body.folder, opened: body.opened)
        }
    }

    /// A body with a calendar part goes to the intake, with the account as stored now (its CalDAV
    /// may have been turned off since this syncer was made). The body is kept whatever the intake
    /// does: one that fails records nothing and is taken again when the message is next fetched for
    /// (opened, or among the Inbox's prefetched). A message marked as an invitation whose body does
    /// not read is kept as unreadable, so it is not read again.
    private func takeInvitation(_ row: MessageRow, _ data: Data, _ folder: Folder, opened: OpenedMessage?) {
        guard let parsed = (opened ?? store.open(data))?.message else {
            if row.isInvitation {
                try? store.recordUnreadableInvitation(row.id)
            }
            return
        }
        guard parsed.calendar != nil else {
            return
        }
        let current = ((try? store.accounts()) ?? []).first { $0.id == account.id } ?? account
        let (today, zone) = (now(), phoneZone())
        _ = try? InvitationIntake.process(
            row, parsed: parsed, account: current, folder: folder, store: store,
            window: CalendarWindow.window(now: today, zone: zone), phoneZone: zone, now: today)
    }
}
