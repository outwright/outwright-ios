// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightModel

extension SyncCoordinator {
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
