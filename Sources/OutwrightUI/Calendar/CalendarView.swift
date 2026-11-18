// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightModel
import SwiftUI

/// The Calendar tab: the header, the chosen view, and the floating New event button. Everything is
/// read from the store, so today's events are there the moment the tab opens.
struct CalendarView: View {
    let app: AppModel
    @Bindable var model: CalendarModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var cannotAdd = false
    @State private var isAddingSubscription = false

    var body: some View {
        VStack(spacing: 0) {
            CalendarHeader(app: app, model: model)
            AttentionBanners(app: app)
            if model.failed {
                ProblemBanner(text: L10n.string("The calendar couldn't be read. Try again."))
            }
            if app.accounts.isEmpty {
                NoAccountView(app: app, icon: Icons.calendar, message: "Add an account to see your calendar.")
                    .frame(maxHeight: .infinity)
            } else if !model.hasCalendars {
                noCalendars.frame(maxHeight: .infinity)
            } else {
                above
                content
                    .frame(maxHeight: .infinity)
                    .simultaneousGesture(swipe, isEnabled: model.showsWeek || model.mode == .month)
                    // A pull on the agenda, the month or a day syncs the calendars again.
                    .refreshable { await app.pullCalendars() }
            }
        }
        .background(Theme.background)
        .safeAreaInset(edge: .bottom) { newEvent }
        .task { await model.observe() }
        // A restored setup's view shows without a relaunch.
        .task { await model.observeSettings() }
        // Back in front, or past midnight: today is shown again, and the grid goes back to now.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.sceneBecameActive() }
        }
        .onChange(of: app.clockChanges) { _, _ in model.reload() }
        // On its side the phone shows the week; upright, the view chosen there.
        .onChange(of: verticalSizeClass, initial: true) { _, size in model.isLandscape = size == .compact }
        // A wide screen offers the weeks too.
        .onChange(of: horizontalSizeClass, initial: true) { _, size in model.isRegularWidth = size == .regular }
        .alert(Text(ui: "No calendar takes new events"), isPresented: $cannotAdd) {
            Button(role: .cancel) {} label: { Text(ui: "OK") }
        } message: {
            Text(ui: "Add an account with a calendar to add events. Subscribed calendars can't be changed.")
        }
        .sheet(
            isPresented: $isAddingSubscription, onDismiss: { app.openPending() },
            content: {
                SubscriptionAddView(model: SubscriptionAddModel(app: app)) { model.added($0) }
            })
        .closesForEvents(isOpen: isAddingSubscription) { isAddingSubscription = false }
    }

    /// Under the title: the month when it is open, else the week in Day, 3 Day and Agenda.
    @ViewBuilder private var above: some View {
        if model.showsMiniMonth {
            // Seven days must fit across the phone, so neither grows past the largest standard size.
            MiniMonth(model: model)
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .transition(.move(edge: .top).combined(with: .opacity))
            Rectangle().fill(Theme.separator).frame(height: 1)
        } else if !model.showsWeek, model.mode != .month {
            WeekStrip(model: model).dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            Rectangle().fill(Theme.separator).frame(height: 1)
        }
    }

    /// An account, but no calendar to show: where one comes from.
    private var noCalendars: some View {
        ContentUnavailableView {
            Label { Text(ui: "No calendars") } icon: { Image(systemName: Icons.calendar) }
        } description: {
            Text(ui: "Add an account that has a calendar, or subscribe to a published one.")
        } actions: {
            Button { app.isAddingAccount = true } label: { Text(ui: "Add account") }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
            Button { isAddingSubscription = true } label: { Text(ui: "Add subscribed calendar") }
                .tint(Theme.accent)
        }
    }

    @ViewBuilder private var content: some View {
        if model.showsWeek {
            DayGridView(app: app, model: model, addEvent: addEvent)
        } else {
            portraitContent
        }
    }

    @ViewBuilder private var portraitContent: some View {
        switch model.mode {
        case .agenda: AgendaView(app: app, model: model)
        case .day, .threeDay, .week, .workWeek: DayGridView(app: app, model: model, addEvent: addEvent)
        case .month: MonthView(app: app, model: model)
        }
    }

    /// A horizontal swipe moves the weeks by a week and Month by a month; Day and 3 Day page under the
    /// finger, and the agenda scrolls.
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 30)
            .onEnded { value in
                let width = value.translation.width
                guard abs(width) > 60, abs(width) > abs(value.translation.height) * 1.5 else { return }
                withAnimation(.snappy) { model.step(width < 0 ? 1 : -1) }
            }
    }

    /// A slot tapped in the hour grid: a new event at its time, or why there can't be one.
    private func addEvent(at start: Date) {
        if model.canAddEvents { app.showNewEvent(start: start) } else { cannotAdd = true }
    }

    /// New event opens the editor on the day in view, at the next half hour; with no calendar that
    /// takes events, it says why.
    private var newEvent: some View {
        HStack {
            Spacer()
            Button {
                if model.canAddEvents { app.showNewEvent(day: model.anchorDay) } else { cannotAdd = true }
            } label: {
                Image(systemName: Icons.newEvent)
                    .font(.title2)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 14)
            }
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
