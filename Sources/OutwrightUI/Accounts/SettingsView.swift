// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightModel
import SwiftUI
import UniformTypeIdentifiers

/// Settings: the accounts (name, signature, remove, add, the default one), Focused Inbox, the swipes,
/// notifications per account, backing up and moving the setup, the default calendar, the subscribed
/// calendars, what the build adds, about.
struct SettingsView: View {
    let app: AppModel
    @AppStorage(SettingsKeys.focusedInbox) private var focusedInbox = true
    @AppStorage(SettingsKeys.backgroundRefresh) private var backgroundRefresh = true
    /// Swipe right is a swipe from the leading edge of a row, swipe left from the trailing one.
    @AppStorage(SettingsKeys.swipeLeading) private var swipeRight = SwipeAction.leadingDefault.rawValue
    @AppStorage(SettingsKeys.swipeTrailing) private var swipeLeft = SwipeAction.trailingDefault.rawValue
    @AppStorage(SettingsKeys.defaultAccount) private var defaultAccount = ""
    @Environment(\.dismiss) private var dismiss
    /// The account shown over the list; settings opened from a sync problem starts at it.
    @State private var path: [AccountID]
    /// Send diagnostics was tapped and the report is being built.
    @State private var isPreparingDiagnostics = false
    /// Add subscribed calendar is open; how many times it has closed.
    @State private var isAddingSubscription = false
    @State private var subscriptionAddsClosed = 0
    /// Restore from a file: the picker is open, and the file picked.
    @State private var isPickingSetup = false
    @State private var restoringSetup: SetupFileRequest?
    /// Add account is pushed on Settings' own stack, so closing it lands back here.
    @State private var isAddingAccount = false

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
                                .attentionDot(!app.attention(for: account.id).isEmpty, ring: Theme.groupedRow)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(account.displayName)
                                    Text(account.email)
                                        .font(.subheadline)
                                        .foregroundStyle(Theme.secondaryText)
                                    if app.isUnavailable(account) {
                                        Text(ui: "Not available in this version")
                                            .font(.caption)
                                            .foregroundStyle(Theme.secondaryText)
                                    }
                                }
                            }
                        }
                    }
                    Button {
                        isAddingAccount = true
                    } label: {
                        ModuleLabel("Add account", systemImage: Icons.add)
                    }
                    .accessibilityIdentifier("settings.addAccount")
                    if app.accounts.count > 1 {
                        Picker(selection: defaultAccountSelection) {
                            ForEach(app.accounts) { account in
                                Text(verbatim: account.displayName).tag(account.id.raw.uuidString)
                            }
                        } label: {
                            Text(ui: "Default account")
                        }
                        .accessibilityIdentifier("settings.defaultAccount")
                    }
                } header: {
                    Text(ui: "Accounts")
                } footer: {
                    if app.accounts.count > 1 {
                        Text(ui: "New mail is sent from the default account when no account is open.")
                    }
                }
                Section {
                    Toggle(isOn: $focusedInbox) { Text(ui: "Focused Inbox") }
                        .accessibilityIdentifier("settings.focusedInbox")
                        .onChange(of: focusedInbox) { app.showBadge() }
                    Picker(selection: $swipeRight) {
                        ForEach(SwipeAction.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                    } label: {
                        Text(ui: "Swipe right")
                    }
                    .accessibilityIdentifier("settings.swipeRight")
                    Picker(selection: $swipeLeft) {
                        ForEach(SwipeAction.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                    } label: {
                        Text(ui: "Swipe left")
                    }
                    .accessibilityIdentifier("settings.swipeLeft")
                } header: {
                    Text(ui: "Mail")
                } footer: {
                    Text(ui: "Focused Inbox sorts mail from people apart from newsletters and the like.")
                }
                NotificationsSettingsSection(app: app)
                SetupSection(app: app, isPicking: $isPickingSetup)
                Section {
                    Toggle(isOn: $backgroundRefresh) { Text(ui: "Background refresh") }
                        .accessibilityIdentifier("settings.backgroundRefresh")
                } footer: {
                    Text(ui: "Fetches new mail now and then while Outwright is closed. iOS decides when.")
                }
                DefaultCalendarSection(app: app)
                SubscriptionsSection(
                    app: app, isAdding: $isAddingSubscription, addsClosed: subscriptionAddsClosed)
                // What a build adds (Plus) comes last of the settings, above the About.
                ForEach(Array(app.modules.settingsSections.enumerated()), id: \.offset) { _, module in
                    module.section()
                }
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
                        .foregroundStyle(Theme.secondaryText)
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
            .inlineNavigationTitle()
            .sheet(
                isPresented: $isAddingSubscription, onDismiss: { subscriptionAddsClosed &+= 1 },
                content: { SubscriptionAddView(model: SubscriptionAddModel(app: app)) })
            .fileImporter(isPresented: $isPickingSetup, allowedContentTypes: [.outwrightSetup, .data]) { result in
                guard case .success(let url) = result else { return }
                restoringSetup = SetupFileRequest(url: url)
            }
            .sheet(item: $restoringSetup) { RestoreSetupView(app: app, url: $0.url) }
            .navigationDestination(isPresented: $isAddingAccount) {
                AddAccountView(app: app, placement: .pushed)
            }
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

    /// The default account as the picker shows it: the first one until another is chosen, or when the
    /// chosen one has been removed.
    private var defaultAccountSelection: Binding<String> {
        Binding {
            let stored = app.accounts.first { $0.id.raw.uuidString == defaultAccount }
            return (stored ?? app.accounts.first)?.id.raw.uuidString ?? ""
        } set: {
            defaultAccount = $0
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
    /// String (a `SwipeAction`'s raw value): what a swipe from the left edge of a mail row does; Flag until chosen.
    public static let swipeLeading = "swipeLeading"
    /// The same for a swipe from the right edge; Delete until chosen.
    public static let swipeTrailing = "swipeTrailing"
    /// String (an account's id): who new mail is from when no account is in view; the first account until chosen.
    public static let defaultAccount = "defaultAccount"
    /// String (a `CalendarMode`'s raw value): the view the calendar was last left in; 3 Day, or Week on a
    /// wide screen, until chosen.
    public static let calendarMode = "calendarMode"
    /// String (a `WeekMode`'s raw value): the week a phone on its side shows; Week until chosen.
    public static let calendarWeekMode = "calendarWeekMode"
    /// [Int64] (calendar ids): the calendars shown; absent means every calendar.
    public static let shownCalendars = "shownCalendars"
    /// [String: Int] (a calendar id's raw value as text, 0xRRGGBB): the colours the owner chose for
    /// calendars over their own (`CalendarColors`).
    public static let calendarColors = "calendarColors"
    /// Data (a `DoNotDisturb`), kept in the app group's defaults so the notification extension reads it.
    public static let doNotDisturb = DoNotDisturb.defaultsKey
}
