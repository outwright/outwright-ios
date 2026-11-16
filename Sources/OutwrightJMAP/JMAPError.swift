// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/// Why a JMAP call failed. Descriptions never carry a password, a URL or a server answer.
public enum JMAPError: Error, Sendable, Equatable, CustomStringConvertible {
    case auth
    case http(Int)
    case malformed
    case insecure
    case refused
    /// The server does not have the object (lapsed, or lost in a restore).
    case notFound
    case transport
    case timeout

    public var description: String {
        switch self {
        case .auth: "JMAP sign-in refused"
        case let .http(code): "JMAP server answered HTTP \(code)"
        case .malformed: "malformed JMAP answer"
        case .insecure: "JMAP needs https"
        case .refused: "JMAP server refused the request"
        case .notFound: "JMAP server does not have it"
        case .transport: "JMAP server unreachable"
        case .timeout: "JMAP request timed out"
        }
    }
}
