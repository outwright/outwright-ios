// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
import GRDB
public import OutwrightModel

/// A photo waiting to go to a server that keeps photos apart from the contact (Graph).
public struct PhotoToSend: Sendable, Equatable {
    public let contact: ContactID
    /// Where the server keeps the contact.
    public let href: String
    /// Nil: the owner took the photo away.
    public let photo: Data?
    public let revision: Int
    /// The server's copy as last read (Graph's JSON).
    public let serverCopy: Data?
}

extension MailStore {
    // MARK: The owner's edits

    public func createContact(
        _ details: ContactDetails, photo: Data? = nil, in book: AddressBookID
    ) throws(StoreError) -> ContactID {
        let id: ContactID = try write { database in
            guard
                let account = try String.fetchOne(
                    database, sql: "SELECT accountId FROM address_book WHERE id = ?", arguments: [book.raw])
            else { throw StoreError.noSuchAddressBook }
            try Self.requireCardDAV(database, account: account)
            try Self.requireWritable(database, book: book.raw)
            try database.execute(
                sql: """
                    INSERT INTO contact (
                        accountId, addressBookId, detailsJSON, sortKey, photo, photoPending, pendingChange, revision)
                    VALUES (?, ?, ?, ?, ?, ?, 'create', 1)
                    """, arguments: [
                        account, book.raw, ContactRecords.encode(details), details.sortKey, photo,
                        try photo != nil && Self.keepsPhotosApart(database, account: account)
                    ])
            let id = database.lastInsertedRowID
            try ContactRecords.reindex(database, id, account: account, details)
            return ContactID(raw: id)
        }
        try announce(contact: id)
        return id
    }

    public func updateContact(_ id: ContactID, _ details: ContactDetails) throws(StoreError) {
        try updateContact(id, details, photo: .kept)
    }

    /// The owner's edit, with the photo given (nil: none) instead of the one held.
    public func updateContact(_ id: ContactID, _ details: ContactDetails, photo: Data?) throws(StoreError) {
        try updateContact(id, details, photo: .replaced(photo))
    }

    fileprivate enum PhotoEdit {
        case kept
        case replaced(Data?)
    }

    private func updateContact(_ id: ContactID, _ details: ContactDetails, photo: PhotoEdit) throws(StoreError) {
        try write { database in
            let row = try Self.contactRow(database, id)
            try Self.requireCardDAV(database, account: (row["accountId"] as String?) ?? "")
            try Self.requireWritable(database, contact: id.raw)
            try Self.requireReadable(database, id)
            let kind = (row["href"] as String?) == nil ? "create" : "update"
            // A fresh edit supersedes a held conflict; a photo the server did not take goes again.
            try database.execute(
                sql: """
                    UPDATE contact SET detailsJSON = ?, sortKey = ?, pendingChange = ?, changeFailed = 0,
                        conflictJSON = NULL, attempts = 0, revision = revision + 1,
                        photoPending = MAX(photoPending, photoFailed), photoFailed = 0 WHERE id = ?
                    """,
                arguments: [ContactRecords.encode(details), details.sortKey, kind, id.raw])
            if case .replaced(let data) = photo {
                let apart = try Self.keepsPhotosApart(database, account: (row["accountId"] as String?) ?? "")
                try database.execute(
                    sql: "UPDATE contact SET photo = ?, photoPending = ? WHERE id = ?",
                    arguments: [data, apart, id.raw])
            }
            try ContactRecords.reindex(
                database, id.raw, account: (row["accountId"] as String?) ?? "", details)
        }
        try announce(contact: id)
    }

    /// The contact is hidden until the delete is sent. One the server never got stays a queued
    /// delete too (its create may be on the way): the sync drops it without a request, or sends
    /// the delete once the create's answer gives it an address. Its photo no longer goes.
    public func deleteContact(_ id: ContactID) throws(StoreError) {
        let account: String = try write { database in
            let row = try Self.contactRow(database, id)
            try Self.requireCardDAV(database, account: (row["accountId"] as String?) ?? "")
            try Self.requireWritable(database, contact: id.raw)
            try database.execute(
                sql: """
                    UPDATE contact SET pendingChange = 'delete', changeFailed = 0, attempts = 0,
                        photoPending = 0, photoFailed = 0, revision = revision + 1
                    WHERE id = ?
                    """,
                arguments: [id.raw])
            return (row["accountId"] as String?) ?? ""
        }
        if let uuid = UUID(uuidString: account) { announceQueued(AccountID(raw: uuid)) }
    }

    /// The photos the owner gave or took away (nil) that wait to go to a server keeping photos apart
    /// (Graph), for contacts the server has and with no change of their fields queued, failed or held
    /// as a conflict: each with where the server keeps the contact and the contact's revision then.
    public func photosToSend(_ account: AccountID) throws(StoreError) -> [PhotoToSend] {
        try read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT id, href, photo, revision, vcard FROM contact
                    WHERE accountId = ? AND photoPending = 1 AND pendingChange IS NULL AND changeFailed = 0
                        AND conflictJSON IS NULL AND href IS NOT NULL AND href != '' ORDER BY id
                    """, arguments: [account.raw.uuidString]
            ).compactMap { row in
                guard let id = row["id"] as Int64?, let href = row["href"] as String? else { return nil }
                return PhotoToSend(
                    contact: ContactID(raw: id), href: href, photo: row["photo"] as Data?,
                    revision: (row["revision"] as Int?) ?? 0, serverCopy: row["vcard"] as Data?)
            }
        }
    }

    /// The server's copy moved without the details changing (a photo went to Graph): its new tag
    /// and copy are kept, so the next edit is sent against them.
    public func contactServerCopyMoved(_ id: ContactID, etag: String, vcard: Data) throws(StoreError) {
        try write { database in
            try database.execute(
                sql: "UPDATE contact SET etag = ?, vcard = ? WHERE id = ?", arguments: [etag, vcard, id.raw])
        }
    }

    /// The account's contacts come over Graph, which keeps a contact's photo apart from it; a
    /// CardDAV card carries its own.
    private static func keepsPhotosApart(_ database: Database, account: String) throws -> Bool {
        try String.fetchOne(database, sql: "SELECT contactsVia FROM account WHERE id = ?", arguments: [account])
            == "graph"
    }

    /// The photo went out; one changed since (a later revision) still waits.
    public func photoSent(_ id: ContactID, revision: Int) throws(StoreError) {
        try write { database in
            try database.execute(
                sql: "UPDATE contact SET photoPending = 0, attempts = 0 WHERE id = ? AND revision = ?",
                arguments: [id.raw, revision])
        }
    }

    /// The server did not take the photo (refused, or failed every try): it stays the owner's, the
    /// contact is marked failed and shows it, until Try again (`retryFailedPhoto`) or Discard. One
    /// changed since (a later revision) still waits.
    public func photoGivenUp(_ id: ContactID, revision: Int) throws(StoreError) {
        try write { database in
            try database.execute(
                sql: """
                    UPDATE contact SET photoPending = 0, photoFailed = 1, changeFailed = 1, attempts = 0
                    WHERE id = ? AND revision = ?
                    """, arguments: [id.raw, revision])
        }
    }

    /// The owner sends a photo the server did not take once more, with all its tries.
    public func retryFailedPhoto(_ id: ContactID) throws(StoreError) {
        try write { database in
            try database.execute(
                sql: """
                    UPDATE contact SET photoPending = 1, photoFailed = 0, changeFailed = 0, attempts = 0
                    WHERE id = ? AND photoFailed = 1
                    """, arguments: [id.raw])
        }
        try announce(contact: id)
    }

    /// The photo the server keeps apart from the contact (Graph), as read: never over one of the
    /// owner's that waits to be sent or that the server did not take, nor on any failed change.
    public func setServerPhoto(_ id: ContactID, _ photo: Data?) throws(StoreError) {
        try write { database in
            try database.execute(
                sql: """
                    UPDATE contact SET photo = ?
                    WHERE id = ? AND photoPending = 0 AND changeFailed = 0 AND photo IS NOT ?
                    """, arguments: [photo, id.raw, photo])
        }
    }
}
