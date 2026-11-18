// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightModel

/// The owner's own colour for a calendar, kept on the phone (`SettingsKeys.calendarColors`, by the
/// calendar's id) over the colour the server or the palette gives it.
enum CalendarColors {
    /// Every colour chosen, by calendar.
    static func chosen(_ defaults: UserDefaults) -> [CalendarID: Int] {
        guard let stored = defaults.dictionary(forKey: SettingsKeys.calendarColors) else { return [:] }
        var result: [CalendarID: Int] = [:]
        for (key, value) in stored {
            guard let raw = Int64(key), let color = value as? Int else { continue }
            result[CalendarID(raw: raw)] = color & 0xFF_FFFF
        }
        return result
    }

    /// Chooses the calendar's colour; nil goes back to its own.
    static func choose(_ color: Int?, for id: CalendarID, in defaults: UserDefaults) {
        var stored = defaults.dictionary(forKey: SettingsKeys.calendarColors) ?? [:]
        stored[String(id.raw)] = color.map { $0 & 0xFF_FFFF }
        if stored.isEmpty {
            defaults.removeObject(forKey: SettingsKeys.calendarColors)
        } else {
            defaults.set(stored, forKey: SettingsKeys.calendarColors)
        }
    }

    /// The calendar with the colour the owner chose for it, if any.
    static func applied(_ calendar: CalendarInfo, _ chosen: [CalendarID: Int]) -> CalendarInfo {
        var calendar = calendar
        if let color = chosen[calendar.id] { calendar.color = color }
        return calendar
    }
}

extension CalendarModel {
    /// The owner's own colour for a calendar, kept on the phone; nil goes back to the calendar's.
    func setColor(_ color: Int?, of id: CalendarID) {
        CalendarColors.choose(color, for: id, in: defaults)
        reload()
    }
}
