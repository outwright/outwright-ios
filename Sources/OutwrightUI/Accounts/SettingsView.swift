// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightModel
import SwiftUI

/// Settings: the accounts (name, signature, remove), Focused Inbox, the swipes, the default calendar,
/// the subscribed calendars, about.
struct SettingsView: View {
    let app: AppModel
    @AppStorage(SettingsKeys.focusedInbox) private var focusedInbox = true
    @AppStorage(SettingsKeys.backgroundRefresh) private var backgroundRefresh = true
    @Environment(\.dismiss) private var dismiss
    /// The account shown over the list; settings opened from a sync problem starts at it.
    @State private var path: [AccountID]
    /// Send diagnostics was tapped and the report is being built.
    @State private var isPreparingDiagnostics = false
    /// Add subscribed calendar is open; how many times it has closed.
    @State private var isAddingSubscription = false
    @State private var subscriptionAddsClosed = 0

    init(app: AppModel) {
        self.app = app
        _path = State(initialValue: app.settingsAccount.map { [$0] } ?? [])
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    ForEach(app.accounts) { account in
                        NavigationLink(value: account.id) {
                            HStack(spacing: 12) {
                                Avatar(
                                    name: account.displayName, email: account.email, size: 36,
                                    colorIndex: account.colorIndex)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(account.displayName)
                                    Text(account.email)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    if app.isUnavailable(account) {
                                        Text(ui: "Not available in this version")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    Button {
                        app.addsAccountAfterSettings = true
                        dismiss()
                    } label: {
                        ModuleLabel("Add account", systemImage: Icons.add)
                    }
                } header: {
                    Text(ui: "Accounts")
                }
                Section {
                    Toggle(isOn: $focusedInbox) { Text(ui: "Focused Inbox") }
                        .accessibilityIdentifier("settings.focusedInbox")
                    LabeledContent {
                        Text(ui: "Delete")
                    } label: {
                        Text(ui: "Swipe left")
                    }
                    LabeledContent {
                        Text(ui: "Flag")
                    } label: {
                        Text(ui: "Swipe right")
                    }
                } header: {
                    Text(ui: "Mail")
                } footer: {
                    Text(ui: "Focused Inbox sorts mail from people apart from newsletters and the like.")
                }
                Section {
                    Toggle(isOn: $backgroundRefresh) { Text(ui: "Background refresh") }
                        .accessibilityIdentifier("settings.backgroundRefresh")
                } footer: {
                    Text(ui: "Fetches new mail now and then while Outwright is closed. iOS decides when.")
                }
                ForEach(Array(app.modules.settingsSections.enumerated()), id: \.offset) { _, module in
                    module.section()
                }
                DefaultCalendarSection(app: app)
                SubscriptionsSection(
                    app: app, isAdding: $isAddingSubscription, addsClosed: subscriptionAddsClosed)
                Section {
                    LabeledContent {
                        Text(verbatim: Self.version)
                    } label: {
                        Text(ui: "Version")
                    }
                    Text(
                        ui: """
                            Open source under the MIT or Apache 2.0 licence. \
                            Your mail stays on this phone and your own servers.
                            """)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text(ui: "About")
                }
                // Compose needs an account to send from.
                if !app.accounts.isEmpty {
                    Section {
                        Button {
                            isPreparingDiagnostics = true
                            Task {
                                let report = await app.diagnosticsReport()
                                isPreparingDiagnostics = false
                                if app.isShowingSettings {
                                    // Opens once settings has gone: a second sheet can't show during a dismissal.
                                    app.diagnosticsAfterSettings = report
                                    dismiss()
                                } else {
                                    // Settings was closed while the report was made.
                                    app.compose(.diagnostics(report))
                                }
                            }
                        } label: {
                            if isPreparingDiagnostics {
                                HStack(spacing: 8) {
                                    ProgressView()
                                    Text(ui: "Preparing the report…")
                                }
                            } else {
                                Text(ui: "Send diagnostics")
                            }
                        }
                        .disabled(isPreparingDiagnostics)
                        .accessibilityIdentifier("settings.sendDiagnostics")
                    } footer: {
                        Text(
                            ui: """
                                Opens a message with a report you can read before sending. \
                                It holds no mail, addresses or server names.
                                """)
                    }
                }
            }
            .navigationTitle(Text(ui: "Settings"))
            .sheet(
                isPresented: $isAddingSubscription, onDismiss: { subscriptionAddsClosed &+= 1 },
                content: { SubscriptionAddView(model: SubscriptionAddModel(app: app)) })
            .navigationDestination(for: AccountID.self) { id in
                if let account = app.accounts.first(where: { $0.id == id }) {
                    AccountSettingsView(app: app, account: account)
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Text(ui: "Done") }
                }
            }
        }
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.1"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }
}

/// The calendar new events go to, among the writable ones; shown once there is one.
struct DefaultCalendarSection: View {
    let app: AppModel
    @State private var chosen: CalendarID?
    @State private var failed = false

    private var calendars: [CalendarInfo] {
        ((try? app.store.allCalendars()) ?? []).filter { !$0.isReadOnly }
    }

    var body: some View {
        let calendars = calendars
        if !calendars.isEmpty {
            Section {
                Picker(selection: selection) {
                    ForEach(calendars) { cal in
                        Text(verbatim: label(cal, among: calendars)).tag(Optional(cal.id))
                    }
                } label: {
                    Text(ui: "Default calendar")
                }
                .accessibilityIdentifier("settings.defaultCalendar")
            } header: {
                Text(ui: "Calendar")
            } footer: {
                if failed {
                    Text(ui: "The change couldn't be saved on this phone.").foregroundStyle(Theme.delete)
                } else {
                    Text(ui: "New events go to this calendar.")
                }
            }
            .onAppear { chosen = app.defaultCalendar?.id }
        }
    }

    private var selection: Binding<CalendarID?> {
        Binding { chosen ?? app.defaultCalendar?.id } set: { id in
            guard let id else { return }
            do {
                try app.setDefaultCalendar(id)
                chosen = id
                failed = false
            } catch {
                failed = true
            }
        }
    }

    /// The calendar's name, with its account's when another account has a calendar too.
    private func label(_ cal: CalendarInfo, among calendars: [CalendarInfo]) -> String {
        guard Set(calendars.map(\.accountID)).count > 1,
            let account = app.accounts.first(where: { $0.id == cal.accountID })
        else { return cal.name }
        return cal.name + " · " + account.displayName
    }
}

/// Keys of the settings kept in `UserDefaults` (nothing secret).
public enum SettingsKeys {
    /// Bool, on unless turned off: the Inbox is split into Focused and Other.
    public static let focusedInbox = "focusedInbox"
    /// Bool, on unless turned off: iOS is asked to wake the app now and then to fetch new mail.
    public static let backgroundRefresh = "backgroundRefresh"
}
