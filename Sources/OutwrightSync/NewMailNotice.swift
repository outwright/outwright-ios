// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import OutwrightModel

/// The text a push's new-mail notification shows: one message by its sender and subject, several
/// by their count and the newest.
public struct NewMailNotice: Sendable, Equatable {
    public var title: String
    public var body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }

    /// The words for the rows a push's Inbox update brought; nil for none. The newest (highest
    /// UID) speaks for several. A protected message's subject is never shown: `protectedBody` is.
    public init?(
        _ rows: [MessageRow], accountName: String, protectedBody: String = NewMailPlan.encryptedBody,
        many: (Int) -> String
    ) {
        guard let newest = rows.max(by: { $0.uid < $1.uid }) else {
            return nil
        }
        let sender = NewMailPlan.sender(newest, accountName)
        let subject = newest.isProtected ? protectedBody : newest.subject
        if rows.count == 1 {
            self.init(title: sender, body: subject)
        } else {
            self.init(title: many(rows.count), body: "\(sender): \(subject)")
        }
    }
}
