// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightModel
import SwiftUI

/// A repeat the custom screen edits: how often, on which days, and when it ends. It holds the rules
/// the screen can show (RFC 5545's RRULE with a frequency of a day or more, an interval, weekdays, a
/// monthly date or weekday, and COUNT or UNTIL); any other rule stays as it is, uneditable.
struct CustomRepeat: Equatable {
    enum Frequency: Hashable, CaseIterable { case daily, weekly, monthly, yearly }
    /// A month's occurrence: on the start's date, or on its weekday of the month ("the second Tuesday").
    enum MonthlyBy: Hashable { case date, weekday }
    enum End: Equatable {
        case never
        /// The last day it may happen.
        case onDay(Date)
        case after(Int)
    }

    var frequency: Frequency
    var interval: Int
    /// ISO weekdays (1 Monday … 7 Sunday) of a weekly repeat.
    var weekdays: Set<Int>
    var monthlyBy: MonthlyBy
    var end: End

    static let intervals = 1...99
    static let counts = 1...999

    /// A new pattern: every week on the start's weekday, with no end.
    init(start: Date, phone: Calendar) {
        frequency = .weekly
        interval = 1
        weekdays = [EditorTimes.isoWeekday(start, phone)]
        monthlyBy = .date
        end = .never
    }

    /// The pattern a rule is for an event starting at `start`; nil when the rule says more than the
    /// screen shows.
    init?(rule: RecurrenceRule, start: Date, phone: Calendar, zones: [String: ZoneRules] = [:]) {
        guard rule.rscale == nil, rule.skip == nil, rule.otherParts.isEmpty, rule.byYearDay.isEmpty,
            rule.byWeekNo.isEmpty, rule.byHour.isEmpty, rule.byMinute.isEmpty, rule.bySecond.isEmpty,
            rule.weekStart == 1
        else { return nil }
        self.init(start: start, phone: phone)
        interval = rule.interval
        guard take(rule, start: start, phone: phone) else { return nil }
        if let count = rule.count {
            end = .after(count)
        } else if let until = rule.until, let last = until.instant(in: phone.timeZone, zones: zones) {
            end = .onDay(last)
        }
    }

    /// The rule's frequency and days taken; false for a rule that says more than the screen shows.
    private mutating func take(_ rule: RecurrenceRule, start: Date, phone: Calendar) -> Bool {
        let weekday = EditorTimes.isoWeekday(start, phone)
        let day = phone.component(.day, from: start)
        let month = phone.component(.month, from: start)
        switch rule.freq {
        case .hourly:
            return false
        case .daily:
            frequency = .daily
            return rule.byDay.isEmpty && rule.byMonthDay.isEmpty && rule.byMonth.isEmpty && rule.bySetPos.isEmpty
        case .weekly:
            frequency = .weekly
            weekdays = rule.byDay.isEmpty ? [weekday] : Set(rule.byDay.map(\.weekday))
            return rule.byMonthDay.isEmpty && rule.byMonth.isEmpty && rule.bySetPos.isEmpty
                && rule.byDay.allSatisfy { $0.ordinal == 0 }
        case .monthly:
            frequency = .monthly
            guard rule.byMonth.isEmpty, let monthly = Self.monthly(rule, weekday: weekday, day: day) else {
                return false
            }
            monthlyBy = monthly
            return true
        case .yearly:
            frequency = .yearly
            return rule.byDay.isEmpty && rule.bySetPos.isEmpty && (rule.byMonth.isEmpty || rule.byMonth == [month])
                && (rule.byMonthDay.isEmpty || rule.byMonthDay == [day])
        }
    }

    /// How a monthly rule falls: on the start's date, or on its weekday of the month; nil for any other.
    private static func monthly(_ rule: RecurrenceRule, weekday: Int, day: Int) -> MonthlyBy? {
        if rule.byDay.isEmpty, rule.bySetPos.isEmpty, rule.byMonthDay.isEmpty || rule.byMonthDay == [day] {
            return .date
        }
        guard rule.byMonthDay.isEmpty, rule.byDay.count == 1, let only = rule.byDay.first, only.weekday == weekday
        else { return nil }
        let ordinal = Self.ordinal(day: day)
        if only.ordinal != 0, rule.bySetPos.isEmpty { return only.ordinal == ordinal ? .weekday : nil }
        if only.ordinal == 0, rule.bySetPos == [ordinal] { return .weekday }
        return nil
    }

    /// The week of the month a day is in, as BYDAY counts it: 1 to 4, and the fifth as the last (-1).
    static func ordinal(day: Int) -> Int {
        let week = (day - 1) / 7 + 1
        return week >= 5 ? -1 : week
    }

    /// The rule for an event starting at `start` (`startTime` as stored): UNTIL is a date for an all-day
    /// event, a local time for a floating one and UTC otherwise (RFC 5545 › 3.3.10), at the end of the
    /// day chosen.
    func rule(startTime: EventTime, start: Date, phone: Calendar) -> RecurrenceRule {
        let weekday = EditorTimes.isoWeekday(start, phone)
        var rule = switch frequency {
        case .daily: RecurrenceRule(freq: .daily, interval: interval)
        case .weekly:
            RecurrenceRule(
                freq: .weekly, interval: interval,
                byDay: (weekdays.isEmpty ? [weekday] : weekdays.sorted()).map { WeekdayNum(weekday: $0) })
        case .monthly where monthlyBy == .weekday:
            RecurrenceRule(
                freq: .monthly, interval: interval,
                byDay: [WeekdayNum(weekday: weekday, ordinal: Self.ordinal(day: phone.component(.day, from: start)))])
        case .monthly: RecurrenceRule(freq: .monthly, interval: interval)
        case .yearly: RecurrenceRule(freq: .yearly, interval: interval)
        }
        switch end {
        case .never: break
        case let .after(count): rule.count = min(max(count, Self.counts.lowerBound), Self.counts.upperBound)
        case let .onDay(day): rule.until = Self.until(day, like: startTime, phone: phone)
        }
        return rule
    }

    private static func until(_ day: Date, like start: EventTime, phone: Calendar) -> EventTime {
        let first = phone.startOfDay(for: day)
        let last = (phone.date(byAdding: .day, value: 1, to: first) ?? first).addingTimeInterval(-1)
        switch start {
        case .date: return EditorTimes.make(like: start, at: first, phone: phone)
        case .floating: return EditorTimes.make(like: start, at: last, phone: phone)
        case .zoned, .utc: return .utc(last)
        }
    }
}

/// The custom repeat screen, pushed in the editor: how often, on which weekdays or which day of the
/// month, and when the repeat ends.
struct CustomRepeatView: View {
    @Binding var pattern: CustomRepeat
    let start: Date
    let phone: Calendar

    var body: some View {
        Form {
            Section {
                Picker(selection: $pattern.frequency) {
                    ForEach(CustomRepeat.Frequency.allCases, id: \.self) { frequency in
                        Text(ui: Self.title(frequency)).tag(frequency)
                    }
                } label: {
                    Text(ui: "Repeats")
                }
                .accessibilityIdentifier("customRepeat.frequency")
                Stepper(value: $pattern.interval, in: CustomRepeat.intervals) {
                    Text(ui: Self.every(pattern.frequency, pattern.interval))
                }
                .accessibilityIdentifier("customRepeat.interval")
                if pattern.frequency == .weekly { weekdayChips }
                if pattern.frequency == .monthly { monthlyPicker }
            }
            endSection
        }
        .scrollContentBackground(.hidden)
        .background(Theme.drawerBackground)
        .navigationTitle(Text(ui: "Custom repeat"))
        .inlineNavigationTitle()
    }

    /// The seven weekdays in the phone's order, the chosen ones filled.
    private var weekdayChips: some View {
        let symbols = phone.veryShortStandaloneWeekdaySymbols
        let names = phone.standaloneWeekdaySymbols
        // Calendar counts Sunday as 1; ISO counts Monday as 1.
        let order = (0..<7).map { (phone.firstWeekday - 1 + $0) % 7 + 1 }
        return HStack(spacing: 6) {
            ForEach(order, id: \.self) { calendarDay in
                let iso = (calendarDay + 5) % 7 + 1
                let isOn = pattern.weekdays.contains(iso)
                let index = calendarDay - 1
                Button {
                    // At least one day stays chosen.
                    if isOn, pattern.weekdays.count > 1 {
                        pattern.weekdays.remove(iso)
                    } else {
                        pattern.weekdays.insert(iso)
                    }
                } label: {
                    Text(verbatim: symbols.indices.contains(index) ? symbols[index] : "")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(Circle().fill(isOn ? Theme.accent : Theme.headerTrack))
                        .foregroundStyle(isOn ? Theme.onAccent : Theme.headerText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: names.indices.contains(index) ? names[index] : ""))
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .accessibilityIdentifier("customRepeat.weekdays")
    }

    private var monthlyPicker: some View {
        let locale = phone.locale ?? .current
        let day = phone.component(.day, from: start)
        let weekday = start.formatted(Date.FormatStyle(locale: locale, calendar: phone).weekday(.wide))
        let ordinal = CustomRepeat.ordinal(day: day)
        return Picker(selection: $pattern.monthlyBy) {
            Text(ui: "On day \(day)").tag(CustomRepeat.MonthlyBy.date)
            Text(ui: Self.onThe(ordinal, weekday)).tag(CustomRepeat.MonthlyBy.weekday)
        } label: {
            Text(ui: "Each month")
        }
        .pickerStyle(.inline)
        .labelsHidden()
        .accessibilityIdentifier("customRepeat.monthly")
    }

    private enum EndChoice: Hashable { case never, onDay, after }

    private var endChoice: Binding<EndChoice> {
        Binding {
            switch pattern.end {
            case .never: .never
            case .onDay: .onDay
            case .after: .after
            }
        } set: { choice in
            switch choice {
            case .never: pattern.end = .never
            case .onDay:
                let month = phone.date(byAdding: .month, value: 1, to: start) ?? start
                if case .onDay = pattern.end {} else { pattern.end = .onDay(month) }
            case .after:
                if case .after = pattern.end {} else { pattern.end = .after(10) }
            }
        }
    }

    private var endSection: some View {
        Section {
            Picker(selection: endChoice) {
                Text(ui: "Never").tag(EndChoice.never)
                Text(ui: "On date").tag(EndChoice.onDay)
                Text(ui: "After a number of times").tag(EndChoice.after)
            } label: {
                Text(ui: "End repeat")
            }
            .accessibilityIdentifier("customRepeat.end")
            if case let .onDay(day) = pattern.end {
                DatePicker(
                    selection: Binding(get: { day }, set: { pattern.end = .onDay($0) }), in: start...,
                    displayedComponents: [.date]
                ) {
                    Text(ui: "Last day")
                }
                .environment(\.timeZone, phone.timeZone)
                .accessibilityIdentifier("customRepeat.until")
            }
            if case let .after(count) = pattern.end {
                Stepper(
                    value: Binding(get: { count }, set: { pattern.end = .after($0) }), in: CustomRepeat.counts
                ) {
                    Text(ui: "After \(count) times")
                }
                .accessibilityIdentifier("customRepeat.count")
            }
        }
    }

    static func title(_ frequency: CustomRepeat.Frequency) -> LocalizedStringKey {
        switch frequency {
        case .daily: "Daily"
        case .weekly: "Weekly"
        case .monthly: "Monthly"
        case .yearly: "Yearly"
        }
    }

    static func every(_ frequency: CustomRepeat.Frequency, _ count: Int) -> LocalizedStringKey {
        switch frequency {
        case .daily: "Every \(count) days"
        case .weekly: "Every \(count) weeks"
        case .monthly: "Every \(count) months"
        case .yearly: "Every \(count) years"
        }
    }

    static func onThe(_ ordinal: Int, _ weekday: String) -> LocalizedStringKey {
        switch ordinal {
        case 1: "On the first \(weekday)"
        case 2: "On the second \(weekday)"
        case 3: "On the third \(weekday)"
        case 4: "On the fourth \(weekday)"
        default: "On the last \(weekday)"
        }
    }
}
