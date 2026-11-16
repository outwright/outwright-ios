// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/// How a connection is protected.
public enum TransportSecurity: String, Codable, Sendable {
    /// TLS from the first byte.
    case tls
    /// Plain until the protocol's STARTTLS, which is required: no credential is sent before it.
    case startTLS
    /// No encryption, and only to this computer (tests against the fakes).
    case plainLoopbackOnly
}

/// Where a server is and how to reach it.
public struct ServerEndpoint: Codable, Hashable, Sendable {
    public var host: String
    public var port: UInt16
    public var security: TransportSecurity

    public init(host: String, port: UInt16, security: TransportSecurity) {
        self.host = host
        self.port = port
        self.security = security
    }

    /// Whether `host` names this computer: 127.0.0.1, ::1 or localhost.
    public var isLoopback: Bool {
        let name = host.lowercased()
        return name == "127.0.0.1" || name == "::1" || name == "[::1]" || name == "localhost"
    }
}
