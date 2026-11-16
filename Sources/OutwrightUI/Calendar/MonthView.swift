// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightModel
import SwiftUI

/// The month as a grid of weeks from the locale's first weekday, a dot per calendar with events on
/// a day, and the chosen day's events below.
struct MonthView: View {
    let app: AppModel
    let model: CalendarModel

    private var columns: [GridItem] { Array(repeating: GridItem(.flexible(), spacing: 0), count: 7) }

    var body: some View {
        VStack(spacing: 0) {
            LazyVGrid(columns: columns, spacing: 0) {
                ForEach(Array(model.weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(verbatim: symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.vertical, 6)
                }
                ForEach(model.days) { day in
                    cell(day)
                }
            }
            .padding(.horizontal, 8)
            Rectangle().fill(Theme.separator).frame(height: 1)
            chosenDay
        }
    }

    private func cell(_ day: DayColumn) -> some View {
        let calendar = model.calendar
        let inMonth = calendar.isDate(day.day, equalTo: model.anchorDay, toGranularity: .month)
        let isChosen = day.day == model.anchorDay
        let isToday = model.isToday(day.day)
        return Button {
            withAnimation(.snappy) { model.anchorDay = day.day }
        } label: {
            VStack(spacing: 3) {
                Text(verbatim: "\(calendar.component(.day, from: day.day))")
                    .font(.callout.weight(isToday || isChosen ? .bold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(
                        isChosen ? Theme.onAccent
                            : isToday ? Theme.accent : inMonth ? Color.primary : Theme.secondaryText)
                    .frame(width: 32, height: 32)
                    .background { if isChosen { Circle().fill(Theme.accent) } }
                HStack(spacing: 3) {
                    ForEach(dots(day), id: \.self) { color in
                        Circle().fill(Color(calendar: color)).frame(width: 5, height: 5)
                    }
                }
                .frame(height: 5)
            }
            .frame(maxWidth: .infinity, minHeight: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: day.day.formatted(
            Date.FormatStyle(
                date: .complete, time: .omitted, locale: calendar.locale ?? .current, calendar: calendar,
                timeZone: calendar.timeZone))))
        .accessibilityValue(Text(ui: "\(day.allDay.count + day.timed.count) events"))
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }

    /// One dot per calendar with events that day, at most three.
    private func dots(_ day: DayColumn) -> [Int] {
        var colors: [Int] = []
        for event in day.allDay + day.timed.map(\.event) {
            let color = model.color(of: event.calendarID)
            if !colors.contains(color) { colors.append(color) }
            if colors.count == 3 { break }
        }
        return colors
    }

    @ViewBuilder private var chosenDay: some View {
        if let day = model.chosenDay {
            List {
                Section {
                    if day.isEmpty { Text(ui: "No events").foregroundStyle(Theme.secondaryText) }
                    ForEach(day.allDay + day.timed.map(\.event), id: \.occurrenceKey) { event in
                        AgendaRow(app: app, model: model, event: event, day: day.day)
                    }
                } header: {
                    Text(verbatim: AgendaView.title(day.day, model: model))
                        .font(.subheadline.weight(.semibold))
                }
            }
            .listStyle(.plain)
        } else {
            Spacer()
        }
    }
}
