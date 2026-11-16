// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightModel
import SwiftUI

/// The agenda: the coming days with events, each a section; today is always there, with "No
/// events" when it has none.
struct AgendaView: View {
    let app: AppModel
    let model: CalendarModel

    var body: some View {
        List {
            ForEach(model.days) { day in
                Section {
                    if day.isEmpty {
                        Text(ui: "No events").foregroundStyle(Theme.secondaryText)
                    }
                    ForEach(day.allDay + day.timed.map(\.event), id: \.occurrenceKey) { event in
                        AgendaRow(app: app, model: model, event: event, day: day.day)
                    }
                } header: {
                    Text(verbatim: AgendaView.title(day.day, model: model))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(model.isToday(day.day) ? Theme.accent : Theme.secondaryText)
                }
            }
        }
        .listStyle(.plain)
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

/// An event in a list: its hours (or All day), its calendar's colour, title and place.
struct AgendaRow: View {
    let app: AppModel
    let model: CalendarModel
    let event: CalendarEvent
    let day: Date

    var body: some View {
        let details = event.occurrence.details
        let color = Color(calendar: model.color(of: event.calendarID))
        Button { app.eventToShow = EventRequest(event) } label: {
            HStack(alignment: .top, spacing: 12) {
                hours.frame(width: 64, alignment: .leading)
                Circle()
                    .fill(event.isTentative ? Color.clear : color)
                    .overlay { if event.isTentative { Circle().strokeBorder(color, style: StrokeStyle(dash: [2, 2])) } }
                    .frame(width: 10, height: 10)
                    .padding(.top, 5)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: details.title.isEmpty ? L10n.string("(No title)") : details.title)
                        .font(.body.weight(.medium))
                        .strikethrough(details.status == .cancelled)
                        .lineLimit(2)
                    if !details.place.isEmpty {
                        Text(verbatim: details.place)
                            .font(.subheadline)
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
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
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: occurrence.start < day ? "…" : style.format(occurrence.start)).font(.subheadline)
                Text(verbatim: calendar.isDate(occurrence.end, inSameDayAs: day) ? style.format(occurrence.end) : "…")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
            }
            .monospacedDigit()
        }
    }
}
