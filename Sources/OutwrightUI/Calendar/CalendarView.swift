// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightModel
import SwiftUI

/// The Calendar tab: the header, the chosen view, and the floating New event button. Everything is
/// read from the store, so today's events are there the moment the tab opens.
struct CalendarView: View {
    let app: AppModel
    @Bindable var model: CalendarModel
    @State private var isFiltering = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        VStack(spacing: 0) {
            CalendarHeader(model: model, isFiltering: $isFiltering)
            if model.failed {
                ProblemBanner(text: L10n.string("The calendar couldn't be read. Try again."))
            }
            content
                .frame(maxHeight: .infinity)
                .simultaneousGesture(swipe)
        }
        .background(Theme.background)
        .safeAreaInset(edge: .bottom) { newEvent }
        .task { await model.observe() }
        .task { await app.calendarTabOpened() }
        // Back in front, or past midnight: today is shown again, and the grid goes back to now.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.sceneBecameActive() }
        }
        .onChange(of: app.clockChanges) { _, _ in model.reload() }
        // On its side the phone shows the week; upright, the view chosen there.
        .onChange(of: verticalSizeClass, initial: true) { _, size in model.isLandscape = size == .compact }
        // The first calendar of the account's own arrived while the tab is open: the reminders' question
        // is asked now (a subscribed calendar alone rings nothing).
        .onChange(of: model.canAddEvents) { _, has in
            if has, app.selectedTab == .calendar { Task { await app.calendarTabOpened() } }
        }
        .sheet(
            isPresented: $isFiltering, onDismiss: { app.openPending() },
            content: { CalendarFilterSheet(model: model).presentationDetents([.medium, .large]) })
        .closesForEvents(isOpen: isFiltering) { isFiltering = false }
    }

    @ViewBuilder private var content: some View {
        if model.showsWeek {
            DayGridView(app: app, model: model)
        } else {
            portraitContent
        }
    }

    @ViewBuilder private var portraitContent: some View {
        switch model.mode {
        case .agenda: AgendaView(app: app, model: model)
        case .day, .threeDay: DayGridView(app: app, model: model)
        case .month: MonthView(app: app, model: model)
        }
    }

    /// A horizontal swipe moves by the view's step: a day in Day and 3 Day, a week in landscape.
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 30)
            .onEnded { value in
                let width = value.translation.width
                guard abs(width) > 60, abs(width) > abs(value.translation.height) * 1.5 else { return }
                withAnimation(.snappy) { model.step(width < 0 ? 1 : -1) }
            }
    }

    /// New event opens the editor on the day in view, at the next whole hour.
    private var newEvent: some View {
        HStack {
            Spacer()
            Button { app.showNewEvent(day: model.anchorDay) } label: {
                Image(systemName: Icons.newEvent)
                    .font(.title2)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 14)
            }
            .disabled(!model.canAddEvents)
            .glassEffect(.regular.interactive(), in: .capsule)
            .accessibilityLabel(Text(ui: "New event"))
            .accessibilityIdentifier("calendar.newEvent")
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}

extension EventRequest {
    /// The details of this occurrence of the event.
    init(_ event: CalendarEvent) {
        self.init(event: event.id, occurrence: event.occurrence.recurrenceID)
    }
}

extension Color {
    /// A calendar's colour (0xRRGGBB).
    init(calendar color: Int) {
        self.init(hex: UInt32(truncatingIfNeeded: color & 0xFF_FFFF))
    }
}

extension View {
    /// One VoiceOver element for an event: title, hours and state as the label, the place as the value.
    func spokenEvent(_ event: CalendarEvent, calendar: Calendar) -> some View {
        accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: EventText.spoken(event, in: calendar)))
            .accessibilityValue(Text(verbatim: event.occurrence.details.place))
    }
}
