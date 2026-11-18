// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightModel
import SwiftUI

/// One account: what is wrong with it first, then its sign-in, name, signature, notifications, contacts,
/// calendar and the modules' sections, its servers on a page of their own, and removing it.
struct AccountSettingsView: View {
    let app: AppModel
    @State var account: Account
    @State private var isConfirmingRemoval = false
    @State private var failed = false
    @State private var isRemoved = false
    @State private var isRemoving = false
    @State private var newPassword = ""
    @State private var isCheckingPassword = false
    @State private var passwordResult: PasswordResult?
    @State private var unsent = UnsentWork(changes: 0, messages: 0)
    @State var isChangingPhoneCopy = false
    @State var contactsResult: ContactsResult?
    /// Unsent contact changes that turning the contacts off would lose, while asking.
    @State var unsentContacts = 0
    @State var isConfirmingCardDAVOff = false
    /// The same for the calendar (see `+Calendar`).
    @State var unsentEvents = 0
    @State var isConfirmingCalDAVOff = false
    @State var calendarsNotSaved = false
    /// A sign-in or password problem brought the owner here: the password field is ready for it.
    @FocusState private var passwordFocused: Bool
    /// The Notifications switch; loaded by the form, which is always there.
    @State private var notifications: NotificationsToggleModel
    @Environment(\.dismiss) var dismiss

    private var passwordSection: some View {
        Section {
            SecureField(text: $newPassword) { Text(ui: "New password") }
                .textContentType(.password)
                .focused($passwordFocused)
            Button {
                changePassword()
            } label: {
                Text(ui: "Change password")
            }
            .disabled(newPassword.isEmpty || isCheckingPassword)
        } header: {
            Text(ui: "Password")
        } footer: {
            Text(
                ui: """
                    The new password is checked with both servers and kept in the keychain only when \
                    both accept it.
                    """)
        }
    }

    init(app: AppModel, account: Account) {
        self.app = app
        _account = State(initialValue: account)
        let reminders = app.sync.reminders
        _notifications = State(
            initialValue: NotificationsToggleModel(
                account: account, support: app.push,
                local: StoreLocalNotifying(store: app.store) { await reminders.requestAuthorization() },
                pushIncluded: app.modules.offering?.includes(.push) ?? true,
                alternative: app.modules.pushAlternative))
    }

    /// The account as stored now: the contact and calendar settings change behind this screen's copy.
    var stored: Account {
        app.accounts.first { $0.id == account.id } ?? account
    }

    var body: some View {
        Form {
            if app.isUnavailable(account) {
                unavailableSection
            }
            problemsSection
            if account.auth == .oauth {
                providerSignInSection
            }
            if account.auth == .password {
                passwordSection
            }
            Section {
                TextField(text: $account.displayName) { Text(ui: "Your name") }
            } header: {
                Text(ui: "Name")
            } footer: {
                Text(account.email)
            }
            Section {
                TextEditor(text: $account.signature)
                    .frame(minHeight: 90)
            } header: {
                Text(ui: "Signature")
            } footer: {
                Text(ui: "Added under every message you write from this account.")
            }
            NotificationsSection(
                account: account, model: notifications, alternative: app.modules.pushAlternative,
                offering: app.modules.offering)
            contactsSection
            if account.calendarVia == .calDAV {
                calendarSection
            }
            ForEach(Array(app.modules.accountSections.enumerated()), id: \.offset) { _, module in
                module.section(for: account)
            }
            Section {
                NavigationLink {
                    ServerSettingsView(app: app, account: account)
                } label: {
                    Text(ui: "Server settings")
                }
                .accessibilityIdentifier("account.servers")
            }
            Section {
                Button(role: .destructive) {
                    unsent = app.unsentWork(of: account.id)
                    isConfirmingRemoval = true
                } label: {
                    Text(ui: "Remove account")
                }
                .disabled(isRemoving)
            }
        }
        .navigationTitle(Text(account.email))
        .inlineNavigationTitle()
        .task { await notifications.load() }
        .task {
            guard account.auth == .password, app.asksForPassword(account.id) else { return }
            // Once the page has come in: a field focused while it is pushed loses its keyboard.
            try? await Task.sleep(for: .milliseconds(600))
            passwordFocused = true
        }
        .onDisappear {
            // A removed account is not saved again.
            if !isRemoved {
                try? app.updateAccount(account)
            }
        }
        .confirmationDialog(
            unsent.isEmpty
                ? Text(ui: "Remove this account from Outwright? Its mail stays on the server.")
                : Text(
                    ui: """
                        Unsent messages: \(unsent.messages). Changes the server hasn't got yet: \(unsent.changes). \
                        Removing the account now loses them.
                        """),
            isPresented: $isConfirmingRemoval, titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                guard !isRemoving else { return }
                isRemoving = true
                Task {
                    defer { isRemoving = false }
                    do {
                        try await app.removeAccount(account.id)
                        isRemoved = true
                        dismiss()
                    } catch {
                        failed = true
                    }
                }
            } label: {
                Text(ui: "Remove account")
            }
        }
        .alert(Text(ui: "The account could not be removed."), isPresented: $failed) {
            Button { failed = false } label: { Text(ui: "OK") }
        }
        .alert(item: $passwordResult) { result in
            switch result {
            case .changed: Alert(title: Text(ui: "The password was changed."))
            case .refused: Alert(title: Text(ui: "The servers didn't accept the password. Nothing was changed."))
            case .keychain: Alert(title: Text(ui: "The password couldn't be kept in the keychain."))
            }
        }
    }
}

extension AccountSettingsView {
    /// What is wrong with the account, first: a message that wasn't sent opens Drafts; the rest is put
    /// right on this page.
    @ViewBuilder private var problemsSection: some View {
        let items = app.attention(for: account.id)
        if !items.isEmpty {
            Section {
                ForEach(items, id: \.self) { item in
                    if item.action == .drafts {
                        Button { app.act(on: item) } label: { problemRow(item) }
                            .accessibilityHint(Text(ui: "Opens the account's Drafts"))
                    } else {
                        problemRow(item)
                    }
                }
            }
        }
    }

    private func problemRow(_ item: AttentionItem) -> some View {
        Label {
            Text(item.text).foregroundStyle(.primary)
        } icon: {
            Image(systemName: Icons.warningFilled).foregroundStyle(Theme.warning)
        }
        .accessibilityIdentifier("account.problem")
    }
}

extension AccountSettingsView {
    fileprivate func changePassword() {
        isCheckingPassword = true
        Task {
            do throws(AccountSettingsError) {
                try await app.changePassword(newPassword, for: account)
                newPassword = ""
                passwordResult = .changed
                await app.refresh()
            } catch {
                passwordResult = error == .keychain ? .keychain : .refused
            }
            isCheckingPassword = false
        }
    }
}

extension AccountSettingsView {
    enum ContactsResult: Identifiable {
        case denied, phoneFailed, notSaved
        var id: Self { self }
    }

    enum PasswordResult: Identifiable {
        case changed, refused, keychain
        var id: Self { self }
    }
}
