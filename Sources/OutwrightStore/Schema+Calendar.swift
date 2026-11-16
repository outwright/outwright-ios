// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import GRDB

extension Schema {
    /// v6: CalDAV. The account's calendar address (`calDAVOff` is the owner's choice of none);
    /// calendars (`gone` marks one the server no longer lists that still holds an event with an unsent
    /// change, a held conflict or a failed edit); events (the calendar object as it came, kept opaque,
    /// beside the series the app shows, and any change of the owner's not yet sent; `revision` counts
    /// the owner's edits so a send can tell it was overtaken; `newHref`/`newIcs` are the place and
    /// object a create was first sent with, kept so a retry reuses them); the occurrences of each
    /// series inside the held window; and the window and phone zone they were laid out for.
    /// `pendingEditJSON` and `conflictJSON` hold lists of edits, in order;
    /// `detailed` and `organizer` are the series' ownership: the organizer of its base, else of its first
    /// override. `event_skipped` remembers the calendar objects the server listed that are not kept as
    /// events (unreadable: `refused`; or with no occurrence in the window), by ETag, so that they are not
    /// fetched again until they change.
    static func registerCalendar(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v6") { database in
            try database.execute(sql: """
                ALTER TABLE account ADD COLUMN calDAV TEXT;
                ALTER TABLE account ADD COLUMN calDAVUnconfirmed TEXT;
                ALTER TABLE account ADD COLUMN calDAVOff INTEGER NOT NULL DEFAULT 0;
                CREATE TABLE calendar (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    accountId TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
                    href TEXT NOT NULL, name TEXT NOT NULL, color INTEGER NOT NULL,
                    isReadOnly INTEGER NOT NULL, isDefault INTEGER NOT NULL DEFAULT 0,
                    syncToken TEXT, windowListedFrom INTEGER, gone INTEGER NOT NULL DEFAULT 0,
                    UNIQUE (accountId, href));
                CREATE TABLE event (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    accountId TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
                    calendarId INTEGER NOT NULL REFERENCES calendar(id) ON DELETE CASCADE,
                    href TEXT, etag TEXT, ics BLOB, uid TEXT NOT NULL, seriesJSON TEXT NOT NULL,
                    pendingEditJSON TEXT, conflictJSON TEXT,
                    changeFailed INTEGER NOT NULL DEFAULT 0, attempts INTEGER NOT NULL DEFAULT 0,
                    revision INTEGER NOT NULL DEFAULT 0, newHref TEXT, newIcs BLOB,
                    detailed INTEGER NOT NULL DEFAULT 0, organizer TEXT);
                CREATE INDEX event_calendar_href ON event(calendarId, href);
                CREATE INDEX event_uid ON event(accountId, uid);
                CREATE TABLE occurrence (
                    eventId INTEGER NOT NULL REFERENCES event(id) ON DELETE CASCADE,
                    recurrenceIdJSON TEXT, detailsJSON TEXT NOT NULL,
                    startUTC REAL NOT NULL, endUTC REAL NOT NULL, allDayStart INTEGER, allDayEnd INTEGER);
                CREATE INDEX occurrence_start ON occurrence(startUTC);
                CREATE INDEX occurrence_all_day ON occurrence(allDayStart);
                CREATE INDEX occurrence_event ON occurrence(eventId);
                CREATE TABLE calendar_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE TABLE event_skipped (
                    calendarId INTEGER NOT NULL REFERENCES calendar(id) ON DELETE CASCADE,
                    href TEXT NOT NULL, etag TEXT NOT NULL, refused INTEGER NOT NULL,
                    PRIMARY KEY (calendarId, href));
                """)
        }
    }
}
