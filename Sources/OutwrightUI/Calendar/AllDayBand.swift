// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightModel
import SwiftUI

/// The all-day band over the hour grid: each all-day event one bar across the days it lasts, in lanes.
/// Past three lanes the last shows "+N more" per day, and a tap shows every lane; the "All day" label
/// folds them again. It moves with the paging days, cut at the screen's edge.
struct AllDayBand: View {
    let app: AppModel
    let model: CalendarModel
    /// The days laid out side by side, and the ones on screen.
    let columns: [DayColumn]
    let shownDays: Set<Date>
    /// A day's width, how many days are on screen, how far the days are scrolled, and the time column's width.
    let width: CGFloat
    let shownCount: Int
    let offset: CGFloat
    let gutter: CGFloat
    @ScaledMetric(relativeTo: .caption) private var laneHeight: CGFloat = 24
    /// "+N more" was tapped: every lane shows.
    @State private var isOpen = false

    /// Lanes shown before "+N more".
    static let allDayShown = 3

    var body: some View {
        // Lanes are counted on the days on screen only.
        let bars = AllDayLayout.bars(columns) { columns.indices.contains($0) && shownDays.contains(columns[$0].day) }
        let lanes = (bars.map(\.lane).max() ?? -1) + 1
        let folded = !isOpen && lanes > Self.allDayShown
        let shownLanes = folded ? Self.allDayShown - 1 : lanes
        return HStack(alignment: .top, spacing: 0) {
            Button {
                withAnimation(.snappy) { isOpen.toggle() }
            } label: {
                VStack(spacing: 2) {
                    Text(ui: "All day")
                    if lanes > Self.allDayShown {
                        Image(systemName: Icons.miniMonth(open: isOpen))
                    }
                }
                .font(.caption2)
                .foregroundStyle(Theme.secondaryText)
                .frame(width: gutter)
                .padding(.top, 4)
            }
            .buttonStyle(.plain)
            .disabled(lanes <= Self.allDayShown)
            .accessibilityAddTraits(isOpen ? .isSelected : [])
            ZStack(alignment: .topLeading) {
                ForEach(bars.filter { $0.lane < shownLanes }) { bar in
                    allDayBar(bar)
                }
                if folded {
                    ForEach(Array(columns.enumerated()), id: \.element.id) { index, day in
                        let hidden = bars.filter { $0.lane >= shownLanes && $0.first <= index && index <= $0.last }
                        if !hidden.isEmpty {
                            Button {
                                withAnimation(.snappy) { isOpen = true }
                            } label: {
                                Text(ui: "+\(hidden.count) more")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Theme.accent)
                                    .frame(width: width, height: laneHeight)
                            }
                            .buttonStyle(.plain)
                            .offset(x: width * CGFloat(index), y: CGFloat(shownLanes) * laneHeight)
                            .accessibilityHidden(!shownDays.contains(day.day))
                        }
                    }
                }
            }
            .frame(
                width: width * CGFloat(columns.count),
                height: laneHeight * CGFloat(folded ? Self.allDayShown : lanes), alignment: .topLeading)
            .offset(x: -offset)
            .frame(width: width * CGFloat(shownCount), alignment: .topLeading)
            .clipped()
        }
        .padding(.bottom, 4)
    }

    private func allDayBar(_ bar: AllDayBar) -> some View {
        Button { app.eventToShow = EventRequest(bar.event) } label: {
            EventBlock(
                event: bar.event, color: Color(calendar: model.color(of: bar.event.calendarID)),
                calendar: model.calendar, showsPlace: false)
        }
        .buttonStyle(.plain)
        .frame(width: max(width * CGFloat(bar.last - bar.first + 1) - 2, 4), height: laneHeight - 2)
        .offset(x: width * CGFloat(bar.first) + 1, y: CGFloat(bar.lane) * laneHeight)
    }
}
