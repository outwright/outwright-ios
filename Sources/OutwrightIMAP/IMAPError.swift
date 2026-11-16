// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import OutwrightNet

/// Why an IMAP operation failed. Never carries a credential or message text; `no` and `bad`
/// carry the server's own words, at most 200 characters.
public enum IMAPError: Error, Sendable, Equatable {
    case net(NetError)
    /// The endpoint asked for STARTTLS and the server did not offer it; nothing was sent.
    case startTLSNotOffered
    case authenticationFailed
    // swiftlint:disable:next identifier_name
    case no(String)
    /// A NO the server marked as passing (RFC 5530 `UNAVAILABLE`, `SERVERBUG`): it could not
    /// answer now, which is not a refusal.
    case unavailable(String)
    case bad(String)
    /// The server said something IMAP does not allow, or more than we accept.
    case protocolViolation
    case extensionMissing
    case folderMissing(String)
    /// The task was cancelled while it waited for its turn on the connection; nothing was sent.
    case cancelled

    static let textLimit = 200

    static func clamp(_ text: String) -> String {
        String(text.prefix(textLimit))
    }
}
