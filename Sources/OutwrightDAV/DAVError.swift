// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// Why a DAV request failed. No case carries a credential.
public enum DAVError: Error, Sendable, Equatable {
    /// The connection failed or was cut.
    case net
    /// Plain `http` to a host that is not loopback; refused before any request.
    case plainRefused
    /// The server refused the user and password.
    case unauthorized
    case notFound
    /// The resource changed on the server since its ETag was read (412).
    case preconditionFailed
    /// The server refused an attendee's change to what the organiser controls (RFC 6638 › 3.2.2.1,
    /// the `allowed-attendee-scheduling-object-change` condition), whatever status it came with.
    case attendeeChangeRefused
    /// The server no longer knows the sync token; sync again from scratch.
    case tokenInvalid
    /// A redirect led to a host outside the trusted ones; not followed.
    case offDomainRedirect(host: String)
    case status(Int)
    /// The server's answer could not be read.
    case malformed
    /// The server's answer is past a cap in `DAVLimits`.
    case tooLarge
}

/// The user and password for a DAV server. It prints, debug-prints and dumps as
/// `<credentials>`; only the request builder reads the password.
public struct DAVCredentials: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let user: String
    public let password: String

    public init(user: String, password: String) {
        self.user = user
        self.password = password
    }

    public var description: String { "<credentials>" }
    public var debugDescription: String { "<credentials>" }
    public var customMirror: Mirror { Mirror(self, children: []) }

    /// The value of an `Authorization` header for Basic authentication.
    var basic: String {
        "Basic " + Data("\(user):\(password)".utf8).base64EncodedString()
    }
}
