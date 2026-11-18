// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// The view and the week stored while the calendar is open, as a restored setup writes them.
extension CalendarModel {
    /// The view and the week last chosen, as the model starts; a launch argument's view goes before
    /// the stored one, and is not kept.
    func readStoredSettings() {
        lastStoredMode = defaults.string(forKey: SettingsKeys.calendarMode)
        lastStoredWeek = defaults.string(forKey: SettingsKeys.calendarWeekMode)
        let stored = lastStoredMode.flatMap(CalendarMode.init(rawValue:))
        modeChosen = stored != nil
        applyingDefault = true
        mode = app.initialCalendarMode ?? stored ?? .threeDay
        applyingDefault = false
        weekMode = lastStoredWeek.flatMap(WeekMode.init(rawValue:)) ?? .week
    }

    /// Follows the view and the week stored while the model lives (a restored setup), until the task
    /// is cancelled. What changed while it was not watching is followed first.
    public func observeSettings() async {
        followStoredSettings()
        // Any defaults' change, not only these (UserDefaults is not Sendable to name as the object):
        // reading the two values again when they did not change does nothing.
        let changes = NotificationCenter.default
            .notifications(named: UserDefaults.didChangeNotification).map { _ in () }
        for await _ in changes {
            followStoredSettings()
        }
    }

    /// The stored view and week, when they differ from what was last read, become the ones shown. A
    /// launch argument's view stays while the stored view is the one it was chosen over.
    func followStoredSettings() {
        let storedMode = defaults.string(forKey: SettingsKeys.calendarMode)
        if storedMode != lastStoredMode {
            lastStoredMode = storedMode
            if let chosen = storedMode.flatMap(CalendarMode.init(rawValue:)) {
                // Chosen even when it is the view shown: the wide screen's default no longer applies.
                modeChosen = true
                if chosen != mode {
                    applyingDefault = true
                    mode = chosen
                    applyingDefault = false
                }
            }
        }
        let storedWeek = defaults.string(forKey: SettingsKeys.calendarWeekMode)
        if storedWeek != lastStoredWeek {
            lastStoredWeek = storedWeek
            if let chosen = storedWeek.flatMap(WeekMode.init(rawValue:)), chosen != weekMode {
                weekMode = chosen
            }
        }
    }
}
