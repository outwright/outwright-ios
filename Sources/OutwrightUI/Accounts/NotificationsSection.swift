// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightModel
import SwiftUI

/// The account's Notifications switch, and under it the build's alternative while push from the
/// server is not on or the account uses it. Renders only: the account's form owns and loads the model.
struct NotificationsSection: View {
    let account: Account
    let model: NotificationsToggleModel
    let alternative: (any PushAlternative)?
    /// Where push is not included, what it says under the switch and links to.
    let offering: (any Offering)?

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { model.isOn }, set: { isOn in Task { await model.set(isOn) } })) {
                Text(ui: "Notifications")
            }
            .disabled(model.isWorking)
            .accessibilityIdentifier("settings.notifications")
            if model.showsAlternative, let alternative {
                alternative.row(for: account)
            }
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                NotificationsStatus(model: model)
                if let offering, !model.pushIncluded {
                    offering.note(for: .push)
                    NavigationLink(destination: offering.page()) { offering.linkTitle() }
                        .accessibilityIdentifier("settings.notifications.offering")
                }
            }
        }
    }
}

/// What the Notifications switch says under it: the last thing that went wrong, or what the notices are.
struct NotificationsStatus: View {
    let model: NotificationsToggleModel
    @AppStorage(SettingsKeys.backgroundRefresh) private var backgroundRefresh = true

    @ViewBuilder var body: some View {
        switch model.message {
        case .permissionDenied:
            Text(ui: "Outwright isn't allowed to notify. Allow it in the Settings app.")
        case .limit:
            Text(ui: "Notifications are already on for 10 mailboxes. Switch them off for one first.")
        case .failed:
            Text(ui: "Notifications couldn't be changed on the server. Try again later.")
        case .notChanged:
            Text(ui: "Notifications couldn't be changed. Try again.")
        case .serverRefused:
            Text(ui: "The mail server refused to set up push.")
        case let .notSetUp(guide):
            VStack(alignment: .leading, spacing: 4) {
                Text(ui: "This mail server is not set up for push. Its owner can set it up:")
                if let guide {
                    Link(destination: guide) { Text(ui: "How to set up push") }
                }
            }
        case .dropped:
            Text(ui: "Push stopped: the address it came through is gone.")
        case nil:
            // Without push included, on or off, notices come from background refresh.
            if (model.isLocal || !model.pushIncluded) && !backgroundRefresh {
                Text(ui: "Notifications need background refresh, which is off in Settings.")
            } else if model.isLocal || !model.pushIncluded {
                Text(ui: "New mail is announced when iOS lets Outwright check, which can be late.")
            } else {
                Text(ui: "New mail is announced with its sender and subject.")
            }
        }
    }
}
