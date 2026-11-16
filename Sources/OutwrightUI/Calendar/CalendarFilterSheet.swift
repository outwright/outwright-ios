// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightModel
import SwiftUI

/// Which calendars are shown: all, or the ones ticked, each under its account in its colour, and the
/// subscribed calendars in a group of their own, where one is added or opened to rename it. A
/// calendar with events the app could not read says how many, so none vanishes unnoticed.
struct CalendarFilterSheet: View {
    @Bindable var model: CalendarModel
    @State private var isAddingSubscription = false
    /// The subscribed calendar whose settings are open.
    @State private var opened: CalendarID?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Button { model.shownCalendars = nil } label: {
                    check(Text(ui: "All calendars"), color: nil, isChosen: model.shownCalendars == nil)
                }
                ForEach(model.calendarGroups, id: \.account.id) { group in
                    Section(group.account.displayName) {
                        ForEach(group.calendars) { cal in row(cal) }
                    }
                }
                Section {
                    ForEach(model.subscribedCalendars) { cal in
                        HStack {
                            row(cal)
                            Button { opened = cal.id } label: {
                                Image(systemName: Icons.details).foregroundStyle(Theme.accent)
                            }
                            .accessibilityLabel(Text(ui: "Calendar settings"))
                            .accessibilityIdentifier("calendars.subscriptionDetails")
                        }
                        .buttonStyle(.borderless)
                    }
                    Button {
                        isAddingSubscription = true
                    } label: {
                        ModuleLabel("Add subscribed calendar", systemImage: Icons.add)
                    }
                    .foregroundStyle(Theme.accent)
                    .accessibilityIdentifier("calendars.addSubscription")
                } header: {
                    Text(ui: "Subscribed calendars")
                }
            }
            .foregroundStyle(.primary)
            .navigationTitle(Text(ui: "Calendars"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Text(ui: "Done") }
                }
            }
            .navigationDestination(item: $opened) { id in
                if let held = model.app.subscriptions().first(where: { $0.id == id }) {
                    SubscriptionView(app: model.app, subscription: held) { model.reload() }
                }
            }
            .sheet(
                isPresented: $isAddingSubscription,
                content: {
                    SubscriptionAddView(model: SubscriptionAddModel(app: model.app)) { model.added($0) }
                })
        }
    }

    private func row(_ cal: CalendarInfo) -> some View {
        Button { toggle(cal) } label: {
            VStack(alignment: .leading, spacing: 2) {
                check(
                    Text(verbatim: cal.name), color: cal.color,
                    isChosen: model.shownCalendars?.contains(cal.id) ?? true)
                if let failure = model.subscriptionFailures[cal.id] {
                    failure.text
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.leading, 22)
                }
                if let refused = model.refusedCounts[cal.id] {
                    Text(ui: "\(refused) events could not be read")
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.leading, 22)
                }
            }
        }
    }

    private func check(_ title: Text, color: Int?, isChosen: Bool) -> some View {
        HStack(spacing: 10) {
            if let color { Circle().fill(Color(calendar: color)).frame(width: 12, height: 12) }
            title
            Spacer()
            if isChosen { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
        }
        .contentShape(Rectangle())
    }

    /// Ticking the last unticked calendar is the same as all; unticking every one shows all again.
    private func toggle(_ cal: CalendarInfo) {
        let every = Set(model.everyCalendar.map(\.id))
        var shown = model.shownCalendars ?? every
        if shown.contains(cal.id) { shown.remove(cal.id) } else { shown.insert(cal.id) }
        model.shownCalendars = (shown.isEmpty || shown == every) ? nil : shown
    }
}
