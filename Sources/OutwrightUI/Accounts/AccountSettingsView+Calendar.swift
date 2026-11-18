// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightModel
import SwiftUI

/// The account's calendar: on or off, and an address found outside the domain to say yes or no to. The
/// CalDAV address itself is under Server settings.
extension AccountSettingsView {
    @ViewBuilder var calendarSection: some View {
        Section {
            Toggle(isOn: calendarOn) { Text(ui: "Sync calendar") }
                .accessibilityIdentifier("account.calendarOn")
            if !stored.calDAVOff {
                foundAddress
            }
        } header: {
            Text(ui: "Calendar")
        } footer: {
            if calendarsNotSaved {
                Text(ui: "The change couldn't be saved on this phone.").foregroundStyle(Theme.delete)
            } else {
                Text(ui: "Off, this account's calendar stays on the server but not on this phone.")
            }
        }
        .confirmationDialog(
            Text(ui: "\(unsentEvents) event changes that haven't reached the server will be lost."),
            isPresented: $isConfirmingCalDAVOff, titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                turnCalendar(on: false)
            } label: {
                Text(ui: "Turn off the calendar")
            }
            Button(role: .cancel) {} label: {
                Text(ui: "Cancel")
            }
        }
    }

    /// An address found outside the domain, to say yes or no to.
    @ViewBuilder private var foundAddress: some View {
        if let parked = stored.calDAVUnconfirmed {
            Text(ui: "The calendar is at \(Self.host(of: parked)), not at \(ownDomain).")
            Button {
                do {
                    try app.confirmCalDAV(account.id)
                    Task { await app.refreshCalendars(account.id) }
                } catch {
                    calendarsNotSaved = true
                }
            } label: {
                Text(ui: "Allow")
            }
            .accessibilityIdentifier("account.confirmCalDAV")
            Button(role: .destructive) {
                do {
                    try app.declineCalDAV(account.id)
                } catch {
                    calendarsNotSaved = true
                }
            } label: {
                Text(ui: "Don't use")
            }
            .accessibilityIdentifier("account.declineCalDAV")
        }
    }

    /// The host a found address names, to say where it is.
    static func host(of url: String) -> String {
        URL(string: url)?.host() ?? url
    }

    /// The domain of the account's address.
    var ownDomain: String {
        AddAccountModel.domain(of: account.email) ?? account.email
    }

    /// The switch: off with unsent event changes asks first.
    private var calendarOn: Binding<Bool> {
        Binding { !stored.calDAVOff } set: { isOn in
            let count = isOn ? 0 : app.unsentEventChanges(of: account.id)
            guard count == 0 else {
                unsentEvents = count
                isConfirmingCalDAVOff = true
                return
            }
            turnCalendar(on: isOn)
        }
    }

    /// Turns the calendar on (synced at once, its address looked for when it has none) or off.
    func turnCalendar(on isOn: Bool) {
        Task {
            do throws(AccountSettingsError) {
                try await app.setCalendarOn(isOn, for: account.id)
                calendarsNotSaved = false
            } catch {
                calendarsNotSaved = true
                return
            }
            if isOn { await app.refreshCalendars(account.id) }
        }
    }
}
