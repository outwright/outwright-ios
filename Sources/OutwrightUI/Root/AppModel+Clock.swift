// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/// The phone's clock moved: the calendar is laid out again.
extension AppModel {
    /// The phone moved to another time zone: the events are laid out again for it.
    public func phoneZoneChanged() async {
        await sync.phoneZoneChanged()
        clockChanges &+= 1
    }

    /// Midnight passed: the events are laid out for the new day's window.
    public func dayChanged() async {
        await sync.dayChanged()
        clockChanges &+= 1
    }
}
