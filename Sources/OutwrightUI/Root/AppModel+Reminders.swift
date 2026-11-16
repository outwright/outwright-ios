// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightModel
import OutwrightStore

extension AppModel {
    /// The Calendar tab was opened: the first time an account has a calendar of its own (a subscribed
    /// one rings nothing), the owner is asked whether reminders may be shown (iOS asks only once; later
    /// answers are the first), and they are planned.
    public func calendarTabOpened() async {
        let own = ((try? store.allCalendars()) ?? []).filter { $0.accountID != nil }
        guard !remindersAsked, !own.isEmpty else { return }
        remindersAsked = true
        if await sync.reminders.requestAuthorization() {
            await sync.rescheduleReminders()
        }
    }
}
