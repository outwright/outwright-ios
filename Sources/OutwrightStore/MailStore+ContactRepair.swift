// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
import GRDB
public import OutwrightModel

extension MailStore {
    /// The card as the server last gave it, nil when it never had the contact.
    public func serverCard(_ id: ContactID) throws(StoreError) -> Data? {
        try read { database in
            try Data.fetchOne(database, sql: "SELECT vcard FROM contact WHERE id = ?", arguments: [id.raw])
        }
    }

    /// The owner gave up a change the server did not take: the server's version (`details` read
    /// from `serverCard`) is the contact again, and the change, its failure and any held conflict
    /// go. A contact the server never had (`details` nil, no address) is removed. For every contact
    /// the server has, its ETag and its book's sync token go, since the server may have changed the
    /// card while the failure waited: the next sync fetches it again and its card replaces what is
    /// shown (the details kept here when the held card can't be read).
    public func restoreServerVersion(_ id: ContactID, details: ContactDetails?, photo: Data?) throws(StoreError) {
        try write { database in
            let row = try Self.contactRow(database, id)
            guard let details else {
                if (row["href"] as String?) == nil {
                    try database.execute(sql: "DELETE FROM contact WHERE id = ?", arguments: [id.raw])
                } else {
                    try database.execute(
                        sql: """
                            UPDATE contact SET pendingChange = NULL, changeFailed = 0, conflictJSON = NULL,
                                attempts = 0, etag = NULL, revision = revision + 1 WHERE id = ?
                            """, arguments: [id.raw])
                    try Self.forgetServerState(database, id)
                }
                return
            }
            try database.execute(
                sql: """
                    UPDATE contact SET detailsJSON = ?, sortKey = ?, photo = ?, pendingChange = NULL,
                        changeFailed = 0, conflictJSON = NULL, attempts = 0, newHref = NULL, newCard = NULL,
                        revision = revision + 1 WHERE id = ?
                    """, arguments: [ContactRecords.encode(details), details.sortKey, photo, id.raw])
            if (row["href"] as String?) != nil {
                try Self.forgetServerState(database, id)
            }
            try ContactRecords.reindex(database, id.raw, account: (row["accountId"] as String?) ?? "", details)
        }
        try announce(contact: id)
    }

    /// The account's contacts whose stored details can't be read, with the server's card if any.
    public func unreadableContacts(_ account: AccountID) throws(StoreError) -> [(contact: ContactID, vcard: Data?)] {
        try read { database in
            let rows = try Row.fetchAll(
                database, sql: "SELECT id, detailsJSON, vcard FROM contact WHERE accountId = ? ORDER BY id",
                arguments: [account.raw.uuidString])
            return rows.compactMap { row in
                guard let id = row["id"] as Int64?, ContactRecords.decode(row["detailsJSON"] as String?) == nil
                else { return nil }
                return (ContactID(raw: id), row["vcard"] as Data?)
            }
        }
    }

    /// Unreadable details written again, read from the server's card (or empty without one). A
    /// queued create or edit of them can't be known any more: it is marked failed, not sent.
    public func repairDetails(_ id: ContactID, _ details: ContactDetails, photo: Data?) throws(StoreError) {
        try write { database in
            let row = try Self.contactRow(database, id)
            try database.execute(
                sql: """
                    UPDATE contact SET detailsJSON = ?, sortKey = ?, photo = ?,
                        changeFailed = CASE WHEN pendingChange IN ('create', 'update') THEN 1 ELSE changeFailed END,
                        pendingChange = CASE WHEN pendingChange = 'delete' THEN 'delete' ELSE NULL END
                    WHERE id = ?
                    """, arguments: [ContactRecords.encode(details), details.sortKey, photo, id.raw])
            try ContactRecords.reindex(database, id.raw, account: (row["accountId"] as String?) ?? "", details)
        }
        try announce(contact: id)
    }

    /// CardDAV was turned off for the account: its address books and contacts go from this phone
    /// (the server keeps them), unsent changes with them.
    public func clearContacts(of account: AccountID) throws(StoreError) {
        try write { database in
            try database.execute(
                sql: "DELETE FROM address_book WHERE accountId = ?", arguments: [account.raw.uuidString])
        }
    }

    /// How many of the account's contact changes are not on the server yet.
    public func pendingContactChangeCount(_ account: AccountID) throws(StoreError) -> Int {
        try read { database in
            try Int.fetchOne(
                database, sql: "SELECT COUNT(*) FROM contact WHERE accountId = ? AND pendingChange IS NOT NULL",
                arguments: [account.raw.uuidString]) ?? 0
        }
    }

    /// The server may have changed the contact while its failure waited, which sync did not apply:
    /// its ETag and its book's sync token go, so the next sync lists the book again and fetches it.
    private static func forgetServerState(_ database: Database, _ id: ContactID) throws {
        try database.execute(sql: "UPDATE contact SET etag = NULL WHERE id = ?", arguments: [id.raw])
        try database.execute(
            sql: "UPDATE address_book SET syncToken = NULL WHERE id = (SELECT addressBookId FROM contact WHERE id = ?)",
            arguments: [id.raw])
    }

    static func requireReadable(_ database: Database, _ id: ContactID) throws {
        let json = try String.fetchOne(
            database, sql: "SELECT detailsJSON FROM contact WHERE id = ?", arguments: [id.raw])
        if ContactRecords.decode(json) == nil { throw StoreError.unreadableContact }
    }
}
