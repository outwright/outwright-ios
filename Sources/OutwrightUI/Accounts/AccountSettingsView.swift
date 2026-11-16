// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightModel
import SwiftUI

/// One account: its name, its signature, its servers, and removing it.
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
    @State var cardDAV: String
    @State var isChangingPhoneCopy = false
    @State var contactsResult: ContactsResult?
    /// Unsent contact changes that blanking the CardDAV address would lose, while asking.
    @State var unsentContacts = 0
    @State var isConfirmingCardDAVOff = false
    /// The owner pressed Back with an address blanked: a yes leaves the screen too.
    @State var isLeavingAfterAnswer = false
    /// The CalDAV address as typed, and what blanking it would lose while asking (see `+Calendar`).
    @State var calDAV: String
    @State var unsentEvents = 0
    @State var isConfirmingCalDAVOff = false
    @State var calendarsNotSaved = false
    /// The question above came from a switch turned off, not a blanked address.
    @State var isTurningCalendarOff = false
    @State var isTurningContactsOff = false
    /// The Notifications switch; loaded by the form, which is always there.
    @State private var notifications: NotificationsToggleModel
    @Environment(\.dismiss) var dismiss

    private var passwordSection: some View {
        Section {
            SecureField(text: $newPassword) { Text(ui: "New password") }
                .textContentType(.password)
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
        _cardDAV = State(initialValue: account.cardDAV ?? "")
        _calDAV = State(initialValue: account.calDAV ?? "")
        let reminders = app.sync.reminders
        _notifications = State(
            initialValue: NotificationsToggleModel(
                account: account, support: app.push,
                local: StoreLocalNotifying(store: app.store) { await reminders.requestAuthorization() },
                pushIncluded: app.modules.offering?.includes(.push) ?? true))
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
            NotificationsSection(model: notifications, offering: app.modules.offering)
            contactsSection
            if account.calendarVia == .calDAV {
                calendarSection
            }
            ForEach(Array(app.modules.accountSections.enumerated()), id: \.offset) { _, module in
                module.section(for: account)
            }
            if account.auth == .oauth {
                providerSignInSection
            }
            if account.auth == .password {
                passwordSection
            }
            Section {
                LabeledContent {
                    Text(verbatim: "\(account.imap.host):\(account.imap.port)")
                } label: {
                    Text(ui: "Incoming mail (IMAP)")
                }
                LabeledContent {
                    Text(verbatim: "\(account.smtp.host):\(account.smtp.port)")
                } label: {
                    Text(ui: "Outgoing mail (SMTP)")
                }
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
        // A blanked CardDAV or CalDAV address may need a question before the screen goes: Back asks
        // it. The hidden back button also stops the edge swipe; the Settings sheet is held the same way.
        .navigationBarBackButtonHidden(isBlanking)
        .interactiveDismissDisabled(isBlanking)
        .toolbar {
            if isBlanking {
                ToolbarItem(placement: .navigation) {
                    Button { leave() } label: { Label { Text(ui: "Back") } icon: { Image(systemName: "chevron.left") } }
                        .accessibilityIdentifier("account.back")
                }
            }
        }
        .task { await notifications.load() }
        .onDisappear {
            // A removed account is not saved again.
            if !isRemoved {
                try? app.updateAccount(account)
                saveCardDAV(leaving: true)
                saveCalDAV(leaving: true)
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
    private var isBlanking: Bool { isBlankingCardDAV || isBlankingCalDAV }

    /// Back with an address blanked: asks as Return does (one question at a time), and leaves once
    /// answered yes.
    func leave() {
        saveCardDAV()
        if isConfirmingCardDAVOff {
            isLeavingAfterAnswer = true
            return
        }
        leaveAfterContacts()
    }

    /// The contacts settled: the calendar's question if it has one, else away.
    func leaveAfterContacts() {
        saveCalDAV()
        if isConfirmingCalDAVOff {
            isLeavingAfterAnswer = true
        } else {
            dismiss()
        }
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
