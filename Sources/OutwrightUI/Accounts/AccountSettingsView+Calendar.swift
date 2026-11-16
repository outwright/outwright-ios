// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightModel
import SwiftUI

/// The account's calendar: on or off, its CalDAV address, and one found outside the domain to say yes
/// or no to.
extension AccountSettingsView {
    @ViewBuilder var calendarSection: some View {
        Section {
            Toggle(isOn: calendarOn) { Text(ui: "Sync calendar") }
                .accessibilityIdentifier("account.calendarOn")
            if !stored.calDAVOff {
                calendarAddress
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
        .onChange(of: stored.calDAV) { old, new in followStoredCalDAV(from: old, to: new) }
        .confirmationDialog(
            Text(ui: "\(unsentEvents) event changes that haven't reached the server will be lost."),
            isPresented: $isConfirmingCalDAVOff, titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                if isTurningCalendarOff {
                    turnCalendar(on: false)
                } else {
                    saveCalDAV(confirmed: true)
                }
                isTurningCalendarOff = false
                if isLeavingAfterAnswer { dismiss() }
            } label: {
                Text(ui: "Turn off the calendar")
            }
            Button(role: .cancel) {
                // Only a blanked address goes back; an address being typed stays when the switch asked.
                if !isTurningCalendarOff { calDAV = stored.calDAV ?? "" }
                isTurningCalendarOff = false
                isLeavingAfterAnswer = false
            } label: {
                Text(ui: "Cancel")
            }
        }
    }

    /// The address, and one found outside the domain to say yes or no to.
    @ViewBuilder private var calendarAddress: some View {
            if let parked = stored.calDAVUnconfirmed {
                Text(ui: "The calendar is at \(Self.host(of: parked)), not at \(ownDomain).")
                Button {
                    do {
                        try app.confirmCalDAV(account.id)
                        calDAV = parked
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
            TextField(text: $calDAV) { Text(ui: "CalDAV address") }
                .emailEntry()
                .onSubmit { saveCalDAV() }
                .accessibilityIdentifier("account.calDAV")
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
                isTurningCalendarOff = true
                isConfirmingCalDAVOff = true
                return
            }
            turnCalendar(on: isOn)
        }
    }

    /// Turns the calendar on (synced at once, its address looked for when it has none) or off. The field
    /// follows the stored address (`followStoredCalDAV`).
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

    /// The stored address changed (a lookup found one, the switch, a refresh): the field shows it,
    /// unless the owner has typed something else, so a field left behind is never saved over it.
    func followStoredCalDAV(from old: String?, to new: String?) {
        if calDAV == (old ?? "") { calDAV = new ?? "" }
    }

    /// The typed CalDAV address is blank where a stored one is.
    var isBlankingCalDAV: Bool {
        calDAV.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !(stored.calDAV ?? "").isEmpty
    }

    /// Saves the typed CalDAV address when it differs from the stored one. A blank one with unsent
    /// event changes is asked about first (Back asks too); leaving any other way keeps it.
    func saveCalDAV(confirmed: Bool = false, leaving: Bool = false) {
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
            calendarsNotSaved = false
            Task { await app.refreshCalendars(account.id) }
        } catch {
            calendarsNotSaved = true
        }
    }
}
