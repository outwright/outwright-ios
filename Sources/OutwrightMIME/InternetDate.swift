// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// RFC 5322 dates, read and written without locale or calendar objects.
enum InternetDate {
    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
    private static let weekdays = ["Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed"]
    private static let monthNames = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"
    ]
    private static let zones: [String: Int] = [
        "ut": 0, "utc": 0, "gmt": 0, "z": 0, "est": -5, "edt": -4, "cst": -6, "cdt": -5,
        "mst": -7, "mdt": -6, "pst": -8, "pdt": -7
    ]

    static func parse(_ input: String) -> Date? {
        var tokens = input.split { $0 == " " || $0 == "," || $0 == "\t" }.map(String.init)
        tokens.removeAll { $0.hasPrefix("(") }
        if let first = tokens.first, Int(first) == nil { tokens.removeFirst() }
        guard tokens.count >= 4, let day = Int(tokens[0]), let year = year(tokens[2]),
              let month = months.firstIndex(of: String(tokens[1].lowercased().prefix(3))),
              let seconds = time(tokens[3]), (1...31).contains(day), year >= 1900 else { return nil }
        let zoneSeconds = tokens.count > 4 ? zone(tokens[4]) : 0
        let days = daysFromCivil(year: year, month: month + 1, day: day)
        return Date(timeIntervalSince1970: Double(days * 86_400 + seconds - zoneSeconds))
    }

    private static func year(_ token: String) -> Int? {
        guard let value = Int(token), (0...9_999).contains(value) else { return nil }
        if token.count <= 2 { return value < 50 ? 2_000 + value : 1_900 + value }
        return token.count == 3 ? 1_900 + value : value
    }

    private static func time(_ token: String) -> Int? {
        let parts = token.split(separator: ":").map { Int($0) }
        guard parts.count == 2 || parts.count == 3, let hour = parts[0], let minute = parts[1] else { return nil }
        let second = parts.count == 3 ? parts[2] : 0
        guard let second, (0...23).contains(hour), (0...59).contains(minute), (0...60).contains(second) else {
            return nil
        }
        return hour * 3_600 + minute * 60 + second
    }

    private static func zone(_ token: String) -> Int {
        if let hours = zones[token.lowercased()] { return hours * 3_600 }
        guard token.count == 5, let sign = token.first, sign == "+" || sign == "-",
              let hours = Int(token.dropFirst().prefix(2)), let minutes = Int(token.suffix(2)),
              hours < 24, minutes < 60 else { return 0 }
        let total = hours * 3_600 + minutes * 60
        return sign == "-" ? -total : total
    }

    /// Days since 1970-01-01 for a proleptic Gregorian date.
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let shifted = month <= 2 ? year - 1 : year
        let era = shifted / 400
        let yearOfEra = shifted - era * 400
        let monthIndex = (month + 9) % 12
        let dayOfYear = (153 * monthIndex + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    private struct Civil {
        var year: Int
        var month: Int
        var day: Int
    }

    private static func civilFromDays(_ days: Int) -> Civil {
        let shifted = days + 719_468
        let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
        let dayOfEra = shifted - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthIndex = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthIndex + 2) / 5 + 1
        let month = monthIndex < 10 ? monthIndex + 3 : monthIndex - 9
        return Civil(year: yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month: month, day: day)
    }

    /// "Fri, 06 Nov 2026 10:00:00 +0000"
    static func format(_ date: Date) -> String {
        let raw = date.timeIntervalSince1970
        // RFC 5322 years run from 1900 to 9999.
        let clamped = raw.isFinite ? min(max(raw.rounded(.down), -2_208_988_800), 253_402_300_799) : 0
        let total = Int(clamped)
        // Whole days and the seconds into the last one, also for a date before 1970.
        let rest = (total % 86_400 + 86_400) % 86_400
        let days = (total - rest) / 86_400
        let civil = civilFromDays(days)
        let weekday = weekdays[(days % 7 + 7) % 7]
        let monthName = monthNames[(civil.month - 1 + 12) % 12]
        return "\(weekday), \(pad(civil.day)) \(monthName) \(civil.year) "
            + "\(pad(rest / 3_600)):\(pad(rest % 3_600 / 60)):\(pad(rest % 60)) +0000"
    }

    private static func pad(_ value: Int) -> String { value < 10 ? "0\(value)" : "\(value)" }
}
