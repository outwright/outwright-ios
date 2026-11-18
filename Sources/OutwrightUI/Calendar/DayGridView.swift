// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightModel
import SwiftUI

/// Day, 3 Day and the weeks: each day's header, the all-day band, and a scrolling hour grid that
/// opens at the current hour, with the now line on today. Day and 3 Day page a day at a time under the
/// finger, the headers and the all-day band moving with the hours, which keep their height from day to
/// day. A tap on an empty slot opens a new event at that half hour.
struct DayGridView: View {
    let app: AppModel
    @Bindable var model: CalendarModel
    /// An empty slot was tapped: a new event at this time.
    let addEvent: (Date) -> Void

    /// An hour's height and the time column's width grow with the text.
    @ScaledMetric(relativeTo: .caption2) private var hourHeight: CGFloat = 56
    @ScaledMetric(relativeTo: .caption2) private var gutter: CGFloat = 46

    /// How far the paging days are scrolled, which the headers and the all-day band follow.
    @State private var offset: CGFloat = 0
    /// The day at the leading edge of the paging days.
    @State private var position: Date?

    /// The days laid out side by side: in Day and 3 Day a week more on each side to page into.
    private var columns: [DayColumn] { model.pages ? model.pageDays : model.days }
    private var shownCount: Int { model.pages ? model.pageWidth : max(model.days.count, 1) }
    private var shownDays: Set<Date> { Set(model.days.map(\.day)) }

    var body: some View {
        GeometryReader { geometry in
            let width = max((geometry.size.width - gutter) / CGFloat(shownCount), 1)
            VStack(spacing: 0) {
                band(width) { headers(width) }
                    .padding(.vertical, 6)
                if model.days.contains(where: { !$0.allDay.isEmpty }) {
                    AllDayBand(
                        app: app, model: model, columns: columns, shownDays: shownDays, width: width,
                        shownCount: shownCount, offset: offset, gutter: gutter)
                }
                Rectangle().fill(Theme.separator).frame(height: 1)
                grid(width)
            }
        }
    }

    /// A row beside the time column that moves with the paging days and is cut at the screen's edge.
    private func band(_ width: CGFloat, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: gutter, height: 1)
            content()
                .frame(width: width * CGFloat(columns.count), alignment: .leading)
                .offset(x: -offset)
                .frame(width: width * CGFloat(shownCount), alignment: .leading)
                .clipped()
        }
    }

    // MARK: Headers

    private func headers(_ width: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(columns) { day in
                DayHeader(day: day.day, isToday: model.isToday(day.day), calendar: model.calendar) {
                    withAnimation(.snappy) { model.openDay(day.day) }
                }
                .frame(width: width)
                .accessibilityHidden(!shownDays.contains(day.day))
            }
        }
    }

    // MARK: The hours

    private func grid(_ width: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                HStack(alignment: .top, spacing: 0) {
                    Color.clear.frame(width: gutter)
                    if model.pages {
                        pager(width)
                    } else {
                        HStack(spacing: 0) {
                            ForEach(model.days) { day in
                                dayColumn(day).frame(width: width)
                            }
                        }
                    }
                }
                .frame(height: hourHeight * 24, alignment: .top)
                .background(alignment: .topLeading) { hourLines }
                .padding(.vertical, 8)
            }
            .onAppear { scrollToNow(proxy) }
            .onChange(of: model.nowScrolls) { _, _ in
                if model.isToday(model.anchorDay) { withAnimation { scrollToNow(proxy) } }
            }
        }
    }

    /// Day and 3 Day: the days in a row that pages a day at a time, inside the hours' scroll, so every
    /// day shows the same hours.
    private func pager(_ width: CGFloat) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(model.pageDays) { day in
                    dayColumn(day)
                        .frame(width: width, height: hourHeight * 24)
                        .accessibilityHidden(!shownDays.contains(day.day))
                }
            }
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
        .scrollPosition(id: $position, anchor: .leading)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.x + geometry.contentInsets.leading
        } action: { _, new in
            offset = new
        }
        .onScrollPhaseChange { _, phase in
            // Once the days come to rest, the first one is the day in view.
            if phase == .idle, let position, position != model.anchorDay { model.anchorDay = position }
        }
        .onAppear { position = model.anchorDay }
        .onDisappear { offset = 0 }
        .onChange(of: model.anchorDay) { _, day in
            if position != day { position = day }
        }
    }

    private func dayColumn(_ day: DayColumn) -> some View {
        DayColumnView(app: app, model: model, column: day, tapSlot: addEvent)
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
                        .frame(width: gutter - 6, alignment: .trailing)
                        .offset(y: -7)
                    Rectangle().fill(Theme.separator).frame(height: 1)
                }
                .frame(height: hourHeight, alignment: .top)
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
    /// An empty slot was tapped: a new event at the start of its half hour.
    let tapSlot: (Date) -> Void
    @ScaledMetric(relativeTo: .caption2) private var hourHeight: CGFloat = 56

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        tapSlot(model.slot(on: column.day, minute: Int(location.y / max(hourHeight, 1) * 60)))
                    }
                    .accessibilityHidden(true)
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
        CGFloat(minutes) / 60 * hourHeight
    }
}

/// A day's name and number; today's number on the accent. A tap opens that day alone.
struct DayHeader: View {
    let day: Date
    let isToday: Bool
    let calendar: Calendar
    var open: () -> Void = {}

    private var style: Date.FormatStyle {
        Date.FormatStyle(locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone)
    }

    var body: some View {
        Button(action: open) {
            VStack(spacing: 2) {
                Text(verbatim: day.formatted(style.weekday(.abbreviated)))
                    .font(.caption)
                    .foregroundStyle(isToday ? Theme.accent : Theme.secondaryText)
                Text(verbatim: "\(calendar.component(.day, from: day))")
                    .font(.headline)
                    .monospacedDigit()
                    .foregroundStyle(isToday ? Theme.onAccent : Color.primary)
                    .frame(minWidth: 30, minHeight: 30)
                    .background { if isToday { Circle().fill(Theme.accent) } }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Up to seven columns across the phone: grows no further than the largest standard size.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        // Read as one element: "Sunday, November 8".
        .accessibilityLabel(Text(verbatim: day.formatted(style.weekday(.wide).month(.wide).day())))
        .accessibilityAddTraits(isToday ? .isSelected : [])
        .accessibilityIdentifier(isToday ? "calendar.day.today" : "calendar.day")
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
