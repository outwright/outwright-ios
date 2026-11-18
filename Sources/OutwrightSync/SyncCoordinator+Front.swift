// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightModel

extension SyncCoordinator {
    /// Watches the account's Inbox (IDLE) until cancelled, syncing it first and again after each failure.
    func watch(_ id: AccountID, _ syncer: AccountSyncer) async {
        var delay = backoff.lowerBound
        var needsSync = true
        while !Task.isCancelled {
            do {
                if needsSync {
                    defer { inboxFetched.insert(id) }
                    try await syncer.syncInbox()
                    needsSync = false
                    // The server answered: an earlier failure is over now, not when the IDLE ends.
                    record(id, nil)
                    journalSync(id, .mail, nil)
                }
                if try await syncer.idleInbox() {
                    try await syncer.syncInbox()
                } else {
                    // The IDLE ran its time: what was queued meanwhile goes before the next one.
                    try await syncer.runActions()
                }
                delay = backoff.lowerBound
                record(id, nil)
            } catch {
                guard !Task.isCancelled else {
                    break
                }
                record(id, error)
                journalSync(id, .mail, error)
                needsSync = true
                try? await Task.sleep(for: delay)
                delay = min(delay * 2, backoff.upperBound)
            }
        }
    }

    /// The accounts' contacts and calendars, all at once, each failure recorded; then the reminders.
    func refreshContactsAndCalendars(_ accounts: [AccountID]) async {
        await withTaskGroup(of: Void.self) { group in
            for id in accounts {
                group.addTask {
                    if let error = await self.refreshContacts(id) {
                        await self.record(id, error)
                    }
                    if let error = await self.refreshCalendars(id) {
                        await self.record(id, error)
                    }
                }
            }
        }
        if !Task.isCancelled {
            await rescheduleReminders()
        }
    }
}
