// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightModel
import SwiftUI

/// Day, 3 Day and the week in landscape: each day's header with a plus, the all-day row, and a scrolling hour grid that
/// opens at the current hour, with the now line on today.
struct DayGridView: View {
    let app: AppModel
    @Bindable var model: CalendarModel

    static let hourHeight: CGFloat = 56
    static let gutter: CGFloat = 46
    static let allDayShown = 3

    var body: some View {
        VStack(spacing: 0) {
            headers
            if model.days.contains(where: { !$0.allDay.isEmpty }) { allDayRow }
            Rectangle().fill(Theme.separator).frame(height: 1)
            grid
        }
    }

    // MARK: Headers

    private var headers: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: Self.gutter, height: 1)
            ForEach(model.days) { day in
                DayHeader(
                    day: day.day, isToday: model.isToday(day.day), calendar: model.calendar,
                    canAdd: model.canAddEvents, add: { app.showNewEvent(day: day.day) })
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 6)
    }

    private var allDayRow: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(ui: "All day")
                .font(.caption2)
                .foregroundStyle(Theme.secondaryText)
                .frame(width: Self.gutter, alignment: .center)
                .padding(.top, 4)
            ForEach(model.days) { day in
                VStack(spacing: 2) {
                    ForEach(day.allDay.prefix(Self.allDayShown), id: \.occurrenceKey) { event in
                        Button { app.eventToShow = EventRequest(event) } label: {
                            EventBlock(
                                event: event, color: Color(calendar: model.color(of: event.calendarID)),
                                calendar: model.calendar, showsPlace: false)
                                .frame(height: 22)
                        }
                        .buttonStyle(.plain)
                    }
                    if day.allDay.count > Self.allDayShown {
                        Text(ui: "+\(day.allDay.count - Self.allDayShown) more")
                            .font(.caption2)
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                .padding(.horizontal, 1)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .padding(.bottom, 4)
    }

    // MARK: The hours

    private var grid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                ZStack(alignment: .topLeading) {
                    hourLines
                    HStack(spacing: 0) {
                        Color.clear.frame(width: Self.gutter)
                        ForEach(model.days) { day in
                            DayColumnView(app: app, model: model, column: day)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                .frame(height: Self.hourHeight * 24)
                .padding(.vertical, 8)
            }
            .onAppear { scrollToNow(proxy) }
            .onChange(of: model.nowScrolls) { _, _ in
                if model.isToday(model.anchorDay) { withAnimation { scrollToNow(proxy) } }
            }
        }
    }

    private func scrollToNow(_ proxy: ScrollViewProxy) {
        let hour = model.calendar.component(.hour, from: model.now())
        proxy.scrollTo(max(hour - 1, 0), anchor: .top)
    }

    private var hourLines: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                HStack(alignment: .top, spacing: 4) {
                    Text(verbatim: model.hourLabel(hour))
                        .font(.caption2)
                        .monospacedDigit()
                        // "11:00 PM" in a narrow gutter: one line, smaller, never broken.
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(Theme.secondaryText)
                        .frame(width: Self.gutter - 6, alignment: .trailing)
                        .offset(y: -7)
                    Rectangle().fill(Theme.separator).frame(height: 1)
                }
                .frame(height: Self.hourHeight, alignment: .top)
                .id(hour)
            }
        }
    }

}

/// One day's timed events at their wall-clock hours, side by side where they overlap.
struct DayColumnView: View {
    let app: AppModel
    let model: CalendarModel
    let column: DayColumn

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .topLeading) {
                ForEach(column.timed) { placed in
                    let top = y(placed.startMinute)
                    let bottom = max(y(placed.endMinute), top + 18)
                    let share = width / CGFloat(max(placed.columns, 1))
                    let color = Color(calendar: model.color(of: placed.event.calendarID))
                    Button { app.eventToShow = EventRequest(placed.event) } label: {
                        // Sharing the width, the title gets both lines.
                        EventBlock(
                            event: placed.event, color: color, calendar: model.calendar,
                            showsPlace: placed.columns == 1)
                    }
                    .buttonStyle(.plain)
                    .frame(width: max(share - 2, 4), height: bottom - top - 1)
                    .offset(x: share * CGFloat(placed.column) + 1, y: top)
                }
                if model.isToday(column.day) { nowLine(width: width) }
            }
        }
        .overlay(alignment: .leading) { Rectangle().fill(Theme.separator).frame(width: 1) }
    }

    /// Redrawn every minute at the calendar's own now (the app's clock).
    private func nowLine(width: CGFloat) -> some View {
        TimelineView(.everyMinute) { _ in
            let now = model.now()
            let top = y(model.minutes(of: now, on: column.day))
            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.accent).frame(width: width, height: 2)
                Circle().fill(Theme.accent).frame(width: 8, height: 8).offset(x: -4)
            }
            .offset(y: top - 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(ui: "Now"))
            .accessibilityValue(Text(verbatim: now.formatted(
                Date.FormatStyle(
                    date: .omitted, time: .shortened, locale: model.calendar.locale ?? .current,
                    calendar: model.calendar, timeZone: model.calendar.timeZone))))
            .accessibilityIdentifier("calendar.nowLine")
        }
        .allowsHitTesting(false)
    }

    /// The height of a wall-clock minute of the day (so a day with a clock change still puts 09:00 at
    /// the 9 line).
    private func y(_ minutes: Int) -> CGFloat {
        CGFloat(minutes) / 60 * DayGridView.hourHeight
    }
}

/// A day's name and number; today's number on the accent. The plus opens the new-event editor on
/// that day.
struct DayHeader: View {
    let day: Date
    let isToday: Bool
    let calendar: Calendar
    var canAdd = true
    var add: () -> Void = {}

    private var style: Date.FormatStyle {
        Date.FormatStyle(locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone)
    }

    var body: some View {
        VStack(spacing: 2) {
            Text(verbatim: day.formatted(style.weekday(.abbreviated)))
                .font(.caption)
                .foregroundStyle(isToday ? Theme.accent : Theme.secondaryText)
                // Read with the number, as one element: "Sunday, November 8".
                .accessibilityHidden(true)
            HStack(spacing: 6) {
                Text(verbatim: "\(calendar.component(.day, from: day))")
                    .font(.headline)
                    .monospacedDigit()
                    .foregroundStyle(isToday ? Theme.onAccent : Color.primary)
                    .frame(minWidth: 30, minHeight: 30)
                    .background { if isToday { Circle().fill(Theme.accent) } }
                    .accessibilityLabel(Text(verbatim: day.formatted(style.weekday(.wide).month(.wide).day())))
                    .accessibilityAddTraits(isToday ? .isSelected : [])
                    .accessibilityIdentifier(isToday ? "calendar.day.today" : "calendar.day")
                Button(action: add) {
                    Image(systemName: Icons.add).font(.caption.weight(.semibold))
                }
                .disabled(!canAdd)
                .accessibilityLabel(Text(ui: "New event"))
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// An event drawn in its calendar's colour; a tentative one striped with a dashed edge.
struct EventBlock: View {
    let event: CalendarEvent
    let color: Color
    let calendar: Calendar
    var showsPlace = true

    var body: some View {
        let details = event.occurrence.details
        let shape = RoundedRectangle(cornerRadius: 5)
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: details.title.isEmpty ? L10n.string("(No title)") : details.title)
                .font(.caption.weight(.semibold))
                .strikethrough(details.status == .cancelled)
            if showsPlace, !details.place.isEmpty {
                Text(verbatim: details.place).font(.caption2).foregroundStyle(Theme.secondaryText)
            }
        }
        .lineLimit(2)
        .padding(.leading, event.isTentative ? 4 : 6)
        .padding(.trailing, 3)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            shape.fill(color.opacity(event.isTentative ? 0.10 : 0.22))
            if event.isTentative { Stripes(color: color).clipShape(shape) }
        }
        .overlay(alignment: .leading) {
            if !event.isTentative { Rectangle().fill(color).frame(width: 3) }
        }
        .overlay {
            if event.isTentative { shape.strokeBorder(color, style: StrokeStyle(lineWidth: 1.2, dash: [4, 3])) }
        }
        .clipShape(shape)
        .contentShape(shape)
        .spokenEvent(event, calendar: calendar)
    }
}

/// Diagonal stripes for a tentative event.
struct Stripes: View {
    let color: Color

    var body: some View {
        Canvas { context, size in
            var path = Path()
            var left = -size.height
            var lines = 0
            while left < size.width, lines < 1_000 {
                lines += 1
                path.move(to: CGPoint(x: left, y: size.height))
                path.addLine(to: CGPoint(x: left + size.height, y: 0))
                left += 7
            }
            context.stroke(path, with: .color(color.opacity(0.3)), lineWidth: 2)
        }
        .allowsHitTesting(false)
    }
}

extension CalendarEvent {
    /// The same for an occurrence however often it is read.
    var occurrenceKey: String { "\(id.raw).\(occurrence.start.timeIntervalSince1970)" }
}
