// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightModel
import SwiftUI

/// The subscribed calendars, in Settings: published calendars read from their address, read-only,
/// belonging to no account. The add sheet belongs to the screen, not to this section: a section of
/// a list can be unloaded while it is off screen, and a sheet it presents closes with it.
struct SubscriptionsSection: View {
    let app: AppModel
    @Binding var isAdding: Bool
    /// Changes each time the add sheet closes, so the list is read again.
    let addsClosed: Int
    @State private var list: [CalendarSubscription] = []

    var body: some View {
        Section {
            ForEach(list) { held in
                NavigationLink {
                    SubscriptionView(app: app, subscription: held) { reload() }
                } label: {
                    SubscriptionRow(subscription: held)
                }
                .accessibilityIdentifier("subscription.row")
            }
            Button {
                isAdding = true
            } label: {
                Text(ui: "Add subscribed calendar")
            }
            .accessibilityIdentifier("subscription.add")
        } header: {
            Text(ui: "Subscribed calendars")
        } footer: {
            Text(ui: "A calendar someone publishes as an address (ICS or webcal), shown read-only.")
        }
        .onAppear { reload() }
        .onChange(of: addsClosed) { _, _ in reload() }
    }

    private func reload() {
        list = app.subscriptions()
    }
}

/// One subscription in a list: its colour, name, host, and when it was last fetched or why it failed.
struct SubscriptionRow: View {
    let subscription: CalendarSubscription

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(Color(calendar: subscription.calendar.color)).frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: subscription.calendar.name)
                Group {
                    if let failure = subscription.failure {
                        failure.text.foregroundStyle(Theme.delete)
                    } else if let fetched = subscription.fetchedAt {
                        Text(ui: "Updated \(fetched.formatted(.relative(presentation: .named)))")
                    } else {
                        Text(verbatim: subscription.host)
                    }
                }
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
            }
        }
    }
}

extension SubscriptionFailure {
    /// What the owner is told.
    var text: Text {
        switch self {
        case .unreachable: Text(ui: "The calendar's server can't be reached.")
        case .unshared: Text(ui: "The calendar is no longer shared.")
        case .unpublished: Text(ui: "The calendar is no longer published.")
        case .notCalendar: Text(ui: "The address doesn't give a calendar.")
        case .tooLarge: Text(ui: "The calendar is too large.")
        case .server: Text(ui: "The calendar's server gave an error.")
        case .noAddress: Text(ui: "The calendar's address is missing. Remove it and add it again.")
        }
    }
}

extension SubscriptionAddError {
    var text: Text {
        switch self {
        case .badAddress: Text(ui: "Enter an address that starts with https:// or webcal://.")
        case let .failed(failure): failure.text
        case .keychain: Text(ui: "The address couldn't be kept in the keychain.")
        case .store: Text(ui: "The calendar couldn't be saved on this phone.")
        }
    }
}
