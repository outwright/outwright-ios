// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightDAV
import OutwrightModel
import OutwrightStore

/// Keeping one calendar object as its source has it, shared by CalDAV and subscribed calendars.
enum CalendarObjects {
    // swiftlint:disable function_parameter_count
    /// Stores an object as the server has it. One that cannot be read is remembered as refused (and
    /// counted for the views); one with no event, or none in the window, is remembered as skipped.
    static func keep(
        href: String, etag: String, data: Data, scheduleTag: String?, in local: CalendarID,
        window: ClosedRange<Date>, zone: TimeZone, store: MailStore
    ) throws(SyncError) {
        guard let parsed = try? ICalendarReader.calendar(data) else {
            try stored { try store.setSkippedEvent(href: href, etag: etag, refused: true, in: local) }
            return
        }
        guard let series = EventMapping.series(parsed).first,
            !Recurrence.occurrences(series, from: window.lowerBound, to: window.upperBound, phoneZone: zone).isEmpty
        else {
            try stored { try store.removeRemote(hrefs: [href], in: local) }
            try stored { try store.setSkippedEvent(href: href, etag: etag, refused: false, in: local) }
            return
        }
        // An event with a change queued is left as it is; the queue sends it.
        _ = try stored {
            try store.upsertRemote(
                href: href, etag: etag, ics: data, series: series, in: local, window: window, phoneZone: zone,
                scheduleTag: scheduleTag)
        }
        try stored { try store.removeSkippedEvents(hrefs: [href], in: local) }
    }
    // swiftlint:enable function_parameter_count
}
