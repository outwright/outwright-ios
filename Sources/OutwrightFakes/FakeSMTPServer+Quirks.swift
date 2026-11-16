// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/// Servers that differ from the usual fake: another password, other EHLO lines, a greeting of
/// the test's own.
extension FakeSMTPServer {
    /// From now on the account's password is `password` (one with CR or LF, say).
    public func acceptPassword(_ password: String) {
        acceptedPassword = password
    }

    /// From now on every recipient is taken, whatever the server was made to refuse.
    public func acceptAllRecipients() {
        refusedOnce = [:]
        rejectRecipient = nil
    }

    /// The next RCPT TO for `recipient` is refused with `code`; after that it is taken.
    public func refuseRecipientOnce(_ recipient: String, code: Int) {
        refusedOnce[recipient] = code
    }

    /// EHLO answers with these lines (after the first `250-`), instead of the usual ones.
    public func announce(_ lines: [String]) {
        ehloLines = lines
    }

    /// A new connection is greeted with these raw lines, as they are, instead of `220 ...`.
    public func greet(with lines: [String]) {
        greeting = lines
    }
}
