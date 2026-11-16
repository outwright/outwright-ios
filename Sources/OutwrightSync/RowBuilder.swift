// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightIMAP
import OutwrightMIME
import OutwrightModel
import OutwrightStore

/// Turns summaries into rows: threaded (across the batch too), classified, previewed.
struct RowBuilder {
    let account: Account
    let folder: Folder
    let store: MailStore
    let correspondents: Set<String>
    let overrides: [String: InboxClass]
    var threads: [String: ThreadID] = [:]
    var ownThreads: [ThreadID: Bool] = [:]

    init(
        account: Account, folder: Folder, store: MailStore, correspondents: Set<String>,
        overrides: [String: InboxClass]
    ) {
        self.account = account
        self.folder = folder
        self.store = store
        self.correspondents = correspondents
        self.overrides = overrides
    }

    mutating func row(_ summary: MessageSummary) -> MessageRow {
        let parsed = Self.headers(summary)
        let from = Self.sender(parsed)
        let isProtected = MessageReader.isEncryptedShape(parsed)
        let known = threads
        let threadID = Threading.threadID(
            messageID: parsed.messageID, inReplyTo: parsed.inReplyTo, references: parsed.references,
            subject: parsed.subject, accountID: account.id, folderPath: folder.path, uid: summary.uid,
            isProtected: isProtected
        ) { [store, account] id in
            known[id] ?? (try? store.threadID(forMessageID: id, account: account.id)) ?? nil
        }
        if let own = parsed.messageID {
            threads[own] = threadID
        }
        let isReply = !parsed.inReplyTo.isEmpty || !parsed.references.isEmpty
        let inboxClass = FocusedClassifier.classify(
            from: from, isBulk: parsed.isBulk, isReplyToOwn: isReply && ownerTookPart(threadID),
            correspondents: correspondents, overrides: overrides)
        return MessageRow(
            id: MessageID(raw: 0), accountID: account.id, folderID: folder.id, uid: summary.uid, threadID: threadID,
            from: from, to: parsed.to, cc: parsed.cc, subject: parsed.subject,
            preview: isProtected ? "" : Preview.text(fromPartial: summary.partialText, headers: summary.headers),
            date: parsed.date ?? summary.internalDate, isRead: summary.flags.contains("\\Seen"),
            isFlagged: summary.flags.contains("\\Flagged"),
            hasAttachment: Self.mayHaveAttachment(parsed),
            isInvitation: parsed.isInvitation, inboxClass: inboxClass, hasBody: false, threadCount: 1,
            messageIDHeader: parsed.messageID,
            references: Array(parsed.references.prefix(256)) + Array(parsed.inReplyTo.prefix(16)),
            isProtected: isProtected)
    }

    /// The summary's headers, decoded; empty when they will not parse.
    static func headers(_ summary: MessageSummary) -> MIMEMessage {
        (try? MIMEParser.parseHeaders(summary.headers)) ?? MIMEMessage()
    }

    /// The first From address; an empty one when there is none.
    static func sender(_ parsed: MIMEMessage) -> Address {
        parsed.from.first ?? Address(name: nil, email: "")
    }

    /// From the headers alone: a mixed multipart, a message that is one file, or one that says it is
    /// an attachment. The body, once fetched, tells for sure (`MailStore.setBody`).
    static func mayHaveAttachment(_ parsed: MIMEMessage) -> Bool {
        func header(_ name: String) -> String {
            parsed.rawHeaders.first { $0.name.lowercased() == name }?.value.lowercased()
                .trimmingCharacters(in: .whitespaces) ?? ""
        }
        let type = header("content-type")
        if type.hasPrefix("multipart/mixed") || header("content-disposition").hasPrefix("attachment") {
            return true
        }
        return !type.isEmpty && !type.hasPrefix("text/") && !type.hasPrefix("multipart/")
            && !type.hasPrefix("message/")
    }

    /// Whether the thread holds a message the owner sent.
    private mutating func ownerTookPart(_ thread: ThreadID) -> Bool {
        if let known = ownThreads[thread] {
            return known
        }
        let owner = Address(name: nil, email: account.email)
        let rows = (try? store.thread(thread, account: account.id)) ?? []
        let tookPart = rows.contains { $0.from == owner }
        ownThreads[thread] = tookPart
        return tookPart
    }
}
