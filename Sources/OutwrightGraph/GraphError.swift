// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/// What went wrong talking to Microsoft Graph. Never carries server text or a token.
public enum GraphError: Error, Sendable, Equatable {
    /// The connection failed, or an answer never came.
    case net
    /// 401 after one renewal of the token.
    case unauthorized
    case notFound
    /// 403: the token lacks the permission (a scope not consented to).
    case forbidden
    /// 409: what is being made is there already.
    case conflict
    /// 412: the `If-Match` ETag is not the server's any more.
    case preconditionFailed
    /// 429 or 503: the server asks to come back later.
    case throttled
    case status(Int)
    /// An answer that is not the JSON Graph sends.
    case malformed
    /// An answer, or a listing, past its cap.
    case tooLarge
    /// A link that leaves the Graph host.
    case offHost
    /// Plain `http` to anything but loopback.
    case plainRefused
}
