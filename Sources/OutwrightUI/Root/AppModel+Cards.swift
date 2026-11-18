// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// What a person card opens, and the pulls on the Contacts and Calendar tabs.
extension AppModel {
    /// Opens what a person card asked for: now when the card is not a sheet (beside the list, or
    /// pushed), else once the sheet has gone (a second sheet can't be presented during a dismissal).
    /// A second tap while the sheet is still going replaces the first.
    func afterCard(_ open: @escaping () -> Void) {
        guard personToShow != nil || afterCardClosed != nil else {
            open()
            return
        }
        afterCardClosed = open
        personToShow = nil
    }

    /// A pull on the contacts: every account's contacts are synced again, its mail left alone.
    func pullContacts() async {
        for account in accounts { await sync.refreshContacts(of: account.id) }
        await updateAttention()
    }

    /// A pull on the calendar: every account's calendars and the subscribed ones are read again.
    func pullCalendars() async {
        for account in accounts { await sync.refreshCalendars(of: account.id) }
        await sync.refreshSubscriptions(force: true)
        await updateAttention()
    }
}
