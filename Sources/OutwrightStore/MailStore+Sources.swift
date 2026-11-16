// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import GRDB
import OutwrightModel

/// Where an account's calendars and contacts come from, read from its row: the rule lives here
/// alone, by protocol, never by provider.
extension MailStore {
    /// Calendars: Graph, or a CalDAV address. `row` holds the account's `calendarVia` and `calDAV`.
    static func hasCalendarSource(_ row: Row?) -> Bool {
        (row?["calendarVia"] as String?) == CalendarVia.graph.rawValue || (row?["calDAV"] as String?) != nil
    }

    /// Contacts: Graph, or a CardDAV address. `row` holds the account's `contactsVia` and `cardDAV`.
    static func hasContactSource(_ row: Row?) -> Bool {
        (row?["contactsVia"] as String?) == ContactsVia.graph.rawValue || (row?["cardDAV"] as String?) != nil
    }
}
