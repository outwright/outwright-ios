// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightModel
import SwiftUI

/// An account's servers: where its mail comes and goes, and the CardDAV and CalDAV addresses, which
/// can be changed. Blanking an address that unsent changes still need asks before it goes (Return
/// and Back ask; no swipe leaves without the answer).
struct ServerSettingsView: View {
    let app: AppModel
    let account: Account
    @State private var cardDAV: String
    @State private var calDAV: String
    @State private var unsentContacts = 0
    @State private var unsentEvents = 0
    @State private var isConfirmingCardDAVOff = false
    @State private var isConfirmingCalDAVOff = false
    /// The owner pressed Back with an address blanked: a yes leaves the screen too.
    @State private var isLeavingAfterAnswer = false
    @State private var notSaved = false
    @Environment(\.dismiss) private var dismiss

    init(app: AppModel, account: Account) {
        self.app = app
        self.account = account
        let stored = app.accounts.first { $0.id == account.id } ?? account
        _cardDAV = State(initialValue: stored.cardDAV ?? "")
        _calDAV = State(initialValue: stored.calDAV ?? "")
    }

    /// The account as stored now: a lookup or a switch changes the addresses behind this screen.
    private var stored: Account {
        app.accounts.first { $0.id == account.id } ?? account
    }

    var body: some View {
        Form {
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
            } header: {
                Text(ui: "Mail")
            }
            if account.contactsVia == .cardDAV, !stored.cardDAVOff {
                Section {
                    TextField(text: $cardDAV) { Text(ui: "CardDAV address") }
                        .emailEntry()
                        .onSubmit { saveCardDAV() }
                        .accessibilityIdentifier("account.cardDAV")
                } header: {
                    Text(ui: "Contacts")
                }
            }
            if account.calendarVia == .calDAV, !stored.calDAVOff {
                Section {
                    TextField(text: $calDAV) { Text(ui: "CalDAV address") }
                        .emailEntry()
                        .onSubmit { saveCalDAV() }
                        .accessibilityIdentifier("account.calDAV")
                } header: {
                    Text(ui: "Calendar")
                }
            }
        }
        .navigationTitle(Text(ui: "Server settings"))
        .inlineNavigationTitle()
        // The hidden back button also stops the edge swipe; the Settings sheet is held the same way.
        .navigationBarBackButtonHidden(isBlanking)
        .interactiveDismissDisabled(isBlanking)
        .toolbar {
            if isBlanking {
                ToolbarItem(placement: .navigation) {
                    Button { leave() } label: { Label { Text(ui: "Back") } icon: { Image(systemName: Icons.back) } }
                        .accessibilityIdentifier("account.back")
                }
            }
        }
        .onDisappear {
            saveCardDAV(leaving: true)
            saveCalDAV(leaving: true)
        }
        // The stored address changed (a lookup found one, the switch, a refresh): the field shows it,
        // unless the owner has typed something else, so a field left behind is never saved over it.
        .onChange(of: stored.cardDAV) { old, new in
            if cardDAV == (old ?? "") { cardDAV = new ?? "" }
        }
        .onChange(of: stored.calDAV) { old, new in
            if calDAV == (old ?? "") { calDAV = new ?? "" }
        }
        .confirmationDialog(
            Text(ui: "\(unsentContacts) contact changes that haven't reached the server will be lost."),
            isPresented: $isConfirmingCardDAVOff, titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                saveCardDAV(confirmed: true)
                if isLeavingAfterAnswer { leaveAfterContacts() }
            } label: {
                Text(ui: "Turn off contacts")
            }
            Button(role: .cancel) {
                cardDAV = stored.cardDAV ?? ""
                isLeavingAfterAnswer = false
            } label: {
                Text(ui: "Cancel")
            }
        }
        .confirmationDialog(
            Text(ui: "\(unsentEvents) event changes that haven't reached the server will be lost."),
            isPresented: $isConfirmingCalDAVOff, titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                saveCalDAV(confirmed: true)
                if isLeavingAfterAnswer { dismiss() }
            } label: {
                Text(ui: "Turn off the calendar")
            }
            Button(role: .cancel) {
                calDAV = stored.calDAV ?? ""
                isLeavingAfterAnswer = false
            } label: {
                Text(ui: "Cancel")
            }
        }
        .alert(Text(ui: "The change couldn't be saved on this phone."), isPresented: $notSaved) {
            Button { notSaved = false } label: { Text(ui: "OK") }
        }
    }
}

extension ServerSettingsView {
    private var isBlanking: Bool { isBlanking(cardDAV, stored.cardDAV) || isBlanking(calDAV, stored.calDAV) }

    /// The typed address is blank where a stored one is.
    private func isBlanking(_ typed: String, _ stored: String?) -> Bool {
        typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !(stored ?? "").isEmpty
    }

    /// Back with an address blanked: asks as Return does (one question at a time), and leaves once
    /// answered yes.
    private func leave() {
        saveCardDAV()
        if isConfirmingCardDAVOff {
            isLeavingAfterAnswer = true
            return
        }
        leaveAfterContacts()
    }

    /// The contacts settled: the calendar's question if it has one, else away.
    private func leaveAfterContacts() {
        saveCalDAV()
        if isConfirmingCalDAVOff {
            isLeavingAfterAnswer = true
        } else {
            dismiss()
        }
    }

    /// Saves the typed CardDAV address when it differs from the stored one. A blank one with unsent
    /// contact changes is asked about first (Back asks too); leaving any other way keeps it.
    private func saveCardDAV(confirmed: Bool = false, leaving: Bool = false) {
        let typed = cardDAV.trimmingCharacters(in: .whitespacesAndNewlines)
        guard typed != (stored.cardDAV ?? "") else { return }
        if typed.isEmpty, !confirmed {
            let count = app.unsentContactChanges(of: account.id)
            guard count == 0 else {
                if !leaving {
                    unsentContacts = count
                    isConfirmingCardDAVOff = true
                }
                return
            }
        }
        do {
            try app.setCardDAV(typed, for: account.id)
            Task { await app.refreshContacts(account.id) }
        } catch {
            notSaved = true
        }
    }

    /// Saves the typed CalDAV address, as `saveCardDAV` does the CardDAV one.
    private func saveCalDAV(confirmed: Bool = false, leaving: Bool = false) {
        let typed = calDAV.trimmingCharacters(in: .whitespacesAndNewlines)
        guard typed != (stored.calDAV ?? "") else { return }
        if typed.isEmpty, !confirmed {
            let count = app.unsentEventChanges(of: account.id)
            guard count == 0 else {
                if !leaving {
                    unsentEvents = count
                    isConfirmingCalDAVOff = true
                }
                return
            }
        }
        do {
            try app.setCalDAV(typed, for: account.id)
            Task { await app.refreshCalendars(account.id) }
        } catch {
            notSaved = true
        }
    }
}
