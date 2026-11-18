// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightModel
import SwiftUI

/// The month that opens under the calendar's title: any day in it is a tap away, and the months
/// before and after a swipe (or a chevron) away. A tapped day is shown and the month closes.
struct MiniMonth: View {
    let model: CalendarModel

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Button { step(-1) } label: {
                    Image(systemName: Icons.previousMonth).padding(8)
                }
                .accessibilityLabel(Text(ui: "Previous month"))
                Spacer()
                Text(verbatim: model.monthTitle(of: model.miniMonth).capitalizedFirst)
                    .font(.subheadline.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button { step(1) } label: {
                    Image(systemName: Icons.nextMonth).padding(8)
                }
                .accessibilityLabel(Text(ui: "Next month"))
            }
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 8)
            MonthGrid(
                model: model, days: model.miniMonthDays, month: model.miniMonth, chosen: model.anchorDay,
                compact: true
            ) { day in
                withAnimation(.snappy) { model.jump(to: day) }
            }
        }
        .padding(.bottom, 6)
        .background(Theme.background)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 30).onEnded { value in
                let width = value.translation.width
                guard abs(width) > 60, abs(width) > abs(value.translation.height) * 1.5 else { return }
                step(width < 0 ? 1 : -1)
            })
        .accessibilityIdentifier("calendar.miniMonth")
    }

    private func step(_ months: Int) {
        withAnimation(.snappy) { model.stepMiniMonth(months) }
    }
}
