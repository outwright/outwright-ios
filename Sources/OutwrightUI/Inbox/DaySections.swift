// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
public import OutwrightModel
import Synchronization

/// The rows of one day, under its title.
public struct DaySection: Identifiable, Equatable, Sendable {
    public var id: Date
    public var title: String
    public var rows: [MessageRow]
}

/// Groups a list by day: Today, Yesterday, the weekday within a week, then the date.
public enum DaySections {
    public static func group(_ rows: [MessageRow], now: Date, calendar: Calendar) -> [DaySection] {
        var sections: [DaySection] = []
        for row in rows {
            let day = calendar.startOfDay(for: min(row.date, now))
            if let last = sections.indices.last, sections[last].id == day {
                sections[last].rows.append(row)
            } else {
                sections.append(DaySection(id: day, title: title(day, now: now, calendar: calendar), rows: [row]))
            }
        }
        return sections
    }

    static func daysBefore(_ date: Date, now: Date, calendar: Calendar) -> Int {
        let from = calendar.startOfDay(for: date)
        let to = calendar.startOfDay(for: now)
        return max(0, calendar.dateComponents([.day], from: from, to: to).day ?? 0)
    }

    static func title(_ day: Date, now: Date, calendar: Calendar) -> String {
        let locale = calendar.locale ?? .current
        switch daysBefore(day, now: now, calendar: calendar) {
        case 0: return L10n.string("Today", locale: locale)
        case 1: return L10n.string("Yesterday", locale: locale)
        case 2...6: return format(day, "EEEE", calendar: calendar)
        default:
            let sameYear = calendar.component(.year, from: day) == calendar.component(.year, from: now)
            return format(day, sameYear ? "EEEEdMMMM" : "dMMMMy", calendar: calendar)
        }
    }

    /// What a row shows at its right: the time today, the weekday within a week, else the date.
    public static func rowLabel(_ date: Date, now: Date, calendar: Calendar) -> String {
        switch daysBefore(date, now: now, calendar: calendar) {
        case 0: return format(date, "jmm", calendar: calendar)
        case 1: return L10n.string("Yesterday", locale: calendar.locale ?? .current)
        case 2...6: return format(date, "EEEE", calendar: calendar)
        default:
            let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
            return format(date, sameYear ? "dMMM" : "dMMMy", calendar: calendar)
        }
    }

    /// Formatters by template, calendar, locale and time zone: making one is slow, a list asks often.
    private static let formatters = Mutex<[String: DateFormatter]>([:])

    static func format(_ date: Date, _ template: String, calendar: Calendar) -> String {
        let locale = calendar.locale ?? .current
        let key = [template, "\(calendar.identifier)", locale.identifier, calendar.timeZone.identifier]
            .joined(separator: "|")
        return formatters.withLock { cache in
            if let formatter = cache[key] { return formatter.string(from: date) }
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.locale = locale
            formatter.timeZone = calendar.timeZone
            formatter.setLocalizedDateFormatFromTemplate(template)
            if cache.count > 64 { cache.removeAll() }
            cache[key] = formatter
            return formatter.string(from: date)
        }
    }
}
