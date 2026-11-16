// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightModel

/// An event's time, zone, reminder and repeat as text, in the phone's language, calendar and zone.
enum EventText {
    /// The day (or days) and the hours: "All day" for an all-day event.
    static func time(_ occurrence: Occurrence, in phone: Calendar) -> String {
        let long = style(phone, date: .complete, time: .omitted)
        let short = style(phone, date: .abbreviated, time: .omitted)
        let clock = style(phone, date: .omitted, time: .shortened)
        let allDay = L10n.string("All day", locale: phone.locale ?? .current)
        if let first = occurrence.allDayStart, let start = day(first, phone) {
            let last = occurrence.allDayEnd.flatMap { day($0, phone) }
                .flatMap { phone.date(byAdding: .day, value: -1, to: $0) } ?? start
            guard last > start else { return long.format(start) + "\n" + allDay }
            return short.format(start) + " – " + short.format(last) + "\n" + allDay
        }
        let start = occurrence.start
        let end = max(occurrence.end, start)
        let endsSameDay = phone.isDate(start, inSameDayAs: end)
            || phone.date(byAdding: .day, value: 1, to: phone.startOfDay(for: start)) == end
        if endsSameDay {
            return long.format(start) + "\n" + clock.format(start) + "–" + clock.format(end)
        }
        let both = style(phone, date: .abbreviated, time: .shortened)
        return both.format(start) + " – " + both.format(end)
    }

    /// What VoiceOver says for an event: its title, its hours (or All day), and Tentative or Cancelled.
    static func spoken(_ event: CalendarEvent, in phone: Calendar) -> String {
        let occurrence = event.occurrence
        let details = occurrence.details
        let locale = phone.locale ?? .current
        var parts = [details.title.isEmpty ? L10n.string("(No title)", locale: locale) : details.title]
        if occurrence.allDayStart != nil {
            parts.append(L10n.string("All day", locale: locale))
        } else {
            let sameDay = phone.isDate(occurrence.start, inSameDayAs: occurrence.end)
            let clock = style(phone, date: sameDay ? .omitted : .abbreviated, time: .shortened)
            parts.append(String(
                format: L10n.string("%@ to %@", locale: locale), locale: locale, clock.format(occurrence.start),
                clock.format(max(occurrence.end, occurrence.start))))
        }
        if details.status == .cancelled {
            parts.append(L10n.string("Cancelled", locale: locale))
        } else if event.isTentative {
            parts.append(L10n.string("Tentative", locale: locale))
        }
        return parts.joined(separator: ", ")
    }

    /// "15:00–16:00 (Eastern Time)": the hours in the event's own zone, when its clock differs from the
    /// phone's at the event's start; nil otherwise, and for floating or UTC times.
    static func zoneNote(_ occurrence: Occurrence, zones: [String: ZoneRules], phone: Calendar) -> String? {
        guard case let .zoned(wall, tzid) = occurrence.details.start else { return nil }
        let locale = phone.locale ?? .current
        let zone: TimeZone
        let name: String
        switch ZoneResolver.resolve(tzid: tzid, given: zones) {
        case let .iana(id):
            guard let found = TimeZone(identifier: id) else { return nil }
            zone = found
            name = found.localizedName(for: .generic, locale: locale) ?? id
        case .rules:
            guard let found = ruleZone(occurrence.details.start, wall: wall, zones: zones, phone: phone.timeZone)
            else { return nil }
            zone = found
            name = String(tzid.prefix(64))
        case .floating:
            return nil
        }
        let start = occurrence.start
        guard zone.secondsFromGMT(for: start) != phone.timeZone.secondsFromGMT(for: start) else { return nil }
        var there = phone
        there.timeZone = zone
        let sameDay = there.component(.day, from: start) == phone.component(.day, from: start)
        let clock = style(there, date: sameDay ? .omitted : .abbreviated, time: .shortened)
        let end = style(there, date: .omitted, time: .shortened).format(max(occurrence.end, start))
        return clock.format(start) + "–" + end + " (" + name + ")"
    }

    /// A fixed-offset zone for a time read through its VTIMEZONE: the offset its start was read at.
    private static func ruleZone(
        _ time: EventTime, wall: DateComponents, zones: [String: ZoneRules], phone: TimeZone
    ) -> TimeZone? {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        var plain = wall
        plain.timeZone = nil
        plain.calendar = nil
        guard let instant = time.instant(in: phone, zones: zones), let asUTC = utc.date(from: plain) else {
            return nil
        }
        let offset = asUTC.timeIntervalSince(instant)
        guard abs(offset) <= 18 * 3_600, let seconds = Int(exactly: offset.rounded()) else { return nil }
        return TimeZone(secondsFromGMT: seconds)
    }

    /// "15 minutes before", "1 hour before", "At the start".
    static func reminder(_ minutes: Int, locale: Locale) -> String {
        let minutes = max(minutes, 0)
        if minutes == 0 { return L10n.string("At the start", locale: locale) }
        if minutes % 1_440 == 0 { return plural("%lld days before", minutes / 1_440, locale) }
        if minutes % 60 == 0 { return plural("%lld hours before", minutes / 60, locale) }
        return plural("%lld minutes before", minutes, locale)
    }

    /// "Every week · Monday, Wednesday", "Every 2 months", with "until …" when the rule ends on a date.
    static func repeats(_ rule: RecurrenceRule?, calendar phone: Calendar) -> String {
        let locale = phone.locale ?? .current
        guard let rule else { return L10n.string("On several dates", locale: locale) }
        let key = switch rule.freq {
        case .hourly: "Every %lld hours"
        case .daily: "Every %lld days"
        case .weekly: "Every %lld weeks"
        case .monthly: "Every %lld months"
        case .yearly: "Every %lld years"
        }
        var text = plural(key, rule.interval, locale)
        let names = phone.standaloneWeekdaySymbols
        let days = rule.byDay.filter { $0.ordinal == 0 && (1...7).contains($0.weekday) && names.count == 7 }
            .map { names[$0.weekday % 7] }
        if rule.freq == .weekly, !days.isEmpty {
            let list = ListFormatter()
            list.locale = locale
            text += " · " + (list.string(from: days) ?? days.joined(separator: ", "))
        }
        if let until = rule.until?.instant(in: phone.timeZone) {
            let date = style(phone, date: .abbreviated, time: .omitted).format(until)
            text += " · " + String(format: L10n.string("until %@", locale: locale), locale: locale, date)
        }
        return text
    }

    private static func plural(_ key: String, _ count: Int, _ locale: Locale) -> String {
        String(format: L10n.string(key, locale: locale), locale: locale, count)
    }

    private static func style(
        _ phone: Calendar, date: Date.FormatStyle.DateStyle, time: Date.FormatStyle.TimeStyle
    ) -> Date.FormatStyle {
        Date.FormatStyle(
            date: date, time: time, locale: phone.locale ?? .current, calendar: phone, timeZone: phone.timeZone)
    }

    /// The start of the day a yyyymmdd key names.
    static func day(_ key: Int, _ phone: Calendar) -> Date? {
        phone.date(from: DateComponents(year: key / 10_000, month: key / 100 % 100, day: key % 100))
    }
}
