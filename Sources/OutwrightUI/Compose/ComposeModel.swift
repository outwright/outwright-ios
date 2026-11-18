// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
public import Observation
public import OutwrightMIME
public import OutwrightModel
public import OutwrightStore

/// A message being written: new, a reply, a forward or a draft opened again. Closing it keeps it
/// in the account's Drafts when something changed; sending queues it for the server.
@Observable @MainActor
public final class ComposeModel {
    public static let maxAttachmentBytes = 25 << 20
    /// The cap this model holds attachments to: `maxAttachmentBytes`, lower only in a test, where a
    /// message near 25 MB takes seconds to read in a debug build.
    @ObservationIgnored var attachmentLimit = ComposeModel.maxAttachmentBytes

    /// What is being written, for the sheet's title.
    public enum Purpose: Sendable, Equatable {
        case new, reply, forward
    }

    public var from: AccountID {
        didSet { if from != oldValue { swapSignature(from: oldValue) } }
    }
    public var to: [Address] = []
    public var cc: [Address] = []
    public var bcc: [Address] = []
    public var subject = ""
    public var body = AttributedString()
    public var attachments: [Attachment] = []
    /// The message a reply or forward answers, under the editor; nil for a new message.
    public internal(set) var quoted: QuotedOriginal?
    /// What of the message answered or forwarded didn't fit under the attachment limit; the sheet says so.
    public internal(set) var leftOut = AttachFailures()
    /// The draft row this message is kept in, once it has one.
    public internal(set) var draftID: MessageID?
    /// Sent or closed: nothing more is saved.
    public internal(set) var isFinished = false
    /// The draft could not be kept on close or on the way to the background; the sheet asks.
    public var keepFailure: ComposeError?
    /// What the build's protection says of this message and its recipients; nil: nothing to show.
    public var protection: ComposeProtection?
    /// A reply whose original couldn't be loaded: it opens without the quote, and the sheet says so.
    public private(set) var originalNotQuoted = false
    /// A send is waiting for the protection's answer about its recipients; another is not started.
    public internal(set) var isSending = false

    public let accounts: [Account]
    public private(set) var purpose: Purpose = .new
    @ObservationIgnored let store: MailStore
    @ObservationIgnored let locale: Locale
    @ObservationIgnored let now: () -> Date
    @ObservationIgnored let fixedProtectionUI: (any ProtectionUI)?
    @ObservationIgnored let protectionScreens: [any ProtectionUI]
    /// What the message answers was opened with, for the protection to follow it.
    @ObservationIgnored var original: ProtectionFacts?
    /// The owner's own choice of the lock (nil: not chosen).
    @ObservationIgnored var ownerLock: Bool?
    /// The owner's own choice of signing for this message (nil: the account's).
    @ObservationIgnored var ownerSign: Bool?
    /// A draft the server held protected, opened decrypted: kept protected like an answer to such mail.
    @ObservationIgnored var draftWasProtected = false
    @ObservationIgnored var protectionMemo = ProtectionMemo()
    /// The message carries a calendar part (a reply to an invitation): it is never protected.
    @ObservationIgnored var hasCalendar = false
    @ObservationIgnored private var inReplyTo: String?
    @ObservationIgnored private var references: [String] = []
    @ObservationIgnored private var threadID: ThreadID?
    /// The Message-ID of a draft opened again; nil for a message started here.
    @ObservationIgnored private var keptMessageID: String?
    /// The Message-ID made for this message, with the account whose domain it carries.
    @ObservationIgnored private var minted: (account: AccountID, id: String)?
    @ObservationIgnored var isStarting = true
    /// The body as the message started, where writing begins at the top; nil for a draft opened again.
    @ObservationIgnored var startingBody: AttributedString?
    @ObservationIgnored private var draftUID: UInt32 = 0
    @ObservationIgnored private var draftAccount: AccountID?
    @ObservationIgnored var snapshot: Snapshot?
    @ObservationIgnored lazy var people: [Address] = PeopleIndex.known(store, accounts: accounts)

    /// `accountInView` is the account whose folder is on screen (nil in All accounts, where
    /// `defaultAccount` from Settings is who a new message is from); `locale`
    /// is the interface's, for the `Sv:`/`Re:` prefix and the quoted header.
    /// `opened` is the stored message a reply, forward or draft starts from, read away from the
    /// main actor (`make` reads it); without it they start from the stored row alone, and a reply
    /// leaves the quote out when `quotesOriginal` is false.
    public init(
        request: ComposeRequest, store: MailStore, accounts: [Account], accountInView: AccountID? = nil,
        defaultAccount: AccountID? = nil, locale: Locale = .current, now: @escaping () -> Date = { Date() },
        protectionUI: (any ProtectionUI)? = nil, protectionScreens: [any ProtectionUI] = [],
        opened: OpenedMessage? = nil, quotesOriginal: Bool = true,
        attachmentLimit: Int = ComposeModel.maxAttachmentBytes
    ) {
        self.attachmentLimit = attachmentLimit
        originalNotQuoted = !quotesOriginal
        fixedProtectionUI = protectionUI
        self.protectionScreens = protectionScreens
        self.store = store
        self.accounts = accounts
        self.locale = locale
        self.now = now
        from = accountInView ?? accounts.first { $0.id == defaultAccount }?.id ?? accounts.first?.id ?? AccountID()
        switch request.kind {
        case .new:
            body = signatureBlock()
        case .reply(let id):
            startReply(id, all: false, opened: opened)
        case .replyAll(let id):
            startReply(id, all: true, opened: opened)
        case .forward(let id):
            startForward(id, opened: opened)
        case .draft(let id):
            openDraft(id, opened: opened)
        case .to(let address):
            to = [address]
            body = signatureBlock()
        case let .people(addresses, title):
            (to, subject, body) = (addresses, title, signatureBlock())
        case .diagnostics(let report):
            to = [Address(name: nil, email: Self.diagnosticsAddress)]
            subject = "Outwright diagnostics"
            body = AttributedString(Self.diagnosticsPromise + "\n")
            attachments = [Attachment(
                filename: "outwright-diagnostics.txt", mimeType: "text/plain", contentID: nil, isInline: false,
                data: report)]
        }
        snapshot = current
        if case .draft = request.kind {} else { startingBody = body }
        isStarting = false
    }

    public var account: Account? { accounts.first { $0.id == from } }

    public var isReply: Bool { purpose == .reply }

    // MARK: - Closing and sending

    /// Keeps the message in Drafts when it changed; does nothing after `send` or `discard`. When the
    /// draft can't be kept it throws and the message stays open, so nothing is lost unasked.
    public func close() throws(ComposeError) {
        guard !isFinished else { return }
        guard hasChanges else {
            isFinished = true
            return
        }
        let id = try saveRow()
        do {
            try store.apply(.saveDraft(id))
        } catch {
            throw .store
        }
        isFinished = true
    }

    /// ✕: keeps the draft and says true, or holds why it could not in `keepFailure` and stays open.
    func closeAsked() -> Bool {
        do throws(ComposeError) {
            try close()
            return true
        } catch {
            keepFailure = error
            return false
        }
    }

    /// The app is going to the background: what is written is kept, or `keepFailure` says why not.
    func keepInTheBackground() {
        do throws(ComposeError) {
            try keep()
        } catch {
            keepFailure = error
        }
    }

    /// The owner chose to throw the changes away: nothing is saved (a draft opened again stays as it was).
    public func discard() {
        isFinished = true
    }

    /// Keeps the message in Drafts and queues it for the server, and stays open (the app is going to
    /// the background). Closing it later saves it again only when it changed meanwhile.
    public func keep() throws(ComposeError) {
        guard !isFinished, hasChanges else { return }
        let id = try saveRow()
        do {
            try store.apply(.saveDraft(id))
        } catch {
            throw .store
        }
        snapshot = current
    }

    /// Keeps the message as a draft and queues it to be sent from the account's own address.
    /// `typed` is what is still in each recipient line, not yet made an address: every entry in it
    /// (split at commas and semicolons) is added, and when one is not an address nothing is sent.
    /// `choice` is the owner's answer to `needsProtectionChoice`.
    public func send(typed: [RecipientList: String] = [:], choice: ProtectionChoice = .none) throws(ComposeError) {
        let before = (to, cc, bcc)
        try commit(typed: typed)
        do throws(ComposeError) {
            guard !(to + cc + bcc).isEmpty else { throw .noRecipients }
            let asked = try requirement(choice: choice)
            let id = try saveRow(requirement: asked)
            do {
                try store.apply(.send(draftID: id))
            } catch {
                throw .store
            }
        } catch {
            // Not sent: the typed lines stay as they were, so trying again doesn't add them twice.
            (to, cc, bcc) = before
            throw error
        }
        isFinished = true
    }

    // MARK: - Keeping

    /// A draft opened again keeps its Message-ID; a new message's carries the domain of the account
    /// it is sent from, made again when another account is chosen.
    private func messageID(for account: Account) -> String {
        // A kept one the writer cannot carry (from another client) gives way to one made here.
        if let keptMessageID, MIMEWriter.canWrite(messageID: keptMessageID) { return keptMessageID }
        if let minted, minted.account == account.id { return minted.id }
        let made = Self.mintMessageID(for: account.email)
        minted = (account.id, made)
        return made
    }

    /// Writes the message into the account's Drafts (uid 0 until the server has it) and returns its id.
    private func saveRow(requirement: ProtectionRequirement? = nil) throws(ComposeError) -> MessageID {
        guard let account,
            let drafts = (try? store.folders(account.id))?.first(where: { $0.kind == .drafts })
        else { throw .noDraftsFolder }
        guard attachmentBytes <= attachmentLimit else { throw .tooLarge }
        if let kept = draftID, let stored = try? store.message(kept) {
            // The server may have numbered the draft since it was last saved here.
            draftUID = stored.uid
        }
        if let old = draftID, draftAccount != account.id {
            // Another account was chosen: the draft moves there, the old one goes.
            try? store.apply(.delete(old))
            draftID = nil
            draftUID = 0
        }
        let messageIDHeader = messageID(for: account)
        let text = String(body.characters) + (quoted?.plain ?? "")
        let html = quoted.map { (RichText.html(body, always: true) ?? "") + $0.htmlQuote } ?? RichText.html(body)
        let message = OutgoingMessage(
            from: Address(name: account.displayName.isEmpty ? nil : account.displayName, email: account.email),
            to: to, cc: cc, bcc: bcc, subject: subject, textBody: text, htmlBody: html,
            attachments: attachments + (quoted?.inline ?? []), inReplyTo: inReplyTo, references: references,
            date: now(), messageID: messageIDHeader)
        let data: Data
        do {
            data = try MIMEWriter.write(message, includeBcc: true)
        } catch {
            switch error {
            case .tooLarge, .tooManyParts: throw .tooLarge
            default: throw .notWritable
            }
        }
        let row = MessageRow(
            id: draftID ?? MessageID(raw: 0), accountID: account.id, folderID: drafts.id, uid: draftUID,
            threadID: threadID ?? ThreadID(raw: messageIDHeader), from: message.from, to: to, cc: cc,
            subject: subject, preview: Self.preview(text),
            date: message.date, isRead: true, isFlagged: false, hasAttachment: !attachments.isEmpty,
            isInvitation: false, inboxClass: .focused, hasBody: true, threadCount: 1, messageIDHeader: messageIDHeader)
        do {
            guard let id = try store.upsert([row]).first else { throw ComposeError.store }
            try store.setBody(data, for: id)
            try keepProtection(requirement, for: id)
            draftID = id
            draftAccount = account.id
            return id
        } catch {
            throw .store
        }
    }
}

/// Starting a reply, a forward or a draft opened again.
extension ComposeModel {
    // MARK: - Starting

    private func startReply(_ id: MessageID, all: Bool, opened: OpenedMessage?) {
        purpose = .reply
        guard let row = try? store.message(id) else { return }
        let parsed = opened?.message
        original = Self.facts(opened, row)
        from = accounts.contains { $0.id == row.accountID } ? row.accountID : from
        // Only the replying account is "me": another account on this phone is a recipient like anyone.
        let own = Set(accounts.filter { $0.id == from }.map { $0.email.lowercased() })
        let originalTo = parsed?.to ?? row.to
        let sender = parsed?.from.first ?? row.from
        // A reply to one's own message goes to whom it was sent; else to every Reply-To, or the sender.
        // Decrypted mail is one's own only by a protected From (an outer one anyone could forge).
        let replyTo: [Address]
        if own.contains(sender.email.lowercased()), !Self.fromIsForgeable(opened) {
            replyTo = originalTo
        } else if let given = parsed?.replyTo, !given.isEmpty {
            replyTo = given
        } else {
            replyTo = [sender]
        }
        var seen = Set<String>()
        func keep(_ list: [Address]) -> [Address] {
            list.filter { !own.contains($0.email.lowercased()) && seen.insert($0.email.lowercased()).inserted }
        }
        to = keep(replyTo + (all ? originalTo : []))
        cc = all ? keep(parsed?.cc ?? row.cc) : []
        subject = Self.prefixed(row.subject, L10n.string("Re:", locale: locale))
        inReplyTo = row.messageIDHeader
        references = Array(((parsed?.references ?? []) + [row.messageIDHeader].compactMap { $0 }).suffix(20))
        threadID = row.threadID
        body = signatureBlock()
        quoted = originalNotQuoted ? nil : fitted(quote(row, parsed))
    }

    private func startForward(_ id: MessageID, opened: OpenedMessage?) {
        purpose = .forward
        guard let row = try? store.message(id) else { return }
        let parsed = opened?.message
        original = Self.facts(opened, row)
        from = accounts.contains { $0.id == row.accountID } ? row.accountID : from
        subject = Self.prefixed(row.subject, L10n.string("Fw:", locale: locale))
        let quotation = quote(row, parsed)
        // Inline parts the quote doesn't show (a picture placed in a text message) go as attachments;
        // the files first, then the quote's pictures in the room left.
        let shown = Set(quotation.inline.compactMap(\.contentID))
        for var attachment in parsed?.attachments ?? [] where !shown.contains(attachment.contentID ?? "") {
            attachment.isInline = false
            if !attach(attachment) { leftOut.tooLarge += 1 }
        }
        quoted = fitted(quotation)
        body = signatureBlock()
    }

    private func openDraft(_ id: MessageID, opened: OpenedMessage?) {
        guard let row = try? store.message(id) else { return }
        draftID = id
        protectionMemo.keptKind = Self.keptKind(of: id, in: store)
        draftUID = row.uid
        draftAccount = row.accountID
        from = row.accountID
        threadID = row.threadID
        subject = row.subject
        to = row.to
        cc = row.cc
        keptMessageID = row.messageIDHeader
        guard let parsed = opened?.message else {
            body = AttributedString(row.preview)
            return
        }
        hasCalendar = parsed.calendar != nil
        to = parsed.to
        cc = parsed.cc
        bcc = parsed.bcc
        subject = parsed.subject
        inReplyTo = parsed.inReplyTo.first
        references = parsed.references
        let split = parsed.htmlBody.flatMap { QuotedOriginal.split(draftHTML: $0, parts: parsed.attachments) }
        if let (own, _) = split {
            body = RichText.attributed(fromHTML: own)
        } else {
            body = parsed.htmlBody.map(RichText.attributed(fromHTML:)) ?? AttributedString(parsed.textBody ?? "")
        }
        let shown = Set((split?.quote.inline ?? []).compactMap(\.contentID))
        for attachment in parsed.attachments where !shown.contains(attachment.contentID ?? "") {
            if !attach(attachment) { leftOut.tooLarge += 1 }
        }
        quoted = split.map { fitted($0.quote) }
        if let own = parsed.messageID { keptMessageID = own }
        purpose = inReplyTo == nil ? .new : .reply
        // A draft kept locked, or held protected by the server, is locked again and asks before sending.
        if opened?.facts?.decryption == .decrypted, !hasCalendar {
            draftWasProtected = true
            ownerLock = true
        }
        restoreKeptChoices(of: id)
    }
}
