// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import GRDB

extension Schema {
    /// v7: invitations from outside. An event keeps who wrote its calendar object (`origin`: the
    /// server, or this app from an invitation in mail), whether the owner declined it all (`hidden`:
    /// kept, not shown), the event's revision up to which the app's answers to the organiser were
    /// queued as mail (`replySent`, 0 for none), and the last `Schedule-Tag` the server gave for the
    /// object (`scheduleTag`: with one the server answers the organiser itself), the object as the
    /// organiser's last update or cancellation from mail left it while the server's copy is older
    /// (`appliedIcs`). `invitation_message`
    /// remembers each message read as an invitation, once: its method, UID, RECURRENCE-ID and SEQUENCE,
    /// the event it is about, whether it changed the calendar (`applied`), and for a REPLY who answered
    /// and how (`replyEmail`, `replyResponse`), and whether it waits for the account's calendars
    /// (`awaitingCalendar`: taken again once they are listed).
    static func registerInvitations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v7") { database in
            try database.execute(sql: """
                ALTER TABLE event ADD COLUMN origin TEXT NOT NULL DEFAULT 'server';
                ALTER TABLE event ADD COLUMN hidden INTEGER NOT NULL DEFAULT 0;
                ALTER TABLE event ADD COLUMN replySent INTEGER NOT NULL DEFAULT 0;
                ALTER TABLE event ADD COLUMN scheduleTag TEXT;
                ALTER TABLE event ADD COLUMN appliedIcs BLOB;
                CREATE TABLE invitation_message (
                    messageId INTEGER PRIMARY KEY REFERENCES message(id) ON DELETE CASCADE,
                    method TEXT NOT NULL, uid TEXT NOT NULL, recurrenceIdJSON TEXT,
                    sequence INTEGER NOT NULL,
                    eventId INTEGER REFERENCES event(id) ON DELETE SET NULL,
                    applied INTEGER NOT NULL, replyEmail TEXT, replyResponse TEXT,
                    awaitingCalendar INTEGER NOT NULL DEFAULT 0);
                CREATE INDEX invitation_message_uid ON invitation_message(uid);
                """)
        }
        // v8: an answer the server took whose reply mail could not be queued (no Drafts folder):
        // `failedReplyJSON` holds that answer, shown as a failed change until it is retried.
        migrator.registerMigration("v8") { database in
            try database.execute(sql: "ALTER TABLE event ADD COLUMN failedReplyJSON TEXT")
        }
        // v9: what the meeting card needs of a message without the event: whether it is an update of
        // a meeting the calendar held (`isUpdate`), and if the phone applied it whether the time moved
        // (`timeMoved`: 1 or 0, NULL when unknown or not an update), and the meeting's title (`title`).
        migrator.registerMigration("v9") { database in
            try database.execute(sql: """
                ALTER TABLE invitation_message ADD COLUMN isUpdate INTEGER NOT NULL DEFAULT 0;
                ALTER TABLE invitation_message ADD COLUMN timeMoved INTEGER;
                ALTER TABLE invitation_message ADD COLUMN title TEXT;
                """)
        }
        // v10: the scopes (the whole event, or occurrences) whose last answer was to go without a
        // response, and for which the server sent one anyway (it had scheduled the copy by the time
        // the answer reached it): `serverRepliedJSON`, a JSON array of `EditScope`, NULL for none.
        migrator.registerMigration("v10") { database in
            try database.execute(sql: "ALTER TABLE event ADD COLUMN serverRepliedJSON TEXT")
        }
    }
}
