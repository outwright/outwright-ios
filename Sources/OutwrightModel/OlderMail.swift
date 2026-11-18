// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/// What asking the servers for older mail of a list came to.
public enum OlderMail: Sendable, Equatable {
    /// Some came, and a server may have more.
    case more
    /// Every server has given all it has.
    case noneLeft
    /// No server could be asked (offline, no password): try again later, not at once.
    case failed
}
