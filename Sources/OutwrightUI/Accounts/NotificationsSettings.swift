// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightModel
import SwiftUI

/// Settings › Notifications: every account with its own switch, the same one as in the account's
/// settings.
struct NotificationsSettingsSection: View {
    let app: AppModel

    var body: some View {
        if !app.accounts.isEmpty {
            Section {
                ForEach(app.accounts) { account in
                    AccountNotificationsRow(app: app, account: account)
                }
            } header: {
                Text(ui: "Notifications")
            } footer: {
                if let offering = app.modules.offering, !(offering.includes(.push)) {
                    VStack(alignment: .leading, spacing: 6) {
                        offering.note(for: .push)
                        NavigationLink(destination: offering.page()) { offering.linkTitle() }
                            .accessibilityIdentifier("settings.notificationsOffering")
                    }
                } else {
                    Text(ui: "New mail is announced with its sender and subject.")
                }
            }
        }
    }
}

/// One account's switch, with what went wrong under it.
private struct AccountNotificationsRow: View {
    let app: AppModel
    let account: Account
    @State private var model: NotificationsToggleModel

    init(app: AppModel, account: Account) {
        self.app = app
        self.account = account
        let reminders = app.sync.reminders
        _model = State(
            initialValue: NotificationsToggleModel(
                account: account, support: app.push,
                local: StoreLocalNotifying(store: app.store) { await reminders.requestAuthorization() },
                pushIncluded: app.modules.offering?.includes(.push) ?? true,
                alternative: app.modules.pushAlternative))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(get: { model.isOn }, set: { isOn in Task { await model.set(isOn) } })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.displayName)
                    Text(account.email)
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            .disabled(model.isWorking)
            .accessibilityIdentifier("settings.notifications.\(account.id.raw.uuidString)")
            if model.message != nil {
                NotificationsStatus(model: model)
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
            } else if model.showsAlternative, model.missesPush, let alternative = app.modules.pushAlternative {
                Text(verbatim: alternative.note(for: account))
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .task { await model.load() }
    }
}
