// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightDAV
public import OutwrightModel
public import OutwrightStore

/// Putting an event back to the server's version, read from the object the store keeps.
public enum EventRestore {
    /// The owner gives up a change the server did not take: the server's version comes back, the
    /// change goes. An event the server never had goes too.
    public static func discardFailedChange(_ id: EventID, in store: MailStore) throws(StoreError) {
        let held = try store.serverEvent(id)
        let series = held.flatMap { try? ICalendarReader.calendar($0) }.flatMap { EventMapping.series($0).first }
        try store.restoreEventServerVersion(id, series: series)
    }
}
