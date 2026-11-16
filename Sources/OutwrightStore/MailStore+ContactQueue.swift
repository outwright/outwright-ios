// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
import GRDB
public import OutwrightModel

// swiftlint:disable large_tuple
extension MailStore {
    // MARK: The queue

    /// `revision` counts the owner's edits of the contact: hand it back with the outcome of the send.
    public func pendingContactChanges(_ account: AccountID) throws(StoreError) -> [(
        contact: ContactID, change: ContactChange, href: String?, etag: String?, vcard: Data?,
        book: AddressBookID, revision: Int
    )] {
        try read { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT id, addressBookId, href, etag, vcard, pendingChange, revision FROM contact
                    WHERE accountId = ? AND pendingChange IS NOT NULL ORDER BY id
                    """, arguments: [account.raw.uuidString])
            return rows.compactMap { row in
                guard let id = row["id"] as Int64?, let book = row["addressBookId"] as Int64?,
                    let change = (row["pendingChange"] as String?).flatMap(ContactChange.init(rawValue:))
                else { return nil }
                return (
                    ContactID(raw: id), change, row["href"] as String?, row["etag"] as String?,
                    row["vcard"] as Data?, AddressBookID(raw: book), (row["revision"] as Int?) ?? 0
                )
            }
        }
    }

    /// Where a create goes and the card it starts from, chosen at its first send and kept, so a
    /// send whose answer was lost is sent again to the same place with the same UID.
    public func createTarget(_ id: ContactID) throws(StoreError) -> (href: String, vcard: Data)? {
        try read { database in
            guard
                let row = try Row.fetchOne(
                    database, sql: "SELECT newHref, newCard FROM contact WHERE id = ?", arguments: [id.raw]),
                let href = row["newHref"] as String?, let card = row["newCard"] as Data?
            else { return nil }
            return (href, card)
        }
    }

    public func setCreateTarget(_ id: ContactID, href: String, vcard: Data) throws(StoreError) {
        try write { database in
            try database.execute(
                sql: "UPDATE contact SET newHref = ?, newCard = ? WHERE id = ?", arguments: [href, vcard, id.raw])
        }
    }

    /// The contact's queued change and revision, nil when the contact is gone.
    private static func queued(_ database: Database, _ id: ContactID) throws -> (change: String?, revision: Int)? {
        guard
            let row = try Row.fetchOne(
                database, sql: "SELECT pendingChange, revision FROM contact WHERE id = ?", arguments: [id.raw])
        else { return nil }
        return (row["pendingChange"] as String?, (row["revision"] as Int?) ?? 0)
    }

    /// The server took the change that was `revision` of the contact: the card is now as sent (a
    /// delete removes it). If the owner has edited since, the server's result is recorded (the card
    /// has an address and a tag now) and the newer change stays queued against it.
    ///
    /// `card` is the details as read from `vcard`: where each entry sits in it, so the next edit
    /// goes to the right entry. An edit made since was counted in the card before the send, so its
    /// entries forget their places.
    public func contactChangeDone(
        _ id: ContactID, href: String, etag: String?, vcard: Data, revision: Int, card: ContactDetails? = nil
    ) throws(StoreError) {
        try write { database in
            guard let now = try Self.queued(database, id) else { return }
            let held = ContactRecords.decode(
                try String.fetchOne(database, sql: "SELECT detailsJSON FROM contact WHERE id = ?", arguments: [id.raw]))
            if now.revision == revision {
                if now.change == ContactChange.delete.rawValue {
                    try database.execute(sql: "DELETE FROM contact WHERE id = ?", arguments: [id.raw])
                    return
                }
                let placed = held.map { card.map($0.originsAdopted(from:)) ?? $0.withoutOrigins }
                try database.execute(
                    sql: """
                        UPDATE contact SET href = ?, etag = ?, vcard = ?, pendingChange = NULL,
                            newHref = NULL, newCard = NULL, detailsJSON = COALESCE(?, detailsJSON),
                            changeFailed = 0, attempts = 0 WHERE id = ?
                        """, arguments: [href, etag, vcard, placed.map(ContactRecords.encode), id.raw])
                return
            }
            try database.execute(
                sql: """
                    UPDATE contact SET href = ?, etag = ?, vcard = ?, attempts = 0, newHref = NULL, newCard = NULL,
                        detailsJSON = COALESCE(?, detailsJSON),
                        pendingChange = CASE WHEN pendingChange = 'create' THEN 'update' ELSE pendingChange END
                    WHERE id = ?
                    """, arguments: [href, etag, vcard, held.map { ContactRecords.encode($0.withoutOrigins) }, id.raw])
        }
    }

    /// The server held a newer card (a 412): its version becomes the contact, and the owner's
    /// details go to `conflict`, with any edit made while the send was in flight, so none is sent
    /// over the server's change. A queued delete is not sent: the contact comes back as the server's
    /// card, marked as a failed change. With nothing queued (the owner discarded the change during
    /// the send) the server's card is simply taken.
    public func contactChangeConflicted(
        _ id: ContactID, server: (etag: String, vcard: Data, details: ContactDetails)
    ) throws(StoreError) {
        try write { database in
            let row = try Self.contactRow(database, id)
            let queued = (row["pendingChange"] as String?).flatMap(ContactChange.init(rawValue:))
            switch queued {
            case .create?, .update?:
                // The owner's version, whose entries' places were in a card no longer held.
                let own = ContactRecords.decode(
                    try String.fetchOne(
                        database, sql: "SELECT detailsJSON FROM contact WHERE id = ?", arguments: [id.raw]))
                try database.execute(
                    sql: "UPDATE contact SET conflictJSON = COALESCE(?, detailsJSON) WHERE id = ?",
                    arguments: [own.map { ContactRecords.encode($0.withoutOrigins) }, id.raw])
            case .delete?:
                try database.execute(sql: "UPDATE contact SET conflictJSON = NULL WHERE id = ?", arguments: [id.raw])
            case nil:
                break
            }
            try database.execute(
                sql: """
                    UPDATE contact SET etag = ?, vcard = ?, detailsJSON = ?, sortKey = ?, pendingChange = NULL,
                        changeFailed = ?, attempts = 0 WHERE id = ?
                    """,
                arguments: [
                    server.etag, server.vcard, ContactRecords.encode(server.details), server.details.sortKey,
                    queued == .delete, id.raw
                ])
            try ContactRecords.reindex(
                database, id.raw, account: (row["accountId"] as String?) ?? "", server.details)
        }
    }

    /// The change cannot be sent: it is dropped from the queue and the contact marked. A newer edit
    /// than the one sent stays queued.
    public func contactChangeFailed(_ id: ContactID, revision: Int) throws(StoreError) {
        try write { database in
            try database.execute(
                sql: "UPDATE contact SET pendingChange = NULL, changeFailed = 1 WHERE id = ? AND revision = ?",
                arguments: [id.raw, revision])
        }
    }

    /// The server could not take the change that is `revision` of the contact this time (its own
    /// trouble, not the connection's): counts the try and returns how many there have been.
    public func contactChangeAttempted(_ id: ContactID, revision: Int) throws(StoreError) -> Int {
        try write { database in
            try database.execute(
                sql: "UPDATE contact SET attempts = attempts + 1 WHERE id = ? AND revision = ?",
                arguments: [id.raw, revision])
            return try Int.fetchOne(database, sql: "SELECT attempts FROM contact WHERE id = ?", arguments: [id.raw])
                ?? 0
        }
    }

    // MARK: Conflicts

    /// Queues the owner's version over the server's, which is now the one held. If the owner has
    /// edited since the conflict, that edit is kept and the conflict copy dropped.
    public func applyConflictAgain(_ id: ContactID) throws(StoreError) {
        try write { database in
            let row = try Self.contactRow(database, id)
            guard
                let own = ContactRecords.decode(
                    try String.fetchOne(
                        database, sql: "SELECT conflictJSON FROM contact WHERE id = ?", arguments: [id.raw]))
            else { return }
            if (row["pendingChange"] as String?) != nil {
                try database.execute(
                    sql: "UPDATE contact SET conflictJSON = NULL, changeFailed = 0 WHERE id = ?",
                    arguments: [id.raw])
                return
            }
            try database.execute(
                sql: """
                    UPDATE contact SET detailsJSON = ?, sortKey = ?, conflictJSON = NULL, changeFailed = 0,
                        pendingChange = 'update', revision = revision + 1 WHERE id = ?
                    """, arguments: [ContactRecords.encode(own), own.sortKey, id.raw])
            try ContactRecords.reindex(database, id.raw, account: (row["accountId"] as String?) ?? "", own)
        }
        try announce(contact: id)
    }

    public func discardConflict(_ id: ContactID) throws(StoreError) {
        try write { database in
            try database.execute(sql: "UPDATE contact SET conflictJSON = NULL WHERE id = ?", arguments: [id.raw])
        }
    }
}
// swiftlint:enable large_tuple
