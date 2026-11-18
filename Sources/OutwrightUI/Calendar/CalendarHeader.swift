// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI

/// Calendar's header: the month in large type, and in the capsule the view switcher and a way back to today.
struct CalendarHeader: View {
    @Bindable var app: AppModel
    @Bindable var model: CalendarModel

    var body: some View {
        TabHeader(
            app: app, title: model.monthTitle.capitalizedFirst, titleID: "calendar.title",
            titleAction: { withAnimation(.snappy) { model.showsMiniMonth.toggle() } },
            titleExpanded: model.showsMiniMonth,
            trailing: {
            Menu {
                if model.isLandscape {
                    Picker(selection: $model.weekMode) {
                        ForEach(WeekMode.allCases, id: \.self) { mode in
                            ModuleLabel(Self.name(mode), systemImage: Icons.weekMode(mode)).tag(mode)
                        }
                    } label: {
                        Text(ui: "View")
                    }
                } else {
                    Picker(selection: $model.mode) {
                        ForEach(model.offeredModes, id: \.self) { mode in
                            ModuleLabel(Self.name(mode), systemImage: Icons.calendarMode(mode)).tag(mode)
                        }
                    } label: {
                        Text(ui: "View")
                    }
                }
            } label: {
                Image(systemName: model.isLandscape ? Icons.weekMode(model.weekMode) : Icons.calendarMode(model.mode))
            }
            .accessibilityLabel(Text(ui: "View"))
            .accessibilityIdentifier("calendar.mode")
            Button {
                withAnimation(.snappy) { model.goToToday() }
            } label: {
                TodayMark(day: model.calendar.component(.day, from: model.today))
            }
            .accessibilityLabel(Text(ui: "Today"))
            .accessibilityIdentifier("calendar.today")
        })
    }

    static func name(_ mode: CalendarMode) -> LocalizedStringKey {
        switch mode {
        case .agenda: "Agenda"
        case .day: "Day"
        case .threeDay: "3 Day"
        case .month: "Month"
        case .week: "Week"
        case .workWeek: "Work week"
        }
    }

    static func name(_ mode: WeekMode) -> LocalizedStringKey {
        switch mode {
        case .workWeek: "Work week"
        case .week: "Week"
        }
    }
}

/// Today's day number in a small page, drawn here rather than taken from a symbol.
struct TodayMark: View {
    let day: Int
    @ScaledMetric(relativeTo: .caption) private var width: CGFloat = 24
    @ScaledMetric(relativeTo: .caption) private var height: CGFloat = 22

    var body: some View {
        Text(verbatim: "\(day)")
            .font(.caption.weight(.bold).monospacedDigit())
            .fontDesign(.rounded)
            .frame(width: width, height: height)
            .overlay {
                RoundedRectangle(cornerRadius: 5).strokeBorder(lineWidth: 1.6)
            }
            .overlay(alignment: .top) {
                Rectangle()
                    .frame(height: 4)
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 5, topTrailingRadius: 5))
            }
    }
}

extension String {
    /// The first letter in upper case ("november 2026" in Swedish is a title here).
    var capitalizedFirst: String {
        guard let first = first else { return self }
        return first.uppercased() + dropFirst()
    }
}
