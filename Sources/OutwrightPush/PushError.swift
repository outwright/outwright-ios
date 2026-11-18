// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/// Why a push operation failed. Descriptions never carry a secret or a URL path.
public enum PushError: Error, Sendable, Equatable, CustomStringConvertible {
    case http(Int)
    case limit
    case rateLimited
    case malformed
    case transport
    case crypto
    case jmap
    case attest
    case timeout
    /// Push was asked for before APNs gave the app a device token.
    case noDeviceToken
    /// The push settings or keys could not be kept (registry file or keychain).
    case storage
    /// The account's mail server could not be read to set the push starting point.
    case mailServer
    /// No push method of this build offers push for the account.
    case unsupported
    /// The mail server refused to set up push (a METADATA write or the check message).
    case serverRefused
    /// The mail server took the setup, but nothing came back from it: its push is not set up.
    case notSetUp
    /// A push address that is not one of the relay's (pasted, or gone since).
    case unknownAddress

    public var description: String {
        switch self {
        case let .http(code): "push relay answered HTTP \(code)"
        case .limit: "subscription limit reached"
        case .rateLimited: "push relay rate limit"
        case .malformed: "malformed push relay answer"
        case .transport: "push relay unreachable"
        case .crypto: "push cryptography failed"
        case .jmap: "JMAP push failed"
        case .attest: "device attestation failed"
        case .timeout: "push timed out"
        case .noDeviceToken: "no push device token yet"
        case .storage: "push settings could not be saved"
        case .mailServer: "mail server unreachable for push"
        case .unsupported: "no push for this mail server"
        case .serverRefused: "mail server refused push setup"
        case .notSetUp: "mail server not set up for push"
        case .unknownAddress: "not a known push address"
        }
    }
}
