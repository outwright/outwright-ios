// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightModel
import SwiftUI

/// The account's contacts: on or off, an address found outside the domain to say yes or no to, and the
/// copy in the iPhone's Contacts. The CardDAV address itself is under Server settings.
extension AccountSettingsView {
    /// A Graph account's contacts come through Graph: no CardDAV address, only the phone copy.
    @ViewBuilder var contactsSection: some View {
        if account.contactsVia == .cardDAV || app.sync.canSaveToPhone {
            contactsForm
        }
    }

    @ViewBuilder private var contactsForm: some View {
        Section {
            if account.contactsVia == .cardDAV {
                Toggle(isOn: contactsOn) { Text(ui: "Sync contacts") }
                    .accessibilityIdentifier("account.contactsOn")
            }
            if account.contactsVia == .cardDAV, !stored.cardDAVOff, let parked = stored.cardDAVUnconfirmed {
                Text(ui: "The contacts are at \(Self.host(of: parked)), not at \(ownDomain).")
                Button {
                    do {
                        try app.confirmCardDAV(account.id)
                        Task { await app.refreshContacts(account.id) }
                    } catch {
                        contactsResult = .notSaved
                    }
                } label: {
                    Text(ui: "Allow")
                }
                .accessibilityIdentifier("account.confirmCardDAV")
                Button(role: .destructive) {
                    do {
                        try app.declineCardDAV(account.id)
                    } catch {
                        contactsResult = .notSaved
                    }
                } label: {
                    Text(ui: "Don't use")
                }
                .accessibilityIdentifier("account.declineCardDAV")
            }
            if app.sync.canSaveToPhone {
                Toggle(isOn: savesToPhone) { Text(ui: "Save contacts to iPhone") }
                    .disabled(isChangingPhoneCopy)
                    .accessibilityIdentifier("account.savesContactsToPhone")
            }
        } header: {
            Text(ui: "Contacts")
        } footer: {
            Text(
                ui: """
                    Saving to iPhone puts a copy of this account's contacts in the Contacts app, so calls \
                    show who is calling. Turning it off removes that copy.
                    """)
        }
        .confirmationDialog(
            Text(ui: "\(unsentContacts) contact changes that haven't reached the server will be lost."),
            isPresented: $isConfirmingCardDAVOff, titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                turnContacts(on: false)
            } label: {
                Text(ui: "Turn off contacts")
            }
            Button(role: .cancel) {} label: {
                Text(ui: "Cancel")
            }
        }
        // On the section: a second alert on the form beside the others would never show.
        .alert(item: $contactsResult) { result in
            switch result {
            case .denied:
                Alert(
                    title: Text(ui: "Outwright has no access to Contacts."),
                    message: Text(ui: "You can give it in the Settings app, under Outwright."))
            case .phoneFailed: Alert(title: Text(ui: "The iPhone's Contacts didn't take the change."))
            case .notSaved: Alert(title: Text(ui: "The change couldn't be saved on this phone."))
            }
        }
    }

    private var savesToPhone: Binding<Bool> {
        Binding { stored.savesContactsToPhone } set: { isOn in
            isChangingPhoneCopy = true
            Task {
                do throws(AccountSettingsError) {
                    try await app.setSavesContactsToPhone(isOn, for: account.id)
                } catch {
                    switch error {
                    case .contactsDenied: contactsResult = .denied
                    case .phoneContacts: contactsResult = .phoneFailed
                    default: contactsResult = .notSaved
                    }
                }
                isChangingPhoneCopy = false
            }
        }
    }

    /// The contacts switch: off with unsent contact changes asks first.
    private var contactsOn: Binding<Bool> {
        Binding { !stored.cardDAVOff } set: { isOn in
            let count = isOn ? 0 : app.unsentContactChanges(of: account.id)
            guard count == 0 else {
                unsentContacts = count
                isConfirmingCardDAVOff = true
                return
            }
            turnContacts(on: isOn)
        }
    }

    /// Turns the contacts on (synced at once, their address looked for when they have none) or off.
    private func turnContacts(on isOn: Bool) {
        Task {
            do throws(AccountSettingsError) {
                try await app.setContactsOn(isOn, for: account.id)
            } catch {
                contactsResult = .notSaved
                return
            }
            if isOn { await app.refreshContacts(account.id) }
        }
    }
}
