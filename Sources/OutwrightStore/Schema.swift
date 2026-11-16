// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import GRDB

enum Schema {
    static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { database in
            try database.execute(sql: """
                CREATE TABLE account (
                    id TEXT PRIMARY KEY, displayName TEXT NOT NULL, email TEXT NOT NULL,
                    colorIndex INTEGER NOT NULL, imapHost TEXT NOT NULL, imapPort INTEGER NOT NULL,
                    imapSecurity TEXT NOT NULL, smtpHost TEXT NOT NULL, smtpPort INTEGER NOT NULL,
                    smtpSecurity TEXT NOT NULL, user TEXT NOT NULL, signature TEXT NOT NULL,
                    sortOrder INTEGER NOT NULL);
                CREATE TABLE folder (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    accountId TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
                    path TEXT NOT NULL, name TEXT NOT NULL, kind TEXT NOT NULL,
                    uidValidity INTEGER NOT NULL, isFavorite INTEGER NOT NULL,
                    UNIQUE (accountId, path));
                CREATE TABLE message (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    accountId TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
                    folderId INTEGER NOT NULL REFERENCES folder(id) ON DELETE CASCADE,
                    uid INTEGER NOT NULL, threadId TEXT NOT NULL,
                    fromName TEXT, fromEmail TEXT NOT NULL, toJSON TEXT NOT NULL, ccJSON TEXT NOT NULL,
                    subject TEXT NOT NULL, preview TEXT NOT NULL, date REAL NOT NULL,
                    isRead INTEGER NOT NULL, isFlagged INTEGER NOT NULL,
                    hasAttachment INTEGER NOT NULL, isInvitation INTEGER NOT NULL,
                    inboxClass TEXT NOT NULL, messageIdHeader TEXT, body BLOB);
                CREATE INDEX message_header ON message(accountId, messageIdHeader);
                CREATE INDEX message_folder_uid ON message(folderId, uid);
                CREATE INDEX message_thread ON message(accountId, threadId, date);
                CREATE INDEX message_folder_date ON message(folderId, date);
                CREATE TABLE sender_override (email TEXT PRIMARY KEY, class TEXT NOT NULL);
                CREATE TABLE pending_action (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    accountId TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
                    action BLOB NOT NULL, sourceFolderId INTEGER, sourceUid INTEGER NOT NULL);
                CREATE VIRTUAL TABLE message_fts USING fts5(
                    subject, senderName, senderAddress, preview, body,
                    tokenize = 'unicode61 remove_diacritics 2');
                """)
        }
        registerLater(&migrator)
        registerProviders(&migrator)
        registerSubscriptions(&migrator)
        registerAccountlessSubscriptions(&migrator)
        registerNewMailNotices(&migrator)
        registerProtection(&migrator)
        registerJunkInvitations(&migrator)
        return migrator
    }

    /// junkInvitations: invitations refused while in Junk stayed refused once moved out. Every
    /// REQUEST or ADD refused outside Junk and Trash is taken again once; one refused for another
    /// reason is refused again.
    private static func registerJunkInvitations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("junkInvitations") { database in
            try database.execute(
                sql: """
                    DELETE FROM invitation_message
                    WHERE applied = 0 AND awaitingCalendar = 0 AND method IN ('REQUEST', 'ADD')
                        AND messageId IN (
                            SELECT m.id FROM message m JOIN folder f ON f.id = m.folderId
                            WHERE f.kind NOT IN ('junk', 'trash'))
                    """)
        }
    }

    /// protection: what a draft asks to be sent with (JSON), and the addresses the server has already
    /// taken the message for (JSON), so a send tried again goes only to the rest; and whether a message
    /// was protected from readers (its subject and preview are then the opened message's).
    private static func registerProtection(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("protection") { database in
            try database.execute(
                sql: """
                    ALTER TABLE message ADD COLUMN protection BLOB;
                    ALTER TABLE message ADD COLUMN submittedTo BLOB;
                    ALTER TABLE message ADD COLUMN isProtected INTEGER NOT NULL DEFAULT 0;
                    ALTER TABLE message ADD COLUMN isDecrypted INTEGER NOT NULL DEFAULT 0;
                    """)
        }
    }

    private static func registerLater(_ migrator: inout DatabaseMigrator) {
        // v2: a draft the server refused for good keeps why (`notSent`); a queued change counts the
        // runs that could not find its message (`attempts`); the Message-IDs each message answers
        // (`message_ref`), so a message that arrives after its answers gathers them into its thread.
        migrator.registerMigration("v2") { database in
            try database.execute(sql: """
                ALTER TABLE message ADD COLUMN notSent TEXT;
                ALTER TABLE pending_action ADD COLUMN attempts INTEGER NOT NULL DEFAULT 0;
                CREATE TABLE message_ref (
                    messageId INTEGER NOT NULL REFERENCES message(id) ON DELETE CASCADE,
                    accountId TEXT NOT NULL, ref TEXT NOT NULL, PRIMARY KEY (messageId, ref));
                CREATE INDEX message_ref_ref ON message_ref(accountId, ref);
                """)
        }
        // v3: how far back a folder's mail is held, once older mail was fetched past the window.
        migrator.registerMigration("v3") { database in
            try database.execute(sql: "ALTER TABLE folder ADD COLUMN heldSince REAL")
        }
        registerContacts(&migrator)
        // v5: the server's hierarchy delimiter, so the drawer shows subfolders under their parent.
        migrator.registerMigration("v5") { database in
            try database.execute(sql: "ALTER TABLE folder ADD COLUMN delimiter TEXT")
        }
        registerCalendar(&migrator)
        // How an account signs in: `password`, or `microsoft` before providers (now `oauth`).
        migrator.registerMigration("account-auth") { database in
            try database.execute(sql: "ALTER TABLE account ADD COLUMN auth TEXT NOT NULL DEFAULT 'password'")
        }
        registerInvitations(&migrator)
        // v11: the folder's HIGHESTMODSEQ (RFC 7162) as of the last reconcile that was written, its
        // UInt64 held by bit pattern; NULL when the next sync must reconcile in full.
        migrator.registerMigration("v11") { database in
            try database.execute(sql: "ALTER TABLE folder ADD COLUMN highestModSeq INTEGER")
        }
        registerSearch(&migrator)
        // v13: the mod-sequences remembered so far may stand past changes never seen (a QRESYNC
        // answer said before [CLOSED] was dropped): every folder is reconciled in full once.
        migrator.registerMigration("v13") { database in
            try database.execute(sql: "UPDATE folder SET highestModSeq = NULL")
        }
        // v14: whether the account's CalDAV server schedules (RFC 6638 › 2), as it last said.
        migrator.registerMigration("v14") { database in
            try database.execute(
                sql: """
                    CREATE TABLE caldav_scheduling (
                        accountId TEXT PRIMARY KEY REFERENCES account(id) ON DELETE CASCADE,
                        schedules INTEGER NOT NULL)
                    """)
        }
        // v15: the invitation mails of the owner's meetings owed while the account had no Drafts to
        // send them from, each its whole message; and the last answer taken from each guest of the
        // owner's meetings, per occurrence ("" for the series), by its SEQUENCE and DTSTAMP.
        migrator.registerMigration("v15") { database in
            try database.execute(
                sql: """
                    CREATE TABLE meeting_mail_owed (
                        id INTEGER PRIMARY KEY,
                        accountId TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
                        body BLOB NOT NULL);
                    CREATE TABLE guest_answer (
                        eventId INTEGER NOT NULL REFERENCES event(id) ON DELETE CASCADE,
                        guest TEXT NOT NULL, scope TEXT NOT NULL, sequence INTEGER NOT NULL, stamp REAL,
                        PRIMARY KEY (eventId, guest, scope))
                    """)
        }
    }

    private static func registerProviders(_ migrator: inout DatabaseMigrator) {
        // providers: who each account is with, and which protocol its calendars and contacts come
        // over, kept instead of derived from how it signs in. Microsoft accounts (auth
        // 'microsoft') become the Microsoft provider, signing in with OAuth, over Graph.
        migrator.registerMigration("providers") { database in
            try database.execute(
                sql: """
                    ALTER TABLE account ADD COLUMN provider TEXT NOT NULL DEFAULT 'own-server';
                    ALTER TABLE account ADD COLUMN calendarVia TEXT NOT NULL DEFAULT 'calDAV';
                    ALTER TABLE account ADD COLUMN contactsVia TEXT NOT NULL DEFAULT 'cardDAV';
                    UPDATE account SET provider = 'microsoft', auth = 'oauth', calendarVia = 'graph',
                        contactsVia = 'graph' WHERE auth = 'microsoft';
                    """)
        }
    }
}
