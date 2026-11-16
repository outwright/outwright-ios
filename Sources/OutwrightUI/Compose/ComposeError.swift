// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import OutwrightMIME

/// Why a message could not be sent or kept.
public enum ComposeError: Error, Sendable, Equatable {
    case noRecipients
    /// The account has no Drafts folder yet (its folders were never read).
    case noDraftsFolder
    case store
    /// The message could not be written (it is too large).
    case tooLarge
    /// The message could not be written for another reason (an address or id it cannot carry).
    case notWritable
    /// Typed into a recipient line and not an address: nothing was sent.
    case notAnAddress(String)
    /// The message is to be protected and these recipients can't receive it: the owner chooses
    /// what to do (`ProtectionChoice`) and sends again.
    case needsProtectionChoice(missing: [Address])
    /// The message is to be protected and the protection can't protect it from this account now: the
    /// owner may send it unprotected (`ProtectionChoice.sendPlain`) or keep it.
    case protectionUnavailable
    /// Another send is waiting for the protection's answer; this one did nothing.
    case alreadySending
}

/// The recipient lines of a message.
public enum RecipientList: Hashable, Sendable {
    case to, cc, bcc
}
