// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
public import OutwrightModel

/// What a tapped new-mail notice opens: its message, or for the summary of many, its account's
/// Inbox.
public struct MessageRequest: Sendable, Equatable {
    public let message: MessageID?
    public let account: AccountID?

    public init(message: MessageID?, account: AccountID?) {
        self.message = message
        self.account = account
    }

    /// From a tapped notice's `userInfo` (as `SystemNewMailNotices` writes it); nil when it names
    /// neither a message nor an account.
    public init?(userInfo: [AnyHashable: Any]) {
        let number: Int64? = (userInfo["message"] as? Int64) ?? (userInfo["message"] as? Int).map(Int64.init)
        let account = (userInfo["account"] as? String).flatMap(UUID.init(uuidString:)).map { AccountID(raw: $0) }
        guard number != nil || account != nil else { return nil }
        self.init(message: number.map { MessageID(raw: $0) }, account: account)
    }
}
