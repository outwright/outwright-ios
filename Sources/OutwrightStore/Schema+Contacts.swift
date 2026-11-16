// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import GRDB

extension Schema {
    /// v4: CardDAV. The account's contacts address; address books; contacts (the card as it came, kept
    /// opaque, beside what the app shows, and any change of the owner's not yet sent); a lookup by
    /// e-mail address; which phone contact each exported contact became, and the phone group
    /// Outwright made or adopted for the account; `cardDAVOff` is the owner's choice of no CardDAV
    /// address. `gone` marks a book the server no longer lists that still holds a contact with an
    /// unsent change, a held conflict or a failed edit; `revision` counts the owner's edits of a
    /// contact, so a send can tell it was overtaken.
    static func registerContacts(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v4") { database in
            try database.execute(sql: """
                ALTER TABLE account ADD COLUMN cardDAV TEXT;
                ALTER TABLE account ADD COLUMN cardDAVUnconfirmed TEXT;
                ALTER TABLE account ADD COLUMN savesContactsToPhone INTEGER NOT NULL DEFAULT 0;
                ALTER TABLE account ADD COLUMN cardDAVOff INTEGER NOT NULL DEFAULT 0;
                CREATE TABLE address_book (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    accountId TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
                    href TEXT NOT NULL, name TEXT NOT NULL, isReadOnly INTEGER NOT NULL,
                    syncToken TEXT, gone INTEGER NOT NULL DEFAULT 0,
                    UNIQUE (accountId, href));
                CREATE TABLE contact (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    accountId TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
                    addressBookId INTEGER NOT NULL REFERENCES address_book(id) ON DELETE CASCADE,
                    href TEXT, etag TEXT, vcard BLOB, detailsJSON TEXT NOT NULL, sortKey TEXT NOT NULL,
                    photo BLOB, conflictJSON TEXT, pendingChange TEXT,
                    changeFailed INTEGER NOT NULL DEFAULT 0, attempts INTEGER NOT NULL DEFAULT 0,
                    revision INTEGER NOT NULL DEFAULT 0, newHref TEXT, newCard BLOB);
                CREATE INDEX contact_book_href ON contact(addressBookId, href);
                CREATE INDEX contact_sort ON contact(accountId, sortKey);
                CREATE TABLE contact_email (
                    contactId INTEGER NOT NULL REFERENCES contact(id) ON DELETE CASCADE,
                    accountId TEXT NOT NULL, email TEXT NOT NULL);
                CREATE INDEX contact_email_lookup ON contact_email(accountId, email);
                CREATE TABLE phone_export (
                    accountId TEXT NOT NULL, contactId INTEGER NOT NULL, phoneIdentifier TEXT NOT NULL,
                    PRIMARY KEY (accountId, contactId));
                CREATE TABLE phone_export_group (accountId TEXT PRIMARY KEY, groupIdentifier TEXT NOT NULL);
                """)
        }
    }
}
