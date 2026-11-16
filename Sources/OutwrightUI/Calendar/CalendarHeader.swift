// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI

/// The month in large type, and a glass capsule with the view switcher, a way back to today and
/// the calendars filter.
struct CalendarHeader: View {
    @Bindable var model: CalendarModel
    @Binding var isFiltering: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(verbatim: model.monthTitle.capitalizedFirst)
                .font(.largeTitle.bold())
                .foregroundStyle(Theme.headerText)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .accessibilityIdentifier("calendar.title")
            Spacer(minLength: 8)
            capsule
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 12)
        .background(Theme.header.ignoresSafeArea(edges: .top))
    }

    private var capsule: some View {
        HStack(spacing: 20) {
            Menu {
                if model.showsWeek {
                    Picker(selection: $model.weekMode) {
                        ForEach(WeekMode.allCases, id: \.self) { mode in
                            ModuleLabel(Self.name(mode), systemImage: Icons.weekMode(mode)).tag(mode)
                        }
                    } label: {
                        Text(ui: "View")
                    }
                } else {
                    Picker(selection: $model.mode) {
                        ForEach(CalendarMode.allCases, id: \.self) { mode in
                            ModuleLabel(Self.name(mode), systemImage: Icons.calendarMode(mode)).tag(mode)
                        }
                    } label: {
                        Text(ui: "View")
                    }
                }
            } label: {
                Image(systemName: model.showsWeek ? Icons.weekMode(model.weekMode) : Icons.calendarMode(model.mode))
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
            Button {
                isFiltering = true
            } label: {
                Image(systemName: Icons.filter)
                    .foregroundStyle(model.shownCalendars == nil ? Theme.headerText : Theme.accent)
            }
            .accessibilityLabel(Text(ui: "Calendars"))
            .accessibilityIdentifier("calendar.filter")
        }
        .font(.title3)
        .foregroundStyle(Theme.headerText)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .glassEffect(.regular.tint(Theme.accent.opacity(0.12)).interactive(), in: .capsule)
    }

    static func name(_ mode: CalendarMode) -> LocalizedStringKey {
        switch mode {
        case .agenda: "Agenda"
        case .day: "Day"
        case .threeDay: "3 Day"
        case .month: "Month"
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

    var body: some View {
        Text(verbatim: "\(day)")
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .monospacedDigit()
            .frame(width: 24, height: 22)
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
