// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import GRDB
public import OutwrightModel

/// Which iPhone contact each exported contact became. The rows outlive their account on purpose: a
/// removed account's phone contacts are still found, and removed, from them.
extension MailStore {
    public func phoneExports(_ account: AccountID) throws(StoreError) -> [ContactID: String] {
        try read { database in
            let rows = try Row.fetchAll(
                database, sql: "SELECT contactId, phoneIdentifier FROM phone_export WHERE accountId = ?",
                arguments: [account.raw.uuidString])
            var found: [ContactID: String] = [:]
            for row in rows {
                guard let id = row["contactId"] as Int64?, let identifier = row["phoneIdentifier"] as String?
                else { continue }
                found[ContactID(raw: id)] = identifier
            }
            return found
        }
    }

    /// Records the phone contact `contact` became; nil forgets it.
    public func setPhoneExport(_ identifier: String?, for contact: ContactID, account: AccountID) throws(StoreError) {
        try write { database in
            if let identifier {
                try database.execute(
                    sql: """
                        INSERT INTO phone_export (accountId, contactId, phoneIdentifier) VALUES (?, ?, ?)
                        ON CONFLICT(accountId, contactId) DO UPDATE SET phoneIdentifier = excluded.phoneIdentifier
                        """, arguments: [account.raw.uuidString, contact.raw, identifier])
            } else {
                try database.execute(
                    sql: "DELETE FROM phone_export WHERE accountId = ? AND contactId = ?",
                    arguments: [account.raw.uuidString, contact.raw])
            }
        }
    }

    public func clearPhoneExports(_ account: AccountID) throws(StoreError) {
        try write { database in
            try database.execute(
                sql: "DELETE FROM phone_export WHERE accountId = ?", arguments: [account.raw.uuidString])
        }
    }

    /// Every phone contact recorded, for any account.
    public func allPhoneExportIdentifiers() throws(StoreError) -> Set<String> {
        try read { database in
            Set(try String.fetchAll(database, sql: "SELECT phoneIdentifier FROM phone_export"))
        }
    }

    /// Every account with phone contacts or a phone group recorded, stored or not.
    public func phoneExportAccounts() throws(StoreError) -> Set<AccountID> {
        try read { database in
            Set(
                try String.fetchAll(
                    database,
                    sql: "SELECT accountId FROM phone_export UNION SELECT accountId FROM phone_export_group")
                    .compactMap { UUID(uuidString: $0).map(AccountID.init(raw:)) })
        }
    }

    /// The phone group Outwright made or adopted for the account.
    public func phoneExportGroup(_ account: AccountID) throws(StoreError) -> String? {
        try read { database in
            try String.fetchOne(
                database, sql: "SELECT groupIdentifier FROM phone_export_group WHERE accountId = ?",
                arguments: [account.raw.uuidString])
        }
    }

    /// Records the account's phone group; nil forgets it.
    public func setPhoneExportGroup(_ identifier: String?, account: AccountID) throws(StoreError) {
        try write { database in
            if let identifier {
                try database.execute(
                    sql: """
                        INSERT INTO phone_export_group (accountId, groupIdentifier) VALUES (?, ?)
                        ON CONFLICT(accountId) DO UPDATE SET groupIdentifier = excluded.groupIdentifier
                        """, arguments: [account.raw.uuidString, identifier])
            } else {
                try database.execute(
                    sql: "DELETE FROM phone_export_group WHERE accountId = ?", arguments: [account.raw.uuidString])
            }
        }
    }
}
