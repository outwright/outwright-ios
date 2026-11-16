// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// The items of one FETCH response, by upper-cased name.
struct FetchItems {
    private(set) var items: [String: IMAPValue] = [:]

    init(_ values: [IMAPValue]) {
        guard case let .list(list)? = values.first else {
            return
        }
        var index = 0
        while index + 1 < list.count {
            if case let .atom(name) = list[index] {
                items[name.uppercased()] = list[index + 1]
            }
            index += 2
        }
    }

    mutating func merge(_ other: FetchItems) {
        items.merge(other.items) { _, new in new }
    }

    var uid: UInt32? { items["UID"]?.number }

    var flags: Set<String>? {
        guard case let .list(values)? = items["FLAGS"] else {
            return nil
        }
        return Set(values.compactMap { value in
            if case let .atom(flag) = value { flag } else { nil }
        })
    }

    /// The data of the first section whose name starts with `prefix`.
    func section(_ prefix: String) -> Data? {
        items.first { $0.key.hasPrefix(prefix) }?.value.data
    }

    func summary() -> MessageSummary? {
        guard let uid else {
            return nil
        }
        var flags: Set<String> = []
        if case let .list(values)? = items["FLAGS"] {
            flags = Set(values.compactMap { value in
                if case let .atom(flag) = value { flag } else { nil }
            })
        }
        let date = items["INTERNALDATE"]?.text.flatMap(InternalDate.parse) ?? Date()
        let size = items["RFC822.SIZE"]?.number.map(Int.init) ?? 0
        return MessageSummary(
            uid: uid,
            flags: flags,
            internalDate: date,
            size: size,
            headers: section("BODY[HEADER]") ?? Data(),
            partialText: section("BODY[TEXT]") ?? Data()
        )
    }
}

/// IMAP's dates: `06-Nov-2026 10:00:00 +0100` (INTERNALDATE) and `6-Nov-2026` (SEARCH).
enum InternalDate {
    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }

    static func parse(_ text: String) -> Date? {
        let parts = text.split(separator: " ")
        guard parts.count == 3 else {
            return nil
        }
        let day = parts[0].split(separator: "-")
        let time = parts[1].split(separator: ":")
        let zone = Array(parts[2].utf8)
        guard day.count == 3, time.count == 3, zone.count == 5,
              let dayNumber = Int(day[0]), let year = Int(day[2]),
              let month = months.firstIndex(of: day[1].lowercased()),
              let hour = Int(time[0]), let minute = Int(time[1]), let second = Int(time[2]),
              let zoneHours = Int(lossyText(zone[1...2])),
              let zoneMinutes = Int(lossyText(zone[3...4])),
              zone[0] == UInt8(ascii: "+") || zone[0] == UInt8(ascii: "-"),
              (1...31).contains(dayNumber), (0...9999).contains(year), (0...23).contains(hour),
              (0...59).contains(minute), (0...60).contains(second),
              (0...23).contains(zoneHours), (0...59).contains(zoneMinutes)
        else {
            return nil
        }
        let components = DateComponents(
            year: year, month: month + 1, day: dayNumber, hour: hour, minute: minute, second: second
        )
        guard let local = calendar.date(from: components) else {
            return nil
        }
        let offset = TimeInterval((zoneHours * 60 + zoneMinutes) * 60)
        return zone[0] == UInt8(ascii: "+") ? local - offset : local + offset
    }

    /// `d-Mon-yyyy` of `date` in UTC, as SEARCH SINCE takes it.
    static func searchDate(_ date: Date) -> String {
        let parts = calendar.dateComponents([.era, .year, .month, .day], from: date)
        // Before the common era there is nothing to search for: the first day of year 1 will do.
        guard parts.era != 0, let year = parts.year, let day = parts.day, let number = parts.month,
              months.indices.contains(number - 1)
        else {
            return "1-Jan-0001"
        }
        let month = months[number - 1]
        let digits = String(min(max(year, 1), 9999)).leftPadded(to: 4)
        return "\(day)-\(month.prefix(1).uppercased() + month.dropFirst())-\(digits)"
    }
}
