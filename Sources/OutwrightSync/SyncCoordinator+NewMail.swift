// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
public import OutwrightModel

extension SyncCoordinator {
    /// After a background refresh: each account with local notices on, and not left to push,
    /// announces its new unread Inbox mail; with `focusedOnly` (Focused Inbox on) only its Focused
    /// mail, as Outlook does. While Do Not Disturb is active nothing is posted. An account the store
    /// cannot answer for is skipped.
    public func announceNewMail(
        skipping pushed: Set<AccountID>, focusedOnly: Bool, protectedBody: String = NewMailPlan.encryptedBody,
        doNotDisturb: DoNotDisturb = DoNotDisturbDefaults.load(), more: @Sendable (Int) -> String
    ) async {
        guard let ids = try? store.newMailNoticeAccounts(), !ids.isEmpty else { return }
        let accounts = (try? store.accounts()) ?? []
        for id in ids where !pushed.contains(id) {
            guard let claimed = try? store.claimNewInboxMail(id, now: now()) else { continue }
            let rows = focusedOnly ? claimed.filter { $0.inboxClass == .focused } : claimed
            // Under Do Not Disturb the mail is claimed all the same: it is not announced later.
            guard !rows.isEmpty, !doNotDisturb.isActive(at: now()) else { continue }
            let account = accounts.first { $0.id == id }
            let name = account.map { $0.displayName.isEmpty ? $0.email : $0.displayName } ?? ""
            await newMail.post(NewMailPlan.plan(rows, accountName: name, protectedBody: protectedBody, more: more))
        }
    }

    /// Keeps the app icon's number at the unread mail in every Inbox (only Focused when
    /// `focusedOnly`), until the task is cancelled. The notification extension counts the same way:
    /// `BadgeDefaults` tells it whether to count only Focused.
    public func showBadge(focusedOnly: Bool) async {
        BadgeDefaults.setFocusedOnly(focusedOnly)
        for await count in store.observeUnreadInboxCount(focusedOnly: focusedOnly) {
            await newMail.setBadge(count)
        }
    }
}
