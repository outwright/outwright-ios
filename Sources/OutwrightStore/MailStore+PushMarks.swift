// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
import GRDB
public import OutwrightModel

/// How far each pushed account's Inbox has been announced, by the same rules as local notices
/// (`MailStore+NewMailNotices.swift`) but in a table of its own: a push mark never reads as local
/// notices being on.
extension MailStore {
    /// Sets the mark at the Inbox's newest message when the account has none, so what was there
    /// before the first push is never announced; a mark already there stays.
    public func markPushedInboxIfNew(_ account: AccountID, now: Date = Date()) throws(StoreError) {
        try write { database in
            let id = account.raw.uuidString
            guard try Bool.fetchOne(
                database, sql: "SELECT 1 FROM push_mail_mark WHERE accountId = ?", arguments: [id]) == nil
            else { return }
            try Self.markNewest(database, .pushes, id, now: now)
        }
    }

    /// The unread Inbox messages above the push mark, oldest first; the mark moves past them (see
    /// `claimNewInboxMail`).
    public func claimPushedInboxMail(_ account: AccountID, now: Date = Date()) throws(StoreError) -> [MessageRow] {
        try write { database in try Self.claim(database, .pushes, account.raw.uuidString, now: now) }
    }
}
