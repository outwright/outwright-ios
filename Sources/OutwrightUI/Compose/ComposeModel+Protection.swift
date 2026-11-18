// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightMIME
import OutwrightModel
import OutwrightStore

/// What the owner chose for recipients who can't receive a protected message.
public enum ProtectionChoice: Sendable, Equatable {
    case none
    /// Send the message as it is, to everyone.
    case sendPlain
    /// Leave those recipients out and protect the message for the rest.
    case removeKeyless
}

/// What compose keeps of protection between looks.
struct ProtectionMemo {
    /// The kind the draft was kept with when it was opened, when it was kept encrypted.
    var keptKind: ProtectionRequirement.Kind?
    /// The protection compose chose, with the account it chose it for.
    var chosen: (account: AccountID, screen: (any ProtectionUI)?)?
}

/// Protecting a message: what the build's protection says of it, and what it is sent with.
extension ComposeModel {
    /// The screens of the protection this message is written with: the one given, else the
    /// highest-ranked of the build's for the account it is from, chosen once per account (and
    /// again on each `refreshProtection`, as the account's setup may have changed), not on each look.
    var protectionUI: (any ProtectionUI)? {
        if let fixedProtectionUI { return fixedProtectionUI }
        guard let account else { return protectionScreens.first }
        if let chosen = protectionMemo.chosen, chosen.account == account.id { return chosen.screen }
        let screen = ProtectionScreens.forCompose(protectionScreens, account: account)
        protectionMemo.chosen = (account.id, screen)
        return screen
    }
    /// Asks the protection again for the current recipients; called when they change, not per keystroke.
    /// False when the answer came for recipients, an account or a lock that changed meanwhile, and was dropped.
    @discardableResult
    public func refreshProtection() async -> Bool {
        protectionMemo.chosen = nil
        guard let protectionUI, let account, !hasCalendar else {
            protection = nil
            return true
        }
        let asked = (to + cc + bcc, account.id, ownerLock, ownerSign)
        var answer = await protectionUI.compose(
            recipients: asked.0, account: account, original: original, ownerLock: ownerLock, ownerSign: ownerSign)
        // An answer to an earlier question (recipients, account or a choice changed meanwhile) is dropped.
        guard asked.0 == to + cc + bcc, asked.1 == from, asked.2 == ownerLock, asked.3 == ownerSign else {
            return false
        }
        // A kept draft the protection signs separately from encrypting reopens as it was kept.
        if answer.signsSeparately, ownerSign == nil, let kept = keptKind { answer.signOn = kept == .encrypt }
        if ownerLock == true {
            answer.lockOn = true
            answer.mustAsk = true
        }
        protection = answer
        return true
    }

    /// What the original was opened with; a protected row whose body is not on the phone counts as
    /// protected, though it could not be opened.
    static func facts(_ opened: OpenedMessage?, _ row: MessageRow) -> ProtectionFacts? {
        if let facts = opened?.facts { return facts }
        return row.isProtected ? ProtectionFacts(decryption: .failed, signature: .none, resentBy: nil) : nil
    }

    /// Stores what the draft row `id`, just written, asks to be sent with. While the protection's
    /// answer is unknown a stored requirement is left as it is, but a message that answers, forwards
    /// or is a protected one asks for protection from the start. A draft changed since it was opened
    /// goes to everyone again, whoever a refused send already reached.
    func keepProtection(_ requirement: ProtectionRequirement?, for id: MessageID) throws(StoreError) {
        if protectionKnown {
            try store.setProtection(requirement ?? keepRequirement(), for: id)
        } else if let starting = startingRequirement(), try store.protection(of: id) == nil {
            try store.setProtection(starting, for: id)
        }
        if hasChanges { try store.resetSubmitted(of: id) }
    }

    /// How many times Send asks the protection before it takes the answer as unknown.
    static let sendAsks = 3

    /// The message answers, forwards or is a draft of a protected message: it is to be protected
    /// whatever the protection answers, and kept off the server until it can be.
    var protectedFromStart: Bool {
        protectionUI != nil && !hasCalendar && (draftWasProtected || original.map { $0.decryption != .none } ?? false)
    }

    /// The kind the draft was kept with when it was opened, when it was kept encrypted.
    var keptKind: ProtectionRequirement.Kind? { protectionMemo.keptKind }

    /// The kind the draft `id` was kept with, when it was kept encrypted.
    static func keptKind(of id: MessageID, in store: MailStore) -> ProtectionRequirement.Kind? {
        guard let kept = try? store.protection(of: id), !kept.plainChosen else { return nil }
        return kept.kind == .sign ? nil : kept.kind
    }

    /// What a message protected from the start is kept with before the protection has answered.
    func startingRequirement() -> ProtectionRequirement? {
        guard protectedFromStart, let protectionUI, ownerLock != false else { return nil }
        let recipients = Set((to + cc + bcc).map { $0.email.lowercased() }).sorted()
        return ProtectionRequirement(
            protection: protectionUI.protection, recipients: recipients, plainChosen: false, kind: keptKind ?? .encrypt)
    }

    /// Nothing can be encrypted now: only a message that must ask stops, and may go unencrypted;
    /// signed, when the protection can still sign and signing is on.
    private func unprotectableRequirement(
        _ state: ComposeProtection, choice: ProtectionChoice
    ) throws(ComposeError) -> ProtectionRequirement? {
        guard let protectionUI, ownerLock != false, state.mustAsk || protectedFromStart else {
            return signedRequirement()
        }
        guard choice == .sendPlain else { throw .protectionUnavailable }
        let recipients = Set((to + cc + bcc).map { $0.email.lowercased() }).sorted()
        return ProtectionRequirement(
            protection: protectionUI.protection, recipients: recipients, plainChosen: true,
            kind: signedRequirement() == nil ? .encrypt : .sign)
    }

    /// The protection can't encrypt from the account now (nothing at all, or signing only).
    static func cannotEncrypt(_ state: ComposeProtection) -> Bool { !state.canProtect || !state.canEncrypt }

    /// The protection's answer is known, so what is kept with the draft may follow it.
    var protectionKnown: Bool { protectionUI != nil && protection != nil && !hasCalendar }

    /// What a draft kept now asks to be sent with: locked and the owner's say or every recipient has a
    /// key. Never throws and never removes anyone; the question is asked when sending.
    func keepRequirement() -> ProtectionRequirement? {
        // A protection that can't encrypt yet keeps only a message protected from the start off the server.
        if let state = protection, Self.cannotEncrypt(state) { return startingRequirement() ?? signedRequirement() }
        guard let protectionUI, let state = protection, state.lockOn, !hasCalendar else { return signedRequirement() }
        let all = to + cc + bcc
        let keyed = all.allSatisfy { state.recipients[$0.email.lowercased()] == .has
            || state.recipients[$0.email.lowercased()] == .changed }
        guard state.mustAsk || keyed else { return signedRequirement() }
        let recipients = Set(all.map { $0.email.lowercased() }).sorted()
        return ProtectionRequirement(
            protection: protectionUI.protection, recipients: recipients, plainChosen: false,
            kind: Self.lockedKind(state))
    }

    /// Adds what is typed in the recipient lines as addresses; when one is not an address nothing is added.
    func commit(typed: [RecipientList: String]) throws(ComposeError) {
        var added: [RecipientList: [Address]] = [:]
        for list in [RecipientList.to, .cc, .bcc] {
            let (addresses, rest) = RecipientParser.split(typed[list] ?? "")
            if let wrong = rest.first { throw .notAnAddress(wrong) }
            added[list] = addresses
        }
        for list in [RecipientList.to, .cc, .bcc] {
            add(added[list] ?? [], to: list)
        }
    }

    /// Makes what is typed recipients, asks the protection about them, then sends: a recipient not yet
    /// looked up would count as keyless. What was typed stays among the recipients when sending stops.
    public func send(
        afterLookupOf typed: [RecipientList: String], choice: ProtectionChoice = .none
    ) async throws(ComposeError) {
        guard !isSending else { throw .alreadySending }
        isSending = true
        defer { isSending = false }
        let before = (to, cc, bcc)
        try commit(typed: typed)
        var answered = false
        for _ in 0..<Self.sendAsks where !answered {
            answered = await refreshProtection()
        }
        if !answered {
            // No answer for these very recipients: none is known, so the owner is asked.
            protection = ComposeProtection(
                lockOn: ownerLock ?? true, mustAsk: true, recipients: [:], canProtect: protection?.canProtect ?? true,
                signOn: ownerSign ?? protection?.signOn ?? false)
        }
        do {
            try send(choice: choice)
        } catch {
            // The recipients stay as chips only when the owner is asked; else trying again adds nothing twice.
            switch error {
            case .needsProtectionChoice, .protectionUnavailable: break
            default: (to, cc, bcc) = before
            }
            throw error
        }
    }

    /// What each recipient's chip shows; empty without a protection.
    public var keyStates: [String: RecipientKey] { protection?.recipients ?? [:] }

    /// The owner turns the lock on or off; a lock the owner turned on asks before sending to someone
    /// who can't receive it.
    public func toggleLock() {
        guard var state = protection, !Self.cannotEncrypt(state) else { return }
        state.lockOn.toggle()
        state.mustAsk = true
        ownerLock = state.lockOn
        protection = state
    }

    /// What the line under the subject says, by the rules Send follows (`requirement`); `typed`,
    /// addresses typed but not yet recipients, which Send adds. Nil: no line (no protection, a
    /// calendar invitation, or a message that goes as ordinary mail).
    func protectionNote(typed: [Address] = []) -> ProtectionNote? {
        guard !hasCalendar else { return nil }
        return Self.note(
            protection, recipients: to + cc + bcc + typed, protectedFromStart: protectedFromStart, ownerLock: ownerLock)
    }

    static func note(
        _ state: ComposeProtection?, recipients: [Address], protectedFromStart: Bool, ownerLock: Bool? = nil
    ) -> ProtectionNote? {
        guard let state else { return nil }
        guard !cannotEncrypt(state) else {
            // Send stops here (`unprotectableRequirement`): the line says so before it does.
            let stops = ownerLock != false && (state.mustAsk || protectedFromStart)
            return stops ? .cannotProtect : nil
        }
        guard state.lockOn else { return nil }
        let keys = recipients.map { state.recipients[$0.email.lowercased()] }
        let keyless = keys.contains { $0 == RecipientKey.none }
        let unknown = keys.contains { $0 == nil || $0 == .looking }
        if keyless, state.mustAsk { return .notEveryone }
        if unknown { return .checking }
        // Without the question the lock is a wish only: the message goes as it is, with no line.
        if keyless { return nil }
        return keys.contains { $0 == .changed } ? .keyChanged : .encrypted
    }

    /// What the message asks to be sent with, or the question the owner must answer first. Recipients
    /// the owner chose to leave out are taken off the message. Wherever it goes unencrypted, it goes
    /// signed when signing is on.
    func requirement(choice: ProtectionChoice) throws(ComposeError) -> ProtectionRequirement? {
        if let state = protection, Self.cannotEncrypt(state), !hasCalendar {
            return try unprotectableRequirement(state, choice: choice)
        }
        guard let protectionUI, let state = protection, state.lockOn, !hasCalendar else { return signedRequirement() }
        let missing = Self.missingKeys(to + cc + bcc, in: state)
        var plain = false
        if !missing.isEmpty {
            // Without the question the lock is a wish only: the message goes as it is.
            guard state.mustAsk else { return signedRequirement() }
            switch choice {
            case .none: throw .needsProtectionChoice(missing: missing)
            case .sendPlain: plain = true
            case .removeKeyless:
                let gone = Set(missing.map { $0.email.lowercased() })
                to.removeAll { gone.contains($0.email.lowercased()) }
                cc.removeAll { gone.contains($0.email.lowercased()) }
                bcc.removeAll { gone.contains($0.email.lowercased()) }
                guard !(to + cc + bcc).isEmpty else { throw .noRecipients }
            }
        }
        let recipients = Set((to + cc + bcc).map { $0.email.lowercased() }).sorted()
        if plain, state.signOn {
            return ProtectionRequirement(
                protection: protectionUI.protection, recipients: recipients, plainChosen: true, kind: .sign)
        }
        return ProtectionRequirement(
            protection: protectionUI.protection, recipients: recipients, plainChosen: plain,
            kind: Self.lockedKind(state))
    }

    /// What a locked message is made: encrypted and signed, or (when signing is the owner's own toggle
    /// and it is off) encrypted only.
    static func lockedKind(_ state: ComposeProtection) -> ProtectionRequirement.Kind {
        state.signsSeparately && !state.signOn ? .encryptUnsigned : .encrypt
    }

    /// The recipients without a known key (looked up, or not yet), each once.
    private static func missingKeys(_ addresses: [Address], in state: ComposeProtection) -> [Address] {
        var seen = Set<String>()
        return addresses.filter { address in
            let key = address.email.lowercased()
            switch state.recipients[key] {
            case .has?, .changed?: return false
            case .looking?, RecipientKey.none?, nil: return seen.insert(key).inserted
            }
        }
    }

    /// Signed, not encrypted: while signing is on and the account can protect; nil otherwise.
    func signedRequirement() -> ProtectionRequirement? {
        guard let protectionUI, let state = protection, state.canProtect, state.signOn, !hasCalendar else {
            return nil
        }
        return ProtectionRequirement(
            protection: protectionUI.protection, recipients: [], plainChosen: false, kind: .sign)
    }

    /// A draft kept locked is locked again (and unsigned again, when it was kept encrypted only).
    func restoreKeptChoices(of id: MessageID) {
        guard let kept = try? store.protection(of: id), !kept.plainChosen, !hasCalendar else { return }
        switch kept.kind {
        case .encrypt: ownerLock = true
        case .encryptUnsigned: (ownerLock, ownerSign) = (true, false)
        case .sign: break
        }
    }

    /// The owner turns signing on or off for this message.
    public func toggleSign() {
        guard var state = protection else { return }
        state.signOn.toggle()
        ownerSign = state.signOn
        protection = state
    }
}
