// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import OutwrightNet

/// Why sending failed. Carries no password; `rejected` text is the server's, clamped.
public enum SMTPError: Error, Sendable, Equatable {
    case net(NetError)
    /// `.startTLS` was asked for and the server does not offer it; nothing was sent.
    case startTLSNotOffered
    case authenticationFailed
    /// `AUTH XOAUTH2` was asked for and the server does not offer it; no token was sent.
    case xoauth2NotOffered
    case rejected(code: Int, text: String)
    /// The server would not take a session at all (its greeting, EHLO or STARTTLS refused): it
    /// said nothing about the message, which may go on a later try.
    case sessionRefused(code: Int, text: String)
    /// The server refused a recipient (`RCPT TO`); the text is the server's, clamped.
    case recipientRejected(code: Int, text: String)
    case noRecipients
    /// A recipient has nothing left once what may not go in a path is taken out; nothing was sent.
    case invalidRecipient
    /// An address or a header needs SMTPUTF8 (RFC 6531) and the server does not offer it; nothing was sent.
    case smtpUTF8NotOffered
}
