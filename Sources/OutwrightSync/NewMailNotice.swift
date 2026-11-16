// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/// The text a new-mail notification shows once a probe has found the mail: one message by its
/// sender and subject, several by their count and the newest.
public struct NewMailNotice: Sendable, Equatable {
    public var title: String
    public var body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }

    /// Nil when the probe found nothing to show: the notification keeps its generic text.
    /// `accountName` stands in for a sender without a name; `many` words "N new messages";
    /// `protectedBody` is what a protected message shows in place of its subject.
    public init?(
        _ result: ProbeResult, accountName: String, protectedBody: String = NewMailPlan.encryptedBody,
        many: (Int) -> String
    ) {
        guard case .mail(let mail, let count) = result, let newest = mail.first, count > 0 else {
            return nil
        }
        let sender = newest.sender.isEmpty ? accountName : newest.sender
        let subject = newest.isProtected ? protectedBody : newest.subject
        if count == 1 {
            self.init(title: sender, body: subject)
        } else {
            self.init(title: many(count), body: "\(sender): \(subject)")
        }
    }
}
