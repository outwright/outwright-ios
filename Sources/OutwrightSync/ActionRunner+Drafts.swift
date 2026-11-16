// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightMIME
import OutwrightModel
import OutwrightSMTP
import OutwrightStore

/// Sending and saving drafts.
extension ActionRunner {
    struct Outgoing {
        var wire: Data
        var ownCopy: Data
        var recipients: [String]
    }

    // MARK: - Drafts and sending

    /// Submits the draft. Once the server has taken the message the send is settled at once (the
    /// draft becomes the owner's copy in Sent, and filing it is queued), so nothing is ever sent
    /// twice and the copy is not lost to a drop. A refusal for good settles it too: the draft stays,
    /// marked with why, and the owner hears of it.
    mutating func send(_ draftID: MessageID, _ pending: PendingAction) async throws(SyncError) -> Bool {
        guard let row = try stored({ try store.message(draftID) }), let raw = try stored({ try store.body(draftID) })
        else {
            return true
        }
        let draft = try Self.parseDraft(raw)
        let messageID = try messageID(of: draft, row)
        let message = await outgoingMessage(draft, messageID: messageID)
        let prepared: Prepared
        switch try await prepare(message, draft: draftID) {
        case let .ready(value):
            prepared = value
        case let .refused(refusal):
            try stored { try store.refuseSend(pending.id, draft: draftID, reason: refusal) }
            return true
        }
        guard let endpoint = AccountSyncer.endpoint(account.smtp) else {
            throw .smtp(.net(.io("Unknown transport security")))
        }
        let credential = try await credentials.smtpCredential(for: account)
        // One submission at a time, each recorded (by its addresses, on the draft) once the server has
        // taken it, so a send tried again, after a drop or a refusal, goes only to the rest: nothing
        // reaches an address twice.
        for submission in prepared.submissions {
            let done = try stored { try store.submittedTo(of: draftID) }
            if !submission.recipients.isEmpty, submission.recipients.allSatisfy({ done.contains($0.lowercased()) }) {
                continue
            }
            // A syncer that was replaced leaves the message to the one that replaced it.
            guard await mayContinue() else {
                stopped = true
                return false
            }
            do {
                try await credentials.withSMTP(for: account, first: credential) { credential async throws(SMTPError) in
                    try await SMTPClient.send(
                        submission.wire, envelopeFrom: account.email, recipients: submission.recipients,
                        via: endpoint, user: account.user, credential: credential)
                }
            } catch {
                guard case let .smtp(smtpError) = error, let refusal = SendRefusal(smtpError) else {
                    throw error
                }
                try stored { try store.refuseSend(pending.id, draft: draftID, reason: refusal) }
                refusedSend = refusedSend ?? error
                return true
            }
            try stored { try store.addSubmitted(submission.recipients, to: draftID) }
        }
        // Sent: never again. The rest is `fileSent`, queued in the same step.
        try stored { try store.settleSend(pending.id, draft: draftID, copy: prepared.ownCopy, date: now) }
        return true
    }

    private static func parseDraft(_ raw: Data) throws(SyncError) -> MIMEMessage {
        // A protected draft is kept plain here, so it is read as it is, never opened.
        guard let draft = MessageReader.read(raw, limits: .default, opening: nil) else {
            throw .store("draftUnreadable")
        }
        return draft.message
    }

    /// What goes to SMTP, in order, and the owner's copy.
    struct Prepared {
        var submissions: [Submission]
        var ownCopy: Data
    }

    enum Preparation {
        case ready(Prepared)
        case refused(SendRefusal)
    }

    /// Makes the message ready as the draft's requirement asks: as written (no requirement, or plain
    /// chosen for these very recipients), or through the protection that was asked for. A protection
    /// that is not here, or a plain choice made for other recipients, refuses it.
    private func prepare(_ message: OutgoingMessage, draft: MessageID) async throws(SyncError) -> Preparation {
        let requirement = try stored { try store.protection(of: draft) }
        let plain: Bool
        if let requirement, requirement.kind == .sign {
            // Plain chosen for some recipients holds for them alone, signed or not.
            guard !requirement.plainChosen || requirement.recipients == Self.recipientSet(message) else {
                return .refused(.protectionUnavailable)
            }
            // A signature hides nothing: without its protection the message goes as written.
            plain = protections[requirement.protection] == nil
        } else if let requirement {
            if requirement.plainChosen {
                guard requirement.recipients == Self.recipientSet(message) else {
                    return .refused(.protectionUnavailable)
                }
                plain = true
            } else {
                plain = false
            }
        } else {
            plain = true
        }
        if plain {
            let outgoing = try outgoing(message)
            return .ready(Prepared(
                submissions: [Submission(wire: outgoing.wire, recipients: outgoing.recipients)],
                ownCopy: outgoing.ownCopy))
        }
        guard let requirement, let hook = protections[requirement.protection] else {
            return .refused(.protectionUnavailable)
        }
        do throws(ProtectionFailure) {
            let result = try await hook.protect(message, requirement: requirement, account: account)
            // Nothing to send is no send.
            guard !result.submissions.isEmpty else {
                return .refused(.protectionUnavailable)
            }
            return .ready(Prepared(submissions: result.submissions, ownCopy: result.ownCopy))
        } catch {
            switch error {
            case .keyMissing: return .refused(.protectionKeyMissing)
            }
        }
    }

    /// Lower-case, sorted, without repeats: who a message goes to, as a requirement records it.
    static func recipientSet(_ message: OutgoingMessage) -> [String] {
        Set((message.to + message.cc + message.bcc).map { $0.email.lowercased() }).sorted()
    }

    /// Files the owner's copy of a sent message in the server's Sent, once: a copy already there
    /// (by Message-ID: an earlier try whose answer was lost, or a server that files its own) is
    /// taken instead. Then the draft it was sent from leaves the server's Drafts. Sent it is even
    /// when the row has been moved since: the move, queued later, then takes the copy from there.
    mutating func fileSent(_ id: MessageID, _ pending: PendingAction) async throws(SyncError) -> Bool {
        guard let row = try stored({ try store.message(id) }), let raw = try stored({ try store.body(id) }),
              let sent = folder(.sent)
        else {
            return true
        }
        try await ensureOnServer(sent)
        var uid: UInt32?
        let header = row.messageIDHeader ?? ""
        if !header.isEmpty, case let .found(_, existing) = try await search(header, in: sent) {
            uid = existing
        } else {
            uid = try await imap { try await client.append(raw, to: sent.path, flags: ["\\Seen"]) }
        }
        if let drafts = pending.sourceFolderID.flatMap(folder(id:)), drafts.id != sent.id,
           try await isOnServer(drafts),
           case let .found(folder, draftUID) = try await serverDraft(header, in: drafts, pending) {
            try await select(folder)
            try await removeFromServer(draftUID)
        }
        moved[id] = Moved(folder: sent, uid: uid, header: header.isEmpty ? nil : header)
        // A move queued since settles the row itself, with the uid the copy ends with.
        let movedSince = queue.contains { later in
            guard later.id > pending.id, later.action.target == id else {
                return false
            }
            switch later.action {
            case .move, .moveTo, .delete: return true
            default: return false
            }
        }
        if row.folderID == sent.id, !movedSince {
            try stored { try store.settleMove(id, newUID: uid) }
        }
        return true
    }

    /// A folder made here (for a kind the account lacked) is on the server only once something made
    /// it there; until then there is nothing in it to look for.
    private mutating func isOnServer(_ folder: Folder) async throws(SyncError) -> Bool {
        guard folder.uidValidity == 0 else { return true }
        if serverPaths == nil {
            serverPaths = Set(try await imap { try await client.listFolders() }.map(\.path))
        }
        return serverPaths?.contains(folder.path) == true
    }

    /// The server's copy of the draft a message was sent from: by the uid it had when it was sent,
    /// else by Message-ID.
    private mutating func serverDraft(_ header: String, in drafts: Folder, _ pending: PendingAction)
        async throws(SyncError) -> Location {
        try await select(drafts)
        if pending.sourceUID > 0, !renumbered.contains(drafts.id) {
            return .found(drafts, pending.sourceUID)
        }
        return try await search(header.isEmpty ? nil : header, in: drafts)
    }

    /// The draft's Message-ID; one is made for a draft without and kept on its row before the
    /// first try, so a second try sends the same message.
    func messageID(of draft: MIMEMessage, _ row: MessageRow) throws(SyncError) -> String {
        // One the writer cannot carry (blank, or too long for a line) is made anew.
        if let own = draft.messageID ?? row.messageIDHeader, MIMEWriter.canWrite(messageID: own) {
            return own
        }
        let domain = account.email.split(separator: "@").last.map(String.init) ?? "outwright.invalid"
        let minted = "\(UUID().uuidString)@\(domain)"
        var updated = row
        updated.messageIDHeader = minted
        let (calendar, attachments) = Self.calendarAndAttachments(draft)
        let rewritten = OutgoingMessage(
            from: draft.from.first ?? Address(name: nil, email: account.email), to: draft.to, cc: draft.cc,
            bcc: draft.bcc, subject: draft.subject, textBody: draft.textBody ?? "", htmlBody: draft.htmlBody,
            attachments: attachments, inReplyTo: draft.inReplyTo.first, references: draft.references,
            date: draft.date ?? now, messageID: minted, calendar: calendar)
        let body: Data
        do {
            body = try MIMEWriter.write(rewritten, includeBcc: true)
        } catch {
            throw .store("draftUnreadable")
        }
        _ = try stored { try store.upsert([updated]) }
        _ = try stored { try store.setBody(body, for: row.id) }
        return minted
    }

    /// A reply draft written with a calendar part (text and an iTIP REPLY, no HTML) keeps it as that
    /// part, and the reader's copy of it among the attachments is left out so it is not sent twice.
    /// Any other calendar file (a PUBLISH attached by another client, say), and any in a draft with
    /// HTML (the composer's), stays an ordinary attachment with its filename.
    static func calendarAndAttachments(_ draft: MIMEMessage) -> (CalendarPart?, [Attachment]) {
        guard let calendar = draft.calendar, calendar.method == "REPLY", draft.htmlBody == nil else {
            return (nil, draft.attachments)
        }
        var attachments = draft.attachments
        if let copy = attachments.firstIndex(where: { $0.mimeType == "text/calendar" && $0.data == calendar.data }) {
            attachments.remove(at: copy)
        }
        return (calendar, attachments)
    }

    /// The draft rewritten for sending, dated now and from the account, with the headers the
    /// protections add to every message.
    func outgoingMessage(_ draft: MIMEMessage, messageID: String) async -> OutgoingMessage {
        let (calendar, attachments) = Self.calendarAndAttachments(draft)
        var message = OutgoingMessage(
            from: Address(name: account.displayName.isEmpty ? nil : account.displayName, email: account.email),
            to: draft.to, cc: draft.cc, bcc: draft.bcc, subject: draft.subject, textBody: draft.textBody ?? "",
            htmlBody: draft.htmlBody, attachments: attachments, inReplyTo: draft.inReplyTo.first,
            references: draft.references, date: now, messageID: messageID, calendar: calendar)
        for hook in protections.values {
            message.extraHeaders += await hook.headers(for: account)
        }
        return message
    }

    /// The message written for sending: as the recipients get it (no Bcc), as the owner keeps it in
    /// Sent (with Bcc), and who gets it.
    func outgoing(_ message: OutgoingMessage) throws(SyncError) -> Outgoing {
        let data: Data
        let ownCopy: Data
        do {
            data = try MIMEWriter.write(message, includeBcc: false)
            ownCopy = try MIMEWriter.write(message, includeBcc: true)
        } catch {
            throw .store("draftUnreadable")
        }
        var seen: Set<String> = []
        let everyone = (message.to + message.cc + message.bcc).map(\.email)
        let recipients = everyone.filter { seen.insert($0.lowercased()).inserted }
        return Outgoing(wire: data, ownCopy: ownCopy, recipients: recipients)
    }

    /// Whether a save, a send, or a move or delete of the draft was queued after `pending`.
    private func supersededSince(_ pending: PendingAction, _ draftID: MessageID) -> Bool {
        queue.contains { later in
            guard later.id > pending.id, later.action.target == draftID else {
                return false
            }
            switch later.action {
            case .saveDraft, .send, .delete, .move, .moveTo: return true
            default: return false
            }
        }
    }

    enum KeptForm {
        case bytes(Data)
        /// Nothing to save: a later action of the draft takes over.
        case done
        /// Not yet: tried again on a later run.
        case waits
    }

    /// The draft as the server keeps it. One that asks for a protection is kept as that protection
    /// makes it; the body here stays as written. One the protection cannot make (or that is not in
    /// this build) never goes there in the clear: a later save, send, move or delete of it takes over,
    /// else it waits for a later run, quietly (never counted as a miss nor given up; the draft's later
    /// actions wait with it).
    private func keptForm(
        _ raw: Data, _ draftID: MessageID, _ pending: PendingAction
    ) async throws(SyncError) -> KeptForm {
        guard let requirement = try stored({ try store.protection(of: draftID) }), requirement.kind == .encrypt else {
            return .bytes(raw)
        }
        if let protected = await protections[requirement.protection]?.protectDraft(raw, account: account) {
            return .bytes(protected)
        }
        if requirement.plainChosen { return .bytes(raw) }
        return supersededSince(pending, draftID) ? .done : .waits
    }

    /// Stores the draft in Drafts and removes the copy saved before.
    mutating func saveDraft(_ draftID: MessageID, _ pending: PendingAction) async throws(SyncError) -> Bool {
        guard let row = try stored({ try store.message(draftID) }), let raw = try stored({ try store.body(draftID) }),
              let drafts = folder(.drafts)
        else {
            return true
        }
        // Deleted or sent since it was queued: no longer a draft to keep.
        guard folder(id: row.folderID)?.kind == .drafts else {
            return true
        }
        let kept: Data
        switch try await keptForm(raw, draftID, pending) {
        case let .bytes(data): kept = data
        case .done: return true
        case .waits:
            waiting = true
            return false
        }
        try await ensureOnServer(drafts)
        // Every copy saved before goes once the new one is stored: the one the row holds, and any
        // left by a save whose connection dropped between the two steps (found by Message-ID).
        // Selected first, so a folder the server has numbered anew is known before the row's uid is trusted.
        try await select(drafts)
        var older: Set<UInt32> = []
        if let header = row.messageIDHeader, !header.isEmpty {
            older = Set(try await imap { try await client.uids(messageID: header) })
        }
        if row.folderID == drafts.id, row.uid > 0, !renumbered.contains(drafts.id) {
            older.insert(row.uid)
        }
        let newUID = try await imap { try await client.append(kept, to: drafts.path, flags: ["\\Draft", "\\Seen"]) }
        if let newUID {
            older.remove(newUID)
        }
        if !older.isEmpty {
            try await select(drafts)
            try await removeFromServer(older.sorted())
        }
        // The server holds it protected: the row is marked, so the server's outer headers never
        // overwrite what it was written with.
        if kept != raw, MessageReader.isEncryptedShape(kept) {
            try stored { try store.markProtected(draftID) }
        }
        // Without APPENDUID the next sync finds the new copy by its Message-ID.
        try stored { try store.setUID(newUID ?? 0, for: draftID) }
        return true
    }
}

extension SendRefusal {
    /// A refusal for good (a 5xx reply, or a recipient that is no address); nil for anything worth
    /// trying again (a 4xx reply, the network, signing in).
    init?(_ error: SMTPError) {
        switch error {
        case let .recipientRejected(code, _) where (500..<600).contains(code):
            self = .recipientRefused
        case let .rejected(code, _) where (500..<600).contains(code):
            self = .messageRefused
        case .noRecipients, .invalidRecipient:
            self = .invalidRecipient
        case .smtpUTF8NotOffered:
            self = .addressNeedsSMTPUTF8
        default:
            return nil
        }
    }
}
