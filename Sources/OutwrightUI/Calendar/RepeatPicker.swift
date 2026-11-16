// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightModel
import SwiftUI

/// What the repeat picker offers. `custom` is a rule the picker cannot show: it is shown, never chosen.
enum RepeatChoice: Hashable, CaseIterable {
    case never, daily, weekly, everyTwoWeeks, monthly, yearly, custom

    /// The choices a person can pick.
    static let offered: [RepeatChoice] = [.never, .daily, .weekly, .everyTwoWeeks, .monthly, .yearly]

    /// The rule for a choice, repeating from the start's weekday, day or date (nil for never and custom).
    var rule: RecurrenceRule? {
        switch self {
        case .never, .custom: nil
        case .daily: RecurrenceRule(freq: .daily)
        case .weekly: RecurrenceRule(freq: .weekly)
        case .everyTwoWeeks: RecurrenceRule(freq: .weekly, interval: 2)
        case .monthly: RecurrenceRule(freq: .monthly)
        case .yearly: RecurrenceRule(freq: .yearly)
        }
    }

    /// The choice a rule is, for an event starting at `start`; `custom` when it says more than a
    /// choice does (an end, other days, other parts, seconds, a calendar scale or a skip, or parts
    /// only kept as text).
    static func of(_ rule: RecurrenceRule?, start: Date, phone: Calendar) -> RepeatChoice {
        guard let rule else { return .never }
        guard rule.count == nil, rule.until == nil, rule.bySetPos.isEmpty, rule.byYearDay.isEmpty,
            rule.byWeekNo.isEmpty, rule.byHour.isEmpty, rule.byMinute.isEmpty, rule.weekStart == 1,
            rule.bySecond.isEmpty, rule.rscale == nil, rule.skip == nil, rule.otherParts.isEmpty
        else { return .custom }
        let day = phone.component(.day, from: start)
        let month = phone.component(.month, from: start)
        let weekday = [WeekdayNum(weekday: EditorTimes.isoWeekday(start, phone))]
        let onStartDay = rule.byMonthDay.isEmpty || rule.byMonthDay == [day]
        let onStartMonth = rule.byMonth.isEmpty || rule.byMonth == [month]
        let onStartWeekday = rule.byDay.isEmpty || rule.byDay == weekday
        switch (rule.freq, rule.interval) {
        case (.daily, 1) where rule.byDay.isEmpty && rule.byMonthDay.isEmpty && rule.byMonth.isEmpty:
            return .daily
        case (.weekly, 1) where onStartWeekday && rule.byMonthDay.isEmpty && rule.byMonth.isEmpty:
            return .weekly
        case (.weekly, 2) where onStartWeekday && rule.byMonthDay.isEmpty && rule.byMonth.isEmpty:
            return .everyTwoWeeks
        case (.monthly, 1) where onStartDay && rule.byDay.isEmpty && rule.byMonth.isEmpty:
            return .monthly
        case (.yearly, 1) where onStartDay && onStartMonth && rule.byDay.isEmpty:
            return .yearly
        default:
            return .custom
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .never: "Never"
        case .daily: "Every day"
        case .weekly: "Every week"
        case .everyTwoWeeks: "Every two weeks"
        case .monthly: "Every month"
        case .yearly: "Every year"
        case .custom: "Custom"
        }
    }
}

/// The repeat row: the choices, and "Custom" while the event keeps a rule the picker cannot show.
struct RepeatPicker: View {
    @Binding var choice: RepeatChoice
    let showsCustom: Bool

    var body: some View {
        Picker(selection: $choice) {
            ForEach(RepeatChoice.offered + (showsCustom ? [.custom] : []), id: \.self) { item in
                Text(ui: item.title).tag(item)
            }
        } label: {
            ModuleLabel("Repeat", systemImage: Icons.repeats)
        }
        .accessibilityIdentifier("editor.repeat")
    }
}
