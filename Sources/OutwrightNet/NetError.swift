// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/// Why a connection failed. Carries no credential and no message text.
public enum NetError: Error, Sendable, Equatable {
    /// A plain connection was asked for to a host that is not this computer.
    case plainRefused
    case timeout
    /// The other side closed the connection.
    case closed
    case lineTooLong
    // swiftlint:disable:next identifier_name
    case io(String) // Anything else the system reported, in its own words.
}
