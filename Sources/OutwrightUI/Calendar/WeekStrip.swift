// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightModel
import SwiftUI

/// The week of the day in view under the calendar's title (Day, 3 Day and Agenda): a tap goes to a
/// day, a swipe to the week before or after.
struct WeekStrip: View {
    @ScaledMetric(relativeTo: .callout) private var dayCircle: CGFloat = 30
    let model: CalendarModel

    var body: some View {
        let calendar = model.calendar
        let style = Date.FormatStyle(
            locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone)
        HStack(spacing: 0) {
            ForEach(model.week(of: model.anchorDay), id: \.self) { day in
                let isChosen = day == model.anchorDay
                let isToday = model.isToday(day)
                Button {
                    withAnimation(.snappy) { model.jump(to: day) }
                } label: {
                    VStack(spacing: 2) {
                        Text(verbatim: day.formatted(style.weekday(.narrow)))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(isToday ? Theme.accent : Theme.secondaryText)
                        Text(verbatim: "\(calendar.component(.day, from: day))")
                            .font(.callout.weight(isToday || isChosen ? .bold : .regular))
                            .monospacedDigit()
                            .foregroundStyle(isChosen ? Theme.onAccent : isToday ? Theme.accent : Color.primary)
                            .frame(width: dayCircle, height: dayCircle)
                            .background { if isChosen { Circle().fill(Theme.accent) } }
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: day.formatted(style.weekday(.wide).month(.wide).day())))
                .accessibilityAddTraits(isChosen ? .isSelected : [])
                .accessibilityIdentifier("calendar.strip.day")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 30).onEnded { value in
                let width = value.translation.width
                guard abs(width) > 60, abs(width) > abs(value.translation.height) * 1.5 else { return }
                let next = model.calendar.date(byAdding: .day, value: width < 0 ? 7 : -7, to: model.anchorDay)
                withAnimation(.snappy) { model.jump(to: next ?? model.anchorDay) }
            })
    }
}
