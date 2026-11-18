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

    @Test func aReminderIsQuietOnlyWhenDoNotDisturbCoversItsFireTime() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let reminder = PlannedReminder(
            identifier: "outwright.event.x.1", fire: now.addingTimeInterval(1_800), title: "T", body: "B",
            event: EventID(raw: 1), occurrence: nil)
        func content(_ dnd: DoNotDisturb) -> UNNotificationContent {
            SystemReminders.request(reminder, now: now, doNotDisturb: dnd).content
        }
        let covering = content(DoNotDisturb(until: now.addingTimeInterval(3_600)))
        #expect(covering.interruptionLevel == .passive)
        #expect(covering.sound == nil)
        let endsFirst = content(DoNotDisturb(until: now.addingTimeInterval(600)))
        #expect(endsFirst.interruptionLevel == .active)
        #expect(endsFirst.sound != nil)
        let off = content(DoNotDisturb())
        #expect(off.interruptionLevel == .active)
        #expect(off.sound != nil)
    }

    /// A reminder handed over before Do Not Disturb went on is quieted when the set is planned again
    /// while it is on, and gets its sound back when the set is planned after it ended.
    @Test func aReplanFollowsDoNotDisturb() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let reminder = PlannedReminder(
            identifier: "outwright.event.x.1", fire: now.addingTimeInterval(1_800), title: "T", body: "B",
            event: EventID(raw: 1), occurrence: nil)
        let quiet = DoNotDisturb(until: now.addingTimeInterval(3_600))
        let planned = SystemReminders.request(reminder, now: now)
        #expect(SystemReminders.same(planned, reminder, now: now, doNotDisturb: DoNotDisturb()))
        #expect(!SystemReminders.same(planned, reminder, now: now, doNotDisturb: quiet))
        let quieted = SystemReminders.request(reminder, now: now, doNotDisturb: quiet)
        #expect(quieted.content.interruptionLevel == .passive)
        #expect(SystemReminders.same(quieted, reminder, now: now, doNotDisturb: quiet))
        #expect(!SystemReminders.same(quieted, reminder, now: now, doNotDisturb: DoNotDisturb()))
        #expect(SystemReminders.request(reminder, now: now).content.sound != nil)
    }
}
