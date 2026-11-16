// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
public import OutwrightModel
import UserNotifications

/// One local new-mail notification: a message, or the summary of those past the limit.
public struct LocalMailNotice: Sendable, Equatable {
    public var identifier: String
    public var title: String
    public var body: String
    public var account: AccountID
    /// Nil for the summary.
    public var message: MessageID?

    public init(identifier: String, title: String, body: String, account: AccountID, message: MessageID?) {
        self.identifier = identifier
        self.title = title
        self.body = body
        self.account = account
        self.message = message
    }
}

/// The notices for one account's new mail: the newest `limit` each its own, the rest as one.
public enum NewMailPlan {
    public static let limit = 10
    /// What a protected message shows in a notice when the caller gives no words of its own.
    public static let encryptedBody = "Encrypted message"
    public static let identifierPrefix = "outwright.mail."

    /// `rows` in any order; `more` words "N more" for the summary. The sender's name, else its
    /// address, else `accountName` is the title; the subject is the body. In posting order: iOS
    /// stacks the last posted on top, so the summary comes first and the newest message last. A
    /// protected message's body is `protectedBody` (its subject is never put on a lock screen).
    public static func plan(
        _ rows: [MessageRow], accountName: String, protectedBody: String = encryptedBody,
        more: (Int) -> String
    ) -> [LocalMailNotice] {
        let newest = rows.sorted { $0.uid > $1.uid }
        guard let highest = newest.first else { return [] }
        let prefix = identifierPrefix + highest.accountID.raw.uuidString + "."
        var notices: [LocalMailNotice] = []
        if newest.count > limit {
            notices.append(
                LocalMailNotice(
                    identifier: prefix + "more." + String(highest.uid), title: more(newest.count - limit), body: "",
                    account: highest.accountID, message: nil))
        }
        notices += newest.prefix(limit).reversed().map { row in
            LocalMailNotice(
                identifier: prefix + String(row.uid), title: sender(row, accountName),
                body: row.isProtected ? protectedBody : row.subject,
                account: row.accountID, message: row.id)
        }
        return notices
    }

    private static func sender(_ row: MessageRow, _ accountName: String) -> String {
        let name = (row.from.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        let email = row.from.email.trimmingCharacters(in: .whitespacesAndNewlines)
        return email.isEmpty ? accountName : email
    }
}

/// Where new-mail notices go: the phone's notifications.
public protocol NewMailNotices: Sendable {
    func post(_ notices: [LocalMailNotice]) async
}

/// The notices as iOS local notifications, shown at once, in the order given. Outside an app bundle (a test run) there
/// is no notification centre, and it does nothing.
public struct SystemNewMailNotices: NewMailNotices {
    public init() {}

    public func post(_ notices: [LocalMailNotice]) async {
        guard ["app", "appex"].contains(Bundle.main.bundleURL.pathExtension) else { return }
        let center = UNUserNotificationCenter.current()
        for (index, notice) in notices.enumerated() {
            let content = UNMutableNotificationContent()
            content.title = notice.title
            content.body = notice.body
            // One sound for the lot: the last, newest notice's.
            if index == notices.count - 1 { content.sound = .default }
            content.threadIdentifier = notice.account.raw.uuidString
            var info: [String: Any] = ["account": notice.account.raw.uuidString]
            if let message = notice.message { info["message"] = message.raw }
            content.userInfo = info
            try? await center.add(UNNotificationRequest(identifier: notice.identifier, content: content, trigger: nil))
        }
    }
}
