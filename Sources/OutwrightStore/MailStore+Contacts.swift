// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
import GRDB
public import OutwrightModel

// swiftlint:disable large_tuple
extension MailStore {
    // MARK: Address books

    public func addressBooks(_ account: AccountID) throws(StoreError) -> [AddressBook] {
        try read { database in
            try Row.fetchAll(
                database,
                sql: "SELECT * FROM address_book WHERE accountId = ? AND gone = 0 ORDER BY name, id",
                arguments: [account.raw.uuidString]
            ).compactMap(ContactRecords.book)
        }
    }

    /// Books are matched by href. A book no longer given is removed with its contacts, except the
    /// contacts with a queued change: those stay (marked `changeFailed`, the change dropped) in a
    /// book that is no longer listed. A contact the owner deleted goes with the book.
    public func replaceAddressBooks(
        _ books: [(href: String, name: String, isReadOnly: Bool)], for account: AccountID
    ) throws(StoreError) {
        try write { database in
            let key = account.raw.uuidString
            // An account without CardDAV keeps no books (one turned off during a sync stays empty).
            let books = try Self.hasCardDAV(database, account: key) ? books : []
            for book in books.prefix(100) {
                try database.execute(
                    sql: """
                        INSERT INTO address_book (accountId, href, name, isReadOnly) VALUES (?, ?, ?, ?)
                        ON CONFLICT(accountId, href) DO UPDATE SET name = excluded.name,
                            isReadOnly = excluded.isReadOnly, gone = 0
                        """, arguments: [key, book.href, book.name, book.isReadOnly])
            }
            let keep = Set(books.map(\.href))
            let known = try Row.fetchAll(
                database, sql: "SELECT id, href FROM address_book WHERE accountId = ?", arguments: [key])
            for book in known {
                guard let id = book["id"] as Int64?, let href = book["href"] as String?, !keep.contains(href)
                else { continue }
                try database.execute(
                    sql: """
                        DELETE FROM contact WHERE addressBookId = ?
                            AND (pendingChange = 'delete' OR NOT \(ContactRecords.protected))
                        """,
                    arguments: [id])
                try database.execute(
                    sql: """
                        UPDATE contact SET changeFailed = 1, pendingChange = NULL
                        WHERE addressBookId = ? AND conflictJSON IS NULL
                        """,
                    arguments: [id])
                let left = try Int.fetchOne(
                    database, sql: "SELECT COUNT(*) FROM contact WHERE addressBookId = ?", arguments: [id])
                if (left ?? 0) == 0 {
                    try database.execute(sql: "DELETE FROM address_book WHERE id = ?", arguments: [id])
                } else {
                    try database.execute(sql: "UPDATE address_book SET gone = 1 WHERE id = ?", arguments: [id])
                }
            }
        }
    }

    public func syncToken(_ book: AddressBookID) throws(StoreError) -> String? {
        try read { database in
            try String.fetchOne(
                database, sql: "SELECT syncToken FROM address_book WHERE id = ?", arguments: [book.raw])
        }
    }

    public func setSyncToken(_ token: String?, for book: AddressBookID) throws(StoreError) {
        try write { database in
            try database.execute(
                sql: "UPDATE address_book SET syncToken = ? WHERE id = ?", arguments: [token, book.raw])
        }
    }

    // MARK: From the server

    /// href to ETag of every card of the book that the server has (not one only created here).
    public func remoteETags(_ book: AddressBookID) throws(StoreError) -> [String: String] {
        try read { database in
            var result: [String: String] = [:]
            let rows = try Row.fetchAll(
                database,
                sql: "SELECT href, etag FROM contact WHERE addressBookId = ? AND href IS NOT NULL",
                arguments: [book.raw])
            for row in rows {
                if let href = row["href"] as String? { result[href] = (row["etag"] as String?) ?? "" }
            }
            return result
        }
    }

    /// Stores a card as the server has it. A contact with a change queued is left alone: false.
    @discardableResult
    // swiftlint:disable:next function_parameter_count
    public func upsertRemote(
        href: String, etag: String, vcard: Data, details: ContactDetails, photo: Data?,
        keepsPhoto: Bool = false, in book: AddressBookID
    ) throws(StoreError) -> Bool {
        try write { database in
            guard
                let account = try String.fetchOne(
                    database, sql: "SELECT accountId FROM address_book WHERE id = ?", arguments: [book.raw])
            else { throw StoreError.noSuchAddressBook }
            let existing = try Row.fetchOne(
                database, sql: """
                    SELECT id, pendingChange, changeFailed, conflictJSON FROM contact
                    WHERE addressBookId = ? AND href = ?
                    """,
                arguments: [book.raw, href])
            let json = ContactRecords.encode(details)
            if let existing, let id = existing["id"] as Int64? {
                if (existing["pendingChange"] as String?) != nil { return false }
                if ((existing["changeFailed"] as Int?) ?? 0) != 0 { return false }
                try database.execute(
                    sql: """
                        UPDATE contact SET etag = ?, vcard = ?, detailsJSON = ?, sortKey = ?,
                            photo = CASE WHEN ? THEN photo ELSE ? END
                        WHERE id = ?
                        """, arguments: [etag, vcard, json, details.sortKey, keepsPhoto, photo, id])
                try ContactRecords.reindex(database, id, account: account, details)
                return true
            }
            try database.execute(
                sql: """
                    INSERT INTO contact (accountId, addressBookId, href, etag, vcard, detailsJSON, sortKey, photo)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [account, book.raw, href, etag, vcard, json, details.sortKey, photo])
            try ContactRecords.reindex(database, database.lastInsertedRowID, account: account, details)
            return true
        }
    }

    /// Drops the cards the server no longer has, except those with a change queued.
    public func removeRemote(hrefs: [String], in book: AddressBookID) throws(StoreError) {
        try write { database in
            for href in hrefs {
                try database.execute(
                    sql: """
                        DELETE FROM contact
                        WHERE addressBookId = ? AND href = ? AND NOT \(ContactRecords.protected)
                        """,
                    arguments: [book.raw, href])
            }
        }
    }

    // MARK: Reading

    /// The first value is now; another follows each change to the stored contacts, address books or
    /// accounts (and, with `includingMail`, to the mail, with `includingEvents` to the events): any
    /// write to those tables, not only one that changes how many rows they hold. Only the newest
    /// unseen change is kept. If the database can't be watched any more, the stream ends with that
    /// error.
    public func observeContacts(
        includingMail: Bool = false, includingEvents: Bool = false
    ) -> AsyncThrowingStream<Void, any Error> {
        var tables = ["contact", "address_book", "account"]
        if includingMail { tables.append("message") }
        if includingEvents { tables.append("event") }
        let observation = ValueObservation.tracking(regions: tables.map { Table($0) }) { _ in () }
        let queue = queue
        return AsyncThrowingStream(Void.self, bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                do {
                    for try await _ in observation.values(in: queue) { continuation.yield() }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Sorted by family name (else name). `books` nil means all; `text` matches name, organisation or
    /// address, ignoring case and accents. A contact whose deletion is queued is hidden.
    public func contacts(
        in books: Set<AddressBookID>?, matching text: String?
    ) throws(StoreError) -> [Contact] {
        let needle = ContactRecords.folded((text ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        return try read { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT \(ContactRecords.columns) FROM contact
                    WHERE (pendingChange IS NULL OR pendingChange != 'delete') ORDER BY sortKey, id
                    """)
            return rows.compactMap(ContactRecords.contact).filter { contact in
                (books?.contains(contact.addressBookID) ?? true)
                    && (needle.isEmpty || ContactRecords.matches(contact.details, needle))
            }
        }
    }

    public func contact(_ id: ContactID) throws(StoreError) -> Contact? {
        try read { database in
            try Row.fetchOne(
                database, sql: "SELECT \(ContactRecords.columns) FROM contact WHERE id = ?",
                arguments: [id.raw]
            ).flatMap(ContactRecords.contact)
        }
    }

    /// Where the server keeps the contact; nil before its first send.
    public func contactHref(_ id: ContactID) throws(StoreError) -> String? {
        try read { database in
            try String.fetchOne(database, sql: "SELECT href FROM contact WHERE id = ?", arguments: [id.raw])
        }
    }

    /// The contact is held and not waiting to be deleted.
    public func contactIsShown(_ id: ContactID) throws(StoreError) -> Bool {
        try read { database in
            try Bool.fetchOne(
                database, sql: """
                    SELECT 1 FROM contact WHERE id = ? AND (pendingChange IS NULL OR pendingChange != 'delete')
                    """, arguments: [id.raw]) ?? false
        }
    }

    public func contacts(withEmail email: String) throws(StoreError) -> [Contact] {
        try read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT \(ContactRecords.columns) FROM contact
                    WHERE (pendingChange IS NULL OR pendingChange != 'delete')
                        AND id IN (SELECT contactId FROM contact_email WHERE email = ?)
                    ORDER BY sortKey, id
                    """, arguments: [email.lowercased()]
            ).compactMap(ContactRecords.contact)
        }
    }

    /// Lower-case addresses of the account's contacts.
    public func contactEmails(_ account: AccountID) throws(StoreError) -> Set<String> {
        try read { database in
            Set(
                try String.fetchAll(
                    database,
                    sql: """
                        SELECT e.email FROM contact_email e JOIN contact c ON c.id = e.contactId
                        WHERE e.accountId = ? AND (c.pendingChange IS NULL OR c.pendingChange != 'delete')
                        """, arguments: [account.raw.uuidString]))
        }
    }

    /// Whether the account has somewhere its contacts come from: a CardDAV address, or
    /// Graph.
    static func hasCardDAV(_ database: Database, account: String) throws -> Bool {
        let row = try Row.fetchOne(
            database, sql: "SELECT cardDAV, contactsVia FROM account WHERE id = ?", arguments: [account])
        return hasContactSource(row)
    }

    /// The owner's edits go nowhere for an account without CardDAV (or Graph).
    static func requireCardDAV(_ database: Database, account: String) throws {
        if try !hasCardDAV(database, account: account) { throw StoreError.noCardDAV }
    }

    /// The owner's edits do not go to a read-only address book.
    static func requireWritable(_ database: Database, book: Int64) throws {
        let readOnly = try Int.fetchOne(
            database, sql: "SELECT isReadOnly FROM address_book WHERE id = ?", arguments: [book])
        if (readOnly ?? 0) != 0 { throw StoreError.readOnlyAddressBook }
    }

    static func requireWritable(_ database: Database, contact: Int64) throws {
        let readOnly = try Int.fetchOne(
            database,
            sql: """
                SELECT b.isReadOnly FROM contact c JOIN address_book b ON b.id = c.addressBookId WHERE c.id = ?
                """, arguments: [contact])
        if (readOnly ?? 0) != 0 { throw StoreError.readOnlyAddressBook }
    }

    static func contactRow(_ database: Database, _ id: ContactID) throws -> Row {
        guard
            let row = try Row.fetchOne(
                database, sql: "SELECT id, accountId, href, pendingChange, revision FROM contact WHERE id = ?",
                arguments: [id.raw])
        else { throw StoreError.noSuchContact }
        return row
    }

    func announce(contact id: ContactID) throws(StoreError) {
        let account = try read { database in
            try String.fetchOne(
                database, sql: "SELECT accountId FROM contact WHERE id = ?", arguments: [id.raw])
        }
        if let account, let uuid = UUID(uuidString: account) { announceQueued(AccountID(raw: uuid)) }
    }

    // MARK: Mail and contacts

    /// Moves mail of the account from a contact out of Other into Focused, unless the owner sorted
    /// that sender by hand. Returns how many messages moved.
    public func focusContactsMail(_ account: AccountID) throws(StoreError) -> Int {
        try write { database in
            try database.execute(
                sql: """
                    UPDATE message SET inboxClass = 'focused'
                    WHERE accountId = ?1 AND inboxClass = 'other'
                        AND swiftLowercaseString(fromEmail) IN (
                            SELECT e.email FROM contact_email e JOIN contact c ON c.id = e.contactId
                            WHERE e.accountId = ?1 AND (c.pendingChange IS NULL OR c.pendingChange != 'delete'))
                        AND swiftLowercaseString(fromEmail) NOT IN (SELECT email FROM sender_override)
                    """, arguments: [account.raw.uuidString])
            return database.changesCount
        }
    }

    /// Mail sent by, or to or copied to, an address; newest first.
    public func messages(involving email: String, limit: Int) throws(StoreError) -> [MessageRow] {
        let key = email.lowercased()
        let escaped = key.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_").replacingOccurrences(of: "/", with: "%")
        let pattern = "%\(escaped)%"
        let wanted = max(0, min(limit, 1_000))
        return try read { database in
            var found: [MessageRow] = []
            let cursor = try Row.fetchCursor(
                database,
                sql: """
                    SELECT \(Records.messageColumns) FROM message m
                    WHERE swiftLowercaseString(m.fromEmail) = ?1 OR swiftLowercaseString(m.toJSON) LIKE ?2 ESCAPE '\\'
                        OR swiftLowercaseString(m.ccJSON) LIKE ?2 ESCAPE '\\'
                    ORDER BY m.date DESC, m.id DESC
                    """, arguments: [key, pattern])
            while found.count < wanted, let row = try cursor.next() {
                guard let message = Records.message(row) else { continue }
                let recipients = (message.to + message.cc).map { $0.email.lowercased() }
                if message.from.email.lowercased() == key || recipients.contains(key) { found.append(message) }
            }
            return found
        }
    }

    /// The addresses the account has written to or holds as contacts: mail from them is not bulk.
    public func knownSenders(_ account: AccountID) throws(StoreError) -> Set<String> {
        try correspondents(account).union(contactEmails(account))
    }
}
// swiftlint:enable large_tuple
