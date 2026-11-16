// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// Proleptic Gregorian arithmetic on day numbers (days since 1970-01-01), years 1...9999.
enum Civil {
    static let years = 1...9999
    static let secondsPerDay = 86_400

    static func isLeap(_ year: Int) -> Bool { year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) }

    static func daysInMonth(_ year: Int, _ month: Int) -> Int {
        switch month {
        case 2: isLeap(year) ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }

    static func daysInYear(_ year: Int) -> Int { isLeap(year) ? 366 : 365 }

    /// Day number of a valid date (the caller checks the ranges).
    static func dayNumber(_ year: Int, _ month: Int, _ day: Int) -> Int {
        let shifted = month <= 2 ? year - 1 : year
        let era = floorDiv(shifted, 400)
        let yearOfEra = shifted - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    static func date(_ number: Int) -> CivilDate {
        let shifted = number + 719_468
        let era = floorDiv(shifted, 146_097)
        let dayOfEra = shifted - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthIndex = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthIndex + 2) / 5 + 1
        let month = monthIndex < 10 ? monthIndex + 3 : monthIndex - 9
        let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
        return CivilDate(year: year, month: month, day: day, number: number)
    }

    /// ISO weekday, 1 = Monday ... 7 = Sunday.
    static func weekday(_ number: Int) -> Int { floorMod(number + 3, 7) + 1 }

    static func floorDiv(_ lhs: Int, _ rhs: Int) -> Int {
        let quotient = lhs / rhs
        return (lhs % rhs != 0 && (lhs < 0) != (rhs < 0)) ? quotient - 1 : quotient
    }

    static func floorMod(_ lhs: Int, _ rhs: Int) -> Int { lhs - floorDiv(lhs, rhs) * rhs }
}

struct CivilDate: Hashable, Sendable {
    let year: Int
    let month: Int
    let day: Int
    let number: Int

    var weekday: Int { Civil.weekday(number) }
    var dayOfYear: Int { number - Civil.dayNumber(year, 1, 1) + 1 }
    var yyyymmdd: Int { year * 10_000 + month * 100 + day }
}

/// A wall-clock time, kept as seconds since 1970-01-01T00:00 as if it were UTC.
struct WallTime: Hashable, Comparable, Sendable {
    let seconds: Int

    init(seconds: Int) { self.seconds = seconds }

    init?(year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0, second: Int = 0) {
        guard Civil.years.contains(year), (1...12).contains(month),
              (1...Civil.daysInMonth(year, month)).contains(day),
              (0...23).contains(hour), (0...59).contains(minute), (0...60).contains(second)
        else { return nil }
        let day = Civil.dayNumber(year, month, day)
        seconds = day * Civil.secondsPerDay + hour * 3_600 + minute * 60 + min(second, 59)
    }

    init?(_ components: DateComponents) {
        guard let year = components.year, let month = components.month, let day = components.day else { return nil }
        self.init(year: year, month: month, day: day, hour: components.hour ?? 0,
                  minute: components.minute ?? 0, second: components.second ?? 0)
    }

    /// The wall time `offset` seconds east of UTC at an instant, when the instant lies in years 1...9999.
    init?(instant: Date, offset: Int) {
        let interval = instant.timeIntervalSince1970.rounded(.down)
        guard interval.isFinite, abs(interval) < 300_000_000_000, let whole = Int(exactly: interval) else { return nil }
        let local = whole + offset
        guard Civil.years.contains(Civil.date(Civil.floorDiv(local, Civil.secondsPerDay)).year) else { return nil }
        seconds = local
    }

    var dayNumber: Int { Civil.floorDiv(seconds, Civil.secondsPerDay) }
    var secondOfDay: Int { Civil.floorMod(seconds, Civil.secondsPerDay) }
    var date: CivilDate { Civil.date(dayNumber) }
    var hour: Int { secondOfDay / 3_600 }
    var minute: Int { secondOfDay % 3_600 / 60 }
    var second: Int { secondOfDay % 60 }

    var components: DateComponents {
        let date = date
        return DateComponents(year: date.year, month: date.month, day: date.day, hour: hour, minute: minute,
                              second: second)
    }

    func adding(seconds delta: Int) -> WallTime { WallTime(seconds: seconds + delta) }

    static func < (lhs: WallTime, rhs: WallTime) -> Bool { lhs.seconds < rhs.seconds }
}
