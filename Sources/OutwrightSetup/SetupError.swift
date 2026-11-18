// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/// Why reading or writing a setup file failed. Cases carry no secret and no file content.
public enum SetupError: Error, Equatable, Sendable {
    /// The bytes are not what the format says, or a value is out of its valid range.
    case malformed
    /// A size or cost the file (or a caller) asks for is above what is accepted.
    case tooLarge
    /// A version or algorithm this build does not support.
    case unsupported
    /// The passphrase does not open the file.
    case wrongPassphrase
    /// A piece of the setup could not be read on this device (its keychain refused).
    case unavailable
    /// The other side does not hold the pairing code, or a message of the direct transfer was altered.
    case handshakeFailed
    /// The other side cancelled the direct transfer.
    case stopped
    /// The other side did not answer in time.
    case timedOut
    /// The connection to the other side ended.
    case connectionLost
}
