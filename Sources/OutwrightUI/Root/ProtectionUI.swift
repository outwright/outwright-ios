// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import OutwrightMIME
public import OutwrightModel
public import SwiftUI

/// Whether a recipient can receive protected mail.
public enum RecipientKey: Sendable, Equatable {
    /// Still being looked up.
    case looking
    case has
    /// Has one, but not the one used before.
    case changed
    case none
}

/// What the compose sheet shows and asks about protecting a message, as the protection answers it.
public struct ComposeProtection: Sendable, Equatable {
    /// The message is to be protected.
    public var lockOn: Bool
    /// When not protected, the message is signed: anyone can read it, and it shows who sent it.
    public var signOn: Bool
    /// Sending to someone who can't receive it asks first (the lock is on by the owner, the message
    /// answers a protected one, or the owner's choice is kept).
    public var mustAsk: Bool
    /// Keyed by the recipient's lower-case address.
    public var recipients: [String: RecipientKey]
    /// The protection can protect a message from the account now (false: it lacks what it needs of
    /// its own, such as the account's key). Without it nothing is protected; a message that must ask
    /// stops at Send and offers to go unprotected.
    public var canProtect: Bool

    public init(
        lockOn: Bool, mustAsk: Bool, recipients: [String: RecipientKey], canProtect: Bool = true, signOn: Bool = false
    ) {
        self.lockOn = lockOn
        self.signOn = signOn
        self.mustAsk = mustAsk
        self.recipients = recipients
        self.canProtect = canProtect
    }
}

/// What the line under the subject says the lock does now.
public enum ProtectionNote: Sendable, Equatable {
    /// Protected for every recipient.
    case encrypted
    /// Some recipients' keys are still being looked up.
    case checking
    /// Locked, but someone can't receive it protected: the owner is asked at Send.
    case notEveryone
    /// Sent as ordinary mail (the lock is off, or on only as a wish someone can't receive).
    case notEncrypted
    /// Not encrypted, but signed: anyone can read it, and it shows who sent it.
    case signed
    /// Locked, but the account can't protect anything yet: the owner is asked at Send.
    case cannotProtect
}

/// The screens of a protection, joined to the shared code at app start. The shared code shows what
/// it gives and never names the protection.
@MainActor public protocol ProtectionUI: AnyObject {
    var protection: ProtectionID { get }
    /// Asked again whenever the recipients change; `original` is what the message answered,
    /// `ownerLock` and `ownerSign` the owner's own choices for the message (nil: not chosen).
    func compose(
        recipients: [Address], account: Account, original: ProtectionFacts?, ownerLock: Bool?, ownerSign: Bool?
    ) async -> ComposeProtection
    /// Where a key for the address is added.
    func keyImporter(for address: String) -> AnyView
    /// Marks under the sender of a message that was opened with these facts.
    func readingMarks(_ facts: ProtectionFacts, sender: Address) -> AnyView
    func personSection(for address: String) -> AnyView
}
