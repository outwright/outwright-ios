// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightModel
import SwiftUI

/// The drawer's right column on the Calendar tab: which calendars are shown, each under its account
/// with a checkbox in its colour, and the subscribed calendars in a group of their own, where one is
/// added or opened to rename it. An account's calendar takes a colour of the owner's from its colour
/// menu, kept on the phone. A calendar with events the app could not read says how many, so none
/// vanishes unnoticed. With one account chosen in the rail, only its calendars are listed.
struct DrawerCalendars: View {
    let app: AppModel
    @Bindable var model: CalendarModel
    /// The account chosen in the rail; nil is all accounts.
    let account: AccountID?
    @State private var isAddingSubscription = false
    /// The subscribed calendar whose settings are open.
    @State private var opened: CalendarID?

    private var groups: [(account: Account, calendars: [CalendarInfo])] {
        model.calendarGroups.filter { account == nil || $0.account.id == account }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { model.shownCalendars = nil } label: {
                row(Text(ui: "All calendars"), color: nil, isChosen: model.shownCalendars == nil)
            }
            .buttonStyle(.plain)
            ForEach(groups, id: \.account.id) { group in
                SectionHeader(verbatim: group.account.displayName)
                    .padding(.top, 14).padding(.bottom, 4)
                ForEach(group.calendars) { cal in
                    HStack {
                        calendarRow(cal)
                        colorMenu(cal)
                    }
                }
            }
            if account == nil {
                SectionHeader("Subscribed calendars").padding(.top, 14).padding(.bottom, 4)
                ForEach(model.subscribedCalendars) { cal in
                    HStack {
                        calendarRow(cal)
                        Button { opened = cal.id } label: {
                            Image(systemName: Icons.details).foregroundStyle(Theme.accent)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(ui: "Calendar settings"))
                        .accessibilityIdentifier("calendars.subscriptionDetails")
                    }
                }
                Button {
                    isAddingSubscription = true
                } label: {
                    ModuleLabel("Add subscribed calendar", systemImage: Icons.add)
                        .font(.title3)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                .accessibilityIdentifier("calendars.addSubscription")
            }
        }
        .sheet(
            isPresented: Binding(get: { opened != nil }, set: { if !$0 { opened = nil } }),
            onDismiss: { app.openPending() },
            content: {
                NavigationStack {
                    if let id = opened, let held = model.app.subscriptions().first(where: { $0.id == id }) {
                        SubscriptionView(app: model.app, subscription: held) { model.reload() }
                    }
                }
            })
        .sheet(
            isPresented: $isAddingSubscription, onDismiss: { app.openPending() },
            content: {
                SubscriptionAddView(model: SubscriptionAddModel(app: model.app)) { model.added($0) }
            }
        )
        .closesForEvents(isOpen: isAddingSubscription || opened != nil, inDrawer: true) {
            isAddingSubscription = false
            opened = nil
        }
    }

    private func calendarRow(_ cal: CalendarInfo) -> some View {
        Button { toggle(cal) } label: {
            VStack(alignment: .leading, spacing: 2) {
                row(
                    Text(verbatim: cal.name), color: cal.color,
                    isChosen: model.shownCalendars?.contains(cal.id) ?? true)
                if let failure = model.subscriptionFailures[cal.id] {
                    failure.text
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.leading, 44)
                }
                if let refused = model.refusedCounts[cal.id] {
                    Text(ui: "\(refused) events could not be read")
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.leading, 44)
                }
            }
        }
        .buttonStyle(.plain)
    }

    /// A checkbox in the calendar's colour (the accent for All calendars) and its name.
    private func row(_ title: Text, color: Int?, isChosen: Bool) -> some View {
        HStack(spacing: 16) {
            Image(systemName: isChosen ? Icons.checkboxOn : Icons.checkboxOff)
                .font(.title3)
                .frame(width: 28)
                .foregroundStyle(color.map { Color(calendar: $0) } ?? Theme.accent)
            title.font(.title3).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }

    /// The palette's colours by name, and the calendar's own colour back.
    private func colorMenu(_ cal: CalendarInfo) -> some View {
        Menu {
            ForEach(Array(CalendarPalette.colors.enumerated()), id: \.offset) { index, shade in
                Button { model.setColor(shade, of: cal.id) } label: {
                    Label {
                        Text(ui: Self.colorName(index))
                    } icon: {
                        Image(systemName: cal.color == shade ? Icons.confirm : Icons.colorDot)
                            .foregroundStyle(Color(calendar: shade))
                    }
                }
            }
            Divider()
            Button { model.setColor(nil, of: cal.id) } label: { Text(ui: "Calendar's own colour") }
        } label: {
            Image(systemName: Icons.color)
                .foregroundStyle(Theme.secondaryText)
                .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel(Text(ui: "Colour"))
        .accessibilityIdentifier("calendars.color")
    }

    /// The palette's colours in order (`CalendarPalette.colors`).
    static func colorName(_ index: Int) -> LocalizedStringKey {
        switch index {
        case 0: "Blue"
        case 1: "Red"
        case 2: "Green"
        case 3: "Orange"
        case 4: "Purple"
        case 5: "Teal"
        case 6: "Pink"
        default: "Olive"
        }
    }

    /// Ticking the last unticked calendar is the same as all; unticking every one shows all again.
    private func toggle(_ cal: CalendarInfo) {
        let every = Set(model.everyCalendar.map(\.id))
        var shown = model.shownCalendars ?? every
        if shown.contains(cal.id) { shown.remove(cal.id) } else { shown.insert(cal.id) }
        model.shownCalendars = (shown.isEmpty || shown == every) ? nil : shown
    }
}
