// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/// Why a message could not be read or written. Carries no message text.
public enum MIMEError: Error, Sendable {
    case tooLarge
    case tooDeep
    case tooManyParts
    case notAMessage
}
