// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import GRDB
import OutwrightModel

enum ContactRecords {
    static let columns = """
        id, accountId, addressBookId, detailsJSON, photo, conflictJSON, changeFailed, photoFailed
        """

    static func encode(_ details: ContactDetails) -> String {
        guard let data = try? JSONEncoder().encode(details) else { return "{}" }
        return String(bytes: data, encoding: .utf8) ?? "{}"
    }

    static func decode(_ json: String?) -> ContactDetails? {
        guard let data = json?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ContactDetails.self, from: data)
    }

    static func book(_ row: Row) -> AddressBook? {
        guard let account = (row["accountId"] as String?).flatMap({ UUID(uuidString: $0) }),
            let id = row["id"] as Int64?
        else { return nil }
        return AddressBook(
            id: AddressBookID(raw: id), accountID: AccountID(raw: account),
            href: (row["href"] as String?) ?? "", name: (row["name"] as String?) ?? "",
            isReadOnly: ((row["isReadOnly"] as Int?) ?? 0) != 0)
    }

    /// A row selecting `columns`. Nil when stored data is unusable.
    static func contact(_ row: Row) -> Contact? {
        guard let account = (row["accountId"] as String?).flatMap({ UUID(uuidString: $0) }),
            let id = row["id"] as Int64?, let book = row["addressBookId"] as Int64?
        else { return nil }
        let details = decode(row["detailsJSON"] as String?) ?? ContactDetails()
        return Contact(
            id: ContactID(raw: id), accountID: AccountID(raw: account),
            addressBookID: AddressBookID(raw: book), details: details, photo: row["photo"] as Data?,
            conflict: decode(row["conflictJSON"] as String?),
            changeFailed: ((row["changeFailed"] as Int?) ?? 0) != 0,
            photoFailed: ((row["photoFailed"] as Int?) ?? 0) != 0)
    }

    /// Text as searched: lower-case, diacritics folded.
    static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// A contact the owner's change or conflict or failed edit has not been settled for: the server must
    /// not overwrite or remove it.
    static let protected = "(pendingChange IS NOT NULL OR conflictJSON IS NOT NULL OR changeFailed = 1)"

    static func matches(_ details: ContactDetails, _ needle: String) -> Bool {
        let fields = [details.displayName, details.givenName, details.familyName, details.organization]
            + details.emails.map(\.value)
        return fields.contains { folded($0).contains(needle) }
            || folded("\(details.givenName) \(details.familyName)").contains(needle)
    }

    /// Replaces the address lookup rows of a contact with the addresses in `details`.
    static func reindex(_ database: Database, _ id: Int64, account: String, _ details: ContactDetails) throws {
        try database.execute(sql: "DELETE FROM contact_email WHERE contactId = ?", arguments: [id])
        for email in Set(details.emails.prefix(100).map { $0.value.lowercased() }) where !email.isEmpty {
            try database.execute(
                sql: "INSERT INTO contact_email (contactId, accountId, email) VALUES (?, ?, ?)",
                arguments: [id, account, email])
        }
    }
}
