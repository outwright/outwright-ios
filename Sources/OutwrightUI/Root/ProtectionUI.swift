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
    /// Sign is the owner's own toggle whether or not the lock is on (false: signing is part of the lock).
    public var signsSeparately: Bool
    /// Sending to someone who can't receive it asks first (the lock is on by the owner, the message
    /// answers a protected one, or the owner's choice is kept).
    public var mustAsk: Bool
    /// Keyed by the recipient's lower-case address.
    public var recipients: [String: RecipientKey]
    /// The protection can protect a message from the account now (false: it lacks what it needs of
    /// its own, such as the account's key). Without it nothing is protected; a message that must ask
    /// stops at Send and offers to go unprotected.
    public var canProtect: Bool
    /// The protection can also lock (encrypt) a message from the account now; false: it can only
    /// sign (the account's own key or certificate is for signing only). The lock is not offered
    /// then, and a message that must ask stops at Send and offers to go unencrypted.
    public var canEncrypt: Bool
    /// A line of the protection's own about the account, in the interface's language (such as its
    /// certificate running out soon), shown under the subject; nil: none.
    public var notice: String?

    public init(
        lockOn: Bool, mustAsk: Bool, recipients: [String: RecipientKey], canProtect: Bool = true,
        canEncrypt: Bool = true, signOn: Bool = false, signsSeparately: Bool = false, notice: String? = nil
    ) {
        self.canEncrypt = canEncrypt
        self.notice = notice
        self.lockOn = lockOn
        self.signOn = signOn
        self.signsSeparately = signsSeparately
        self.mustAsk = mustAsk
        self.recipients = recipients
        self.canProtect = canProtect
    }
}

/// What the line under the subject says about protecting this message. Ordinary mail, signed or
/// not, has no line.
public enum ProtectionNote: Sendable, Equatable {
    /// Protected for every recipient.
    case encrypted
    /// Protected, but a recipient's key is not the one used before.
    case keyChanged
    /// Some recipients' keys are still being looked up.
    case checking
    /// Locked, but someone can't receive it protected: the owner is asked at Send.
    case notEveryone
    /// Send will stop, because the account can't protect anything yet: the owner is asked there.
    case cannotProtect
}

/// The screens of a protection, joined to the shared code at app start. The shared code shows what
/// it gives and never names the protection.
@MainActor public protocol ProtectionUI: AnyObject {
    var protection: ProtectionID { get }
    /// How well this protection suits writing from the account: nil when it is not set up for it.
    /// Compose writes with the highest rank, and with none ranked, with the first protection.
    func composeRank(for account: Account) -> Int?
    /// Asked again whenever the recipients change; `original` is what the message answered,
    /// `ownerLock` and `ownerSign` the owner's own choices for the message (nil: not chosen).
    func compose(
        recipients: [Address], account: Account, original: ProtectionFacts?, ownerLock: Bool?, ownerSign: Bool?
    ) async -> ComposeProtection
    /// Where a key for the address is added, for `account` (the one compose writes from; nil: none).
    func keyImporter(for address: String, account: Account?) -> AnyView
    /// Marks under the sender of a message that was opened with these facts; `reverify` opens the
    /// message again (a key it needs came in), and the marks follow what that finds.
    func readingMarks(
        _ facts: ProtectionFacts, sender: Address, reverify: @escaping @MainActor () async -> Void
    ) -> AnyView
    func personSection(for address: String) -> AnyView
    /// Where the account is set up to protect mail (its key), shown in a sheet of its own; nil when
    /// the protection has nothing to set up.
    func accountSetup(for account: Account) -> AnyView?
}

extension ProtectionUI {
    /// Ranked by nothing: as good as any other not-set-up protection, so the first screen is used.
    public func composeRank(for account: Account) -> Int? { nil }
}

/// Which protection compose writes with.
public enum ProtectionScreens {
    /// The screens of the highest-ranked protection for the account (the first of equals); with none
    /// ranked, the first screen; nil without screens.
    @MainActor public static func forCompose(_ screens: [any ProtectionUI], account: Account) -> (any ProtectionUI)? {
        var best: (screen: any ProtectionUI, rank: Int)?
        for screen in screens {
            guard let rank = screen.composeRank(for: account) else { continue }
            if best.map({ rank > $0.rank }) ?? true { best = (screen, rank) }
        }
        return best?.screen ?? screens.first
    }
}
