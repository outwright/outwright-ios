// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightModel
import SwiftUI

/// The agenda: one list of days, every day with its events or "No events", that opens at the day in
/// view and grows at either end as it is reached. Today and a day chosen above scroll it there.
struct AgendaView: View {
    let app: AppModel
    let model: CalendarModel
    /// The day at the top of the list.
    @State private var top: Date?
    /// The list has been put at its first day: an end it shows from now on was scrolled to.
    @State private var placed = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.days) { day in
                    dayView(day)
                        .id(day.day)
                        .onAppear { reached(day.day) }
                }
            }
            .scrollTargetLayout()
        }
        .scrollPosition(id: $top, anchor: .top)
        .onAppear {
            top = model.anchorDay
            Task { @MainActor in placed = true }
        }
        .onChange(of: top) { _, day in
            if let day, placed { model.scrolled(to: day) }
        }
        .onChange(of: model.jumps) { _, _ in show(model.anchorDay) }
        .onChange(of: model.nowScrolls) { _, _ in show(model.today) }
    }

    private func dayView(_ day: DayColumn) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(
                verbatim: AgendaView.title(day.day, model: model), tint: model.isToday(day.day) ? Theme.accent : nil)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.background)
            if day.isEmpty {
                Text(ui: "No events")
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
            ForEach(day.allDay + day.timed.map(\.event), id: \.occurrenceKey) { event in
                AgendaRow(app: app, model: model, event: event, day: day.day)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                Rectangle().fill(Theme.separator).frame(height: 1).padding(.leading, 16)
            }
        }
    }

    /// An end of the list came into view: a month more there.
    private func reached(_ day: Date) {
        guard placed else { return }
        if day == model.days.first?.day { model.extendAgenda(.top) }
        if day == model.days.last?.day { model.extendAgenda(.bottom) }
    }

    private func show(_ day: Date) {
        withAnimation(.snappy) { top = model.calendar.startOfDay(for: day) }
    }

    /// "Today · Sunday 8 November", "Tomorrow · …", else the date.
    static func title(_ day: Date, model: CalendarModel) -> String {
        let calendar = model.calendar
        let locale = calendar.locale ?? .current
        let date = day.formatted(
            Date.FormatStyle(date: .complete, time: .omitted, locale: locale, calendar: calendar,
                             timeZone: calendar.timeZone))
        if model.isToday(day) { return L10n.string("Today", locale: locale) + " · " + date }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: model.today), tomorrow == day {
            return L10n.string("Tomorrow", locale: locale) + " · " + date
        }
        return date
    }
}

/// An event in a list: its hours (or All day), its calendar's colour, title and place, and Join for a
/// meeting from a quarter of an hour before it starts until it ends.
struct AgendaRow: View {
    @ScaledMetric(relativeTo: .subheadline) private var hoursWidth: CGFloat = 64
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let app: AppModel
    let model: CalendarModel
    let event: CalendarEvent
    let day: Date

    /// At the accessibility sizes the hours stand above the title, not in a column beside it, and
    /// Join goes under the row.
    private var isStacked: Bool { dynamicTypeSize.isAccessibilitySize }

    var body: some View {
        let layout = isStacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 8))
        layout {
            row
            // Read again each minute, by the app's clock.
            TimelineView(.everyMinute) { _ in
                if let meeting = EventLinks.joinable(event.occurrence, now: model.now()) {
                    JoinButton(url: meeting)
                }
            }
            .fixedSize()
        }
    }

    private var row: some View {
        let details = event.occurrence.details
        let color = Color(calendar: model.color(of: event.calendarID))
        return Button { app.eventToShow = EventRequest(event) } label: {
            VStack(alignment: .leading, spacing: 4) {
                if isStacked { hours }
                HStack(alignment: .top, spacing: 12) {
                    if !isStacked { hours.frame(width: hoursWidth, alignment: .leading) }
                    Circle()
                        .fill(event.isTentative ? Color.clear : color)
                        .overlay {
                            if event.isTentative { Circle().strokeBorder(color, style: StrokeStyle(dash: [2, 2])) }
                        }
                        .frame(width: 10, height: 10)
                        .padding(.top, 5)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: details.title.isEmpty ? L10n.string("(No title)") : details.title)
                            .font(.body.weight(.medium))
                            .strikethrough(details.status == .cancelled)
                            .lineLimit(isStacked ? 4 : 2)
                        if !details.place.isEmpty {
                            Text(verbatim: details.place)
                                .font(.subheadline)
                                .foregroundStyle(Theme.secondaryText)
                                .lineLimit(isStacked ? 2 : 1)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .contentShape(Rectangle())
            .spokenEvent(event, calendar: model.calendar)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var hours: some View {
        let occurrence = event.occurrence
        if occurrence.allDayStart != nil {
            Text(ui: "All day").font(.subheadline)
        } else {
            let calendar = model.calendar
            let style = Date.FormatStyle(
                date: .omitted, time: .shortened, locale: calendar.locale ?? .current, calendar: calendar,
                timeZone: calendar.timeZone)
            let layout = isStacked
                ? AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
                : AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            layout {
                Text(verbatim: occurrence.start < day ? "…" : style.format(occurrence.start)).font(.subheadline)
                Text(verbatim: calendar.isDate(occurrence.end, inSameDayAs: day) ? style.format(occurrence.end) : "…")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
            }
            .monospacedDigit()
        }
    }
}
