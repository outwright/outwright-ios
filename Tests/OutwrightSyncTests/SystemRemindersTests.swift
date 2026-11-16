// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightModel
@testable import OutwrightSync
import Testing
import UserNotifications

/// The phone's notification fires the time from the app's clock to the reminder, so a clock that
/// runs ahead of the phone's brings a reminder as much sooner.
@Suite struct SystemRemindersTests {
    @Test func theTriggerCountsFromTheAppsClock() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let reminder = PlannedReminder(
            identifier: "outwright.event.x.1", fire: now.addingTimeInterval(5), title: "T", body: "B",
            event: EventID(raw: 1), occurrence: nil)
        let request = SystemReminders.request(reminder, now: now)
        let trigger = try #require(request.trigger as? UNTimeIntervalNotificationTrigger)
        #expect(abs(trigger.timeInterval - 5) < 0.001)
    }

    @Test func aReminderAlreadyDueFiresInASecond() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let reminder = PlannedReminder(
            identifier: "outwright.event.x.1", fire: now.addingTimeInterval(-30), title: "T", body: "B",
            event: EventID(raw: 1), occurrence: nil)
        let trigger = try #require(SystemReminders.request(reminder, now: now).trigger as? UNTimeIntervalNotificationTrigger)
        #expect(trigger.timeInterval == 1)
    }
}
