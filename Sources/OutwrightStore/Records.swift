// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import GRDB
import OutwrightMIME
import OutwrightModel

/// Addresses as stored: JSON, since `Address` is not Codable.
private struct StoredAddress: Codable {
    var name: String?
    var email: String
}

enum Records {
    static let messageColumns = """
        m.id, m.accountId, m.folderId, m.uid, m.threadId, m.fromName, m.fromEmail, m.toJSON, m.ccJSON,
        m.subject, m.preview, m.date, m.isRead, m.isFlagged, m.hasAttachment, m.isInvitation,
        m.inboxClass, m.messageIdHeader, m.notSent, m.isProtected, m.isDecrypted, (m.body IS NOT NULL) AS hasBody
        """

    static func encode(_ list: [Address]) -> String {
        let stored = list.prefix(1_000).map { StoredAddress(name: $0.name, email: $0.email) }
        guard let data = try? JSONEncoder().encode(stored) else { return "[]" }
        return String(bytes: data, encoding: .utf8) ?? "[]"
    }

    static func decode(_ json: String?) -> [Address] {
        guard let data = json?.data(using: .utf8),
            let stored = try? JSONDecoder().decode([StoredAddress].self, from: data)
        else { return [] }
        return stored.map { Address(name: $0.name, email: $0.email) }
    }

    /// A row from a query that selects `messageColumns` and `cnt`. Nil when stored data is unusable.
    static func message(_ row: Row) -> MessageRow? {
        guard let account = (row["accountId"] as String?).flatMap({ UUID(uuidString: $0) }),
            let id = row["id"] as Int64?, let folder = row["folderId"] as Int64?
        else { return nil }
        let uid = (row["uid"] as Int64?) ?? 0
        return MessageRow(
            id: MessageID(raw: id), accountID: AccountID(raw: account), folderID: FolderID(raw: folder),
            uid: UInt32(clamping: uid), threadID: ThreadID(raw: (row["threadId"] as String?) ?? ""),
            from: Address(name: row["fromName"] as String?, email: (row["fromEmail"] as String?) ?? ""),
            to: decode(row["toJSON"] as String?), cc: decode(row["ccJSON"] as String?),
            subject: (row["subject"] as String?) ?? "", preview: (row["preview"] as String?) ?? "",
            date: Date(timeIntervalSince1970: (row["date"] as Double?) ?? 0),
            isRead: ((row["isRead"] as Int?) ?? 0) != 0, isFlagged: ((row["isFlagged"] as Int?) ?? 0) != 0,
            hasAttachment: ((row["hasAttachment"] as Int?) ?? 0) != 0,
            isInvitation: ((row["isInvitation"] as Int?) ?? 0) != 0,
            inboxClass: InboxClass(rawValue: (row["inboxClass"] as String?) ?? "") ?? .focused,
            hasBody: ((row["hasBody"] as Int?) ?? 0) != 0, threadCount: max(1, (row["cnt"] as Int?) ?? 1),
            messageIDHeader: row["messageIdHeader"] as String?,
            notSent: (row["notSent"] as String?).flatMap(SendRefusal.init(rawValue:)),
            isProtected: ((row["isProtected"] as Int?) ?? 0) != 0,
            isDecrypted: ((row["isDecrypted"] as Int?) ?? 0) != 0)
    }

    static func account(_ row: Row) -> Account? {
        guard let id = (row["id"] as String?).flatMap({ UUID(uuidString: $0) }) else { return nil }
        return Account(
            id: AccountID(raw: id), displayName: (row["displayName"] as String?) ?? "",
            email: (row["email"] as String?) ?? "", colorIndex: (row["colorIndex"] as Int?) ?? 0,
            imap: MailEndpoint(
                host: (row["imapHost"] as String?) ?? "",
                port: UInt16(clamping: (row["imapPort"] as Int?) ?? 0),
                security: (row["imapSecurity"] as String?) ?? ""),
            smtp: MailEndpoint(
                host: (row["smtpHost"] as String?) ?? "",
                port: UInt16(clamping: (row["smtpPort"] as Int?) ?? 0),
                security: (row["smtpSecurity"] as String?) ?? ""),
            user: (row["user"] as String?) ?? "", signature: (row["signature"] as String?) ?? "",
            sortOrder: (row["sortOrder"] as Int?) ?? 0, cardDAV: row["cardDAV"] as String?,
            cardDAVUnconfirmed: row["cardDAVUnconfirmed"] as String?,
            savesContactsToPhone: ((row["savesContactsToPhone"] as Int?) ?? 0) != 0,
            cardDAVOff: ((row["cardDAVOff"] as Int?) ?? 0) != 0, calDAV: row["calDAV"] as String?,
            calDAVUnconfirmed: row["calDAVUnconfirmed"] as String?,
            calDAVOff: ((row["calDAVOff"] as Int?) ?? 0) != 0,
            auth: AccountAuth(rawValue: (row["auth"] as String?) ?? "") ?? .password,
            provider: (row["provider"] as String?).flatMap { $0.isEmpty ? nil : ProviderID(raw: $0) } ?? .ownServer,
            calendarVia: CalendarVia(rawValue: (row["calendarVia"] as String?) ?? "") ?? .calDAV,
            contactsVia: ContactsVia(rawValue: (row["contactsVia"] as String?) ?? "") ?? .cardDAV)
    }

    static func folder(_ row: Row) -> Folder? {
        guard let account = (row["accountId"] as String?).flatMap({ UUID(uuidString: $0) }),
            let id = row["id"] as Int64?
        else { return nil }
        return Folder(
            id: FolderID(raw: id), accountID: AccountID(raw: account),
            path: (row["path"] as String?) ?? "", name: (row["name"] as String?) ?? "",
            kind: FolderKind(rawValue: (row["kind"] as String?) ?? "") ?? .other,
            uidValidity: UInt32(clamping: (row["uidValidity"] as Int64?) ?? 0),
            unread: (row["unread"] as Int?) ?? 0, isFavorite: ((row["isFavorite"] as Int?) ?? 0) != 0,
            delimiter: row["delimiter"] as String?)
    }

    /// The words of a message for the search index: the text body, else the HTML with tags dropped.
    static func indexText(_ parsed: MIMEMessage) -> String {
        let text = parsed.textBody ?? parsed.htmlBody.map(stripTags) ?? ""
        return String(text.prefix(200_000))
    }

    static func stripTags(_ html: String) -> String {
        var out = ""
        var inTag = false
        for char in HTMLText.removingHiddenElements(String(html.prefix(1_000_000))) {
            if char == "<" {
                inTag = true
                out.append(" ")
            } else if char == ">" {
                inTag = false
            } else if !inTag {
                out.append(char)
            }
        }
        return out
    }

    /// A user's search text as an FTS5 query: every word quoted, the last one a prefix.
    static func ftsQuery(_ text: String) -> String? {
        let words = text.split(whereSeparator: { $0.isWhitespace }).prefix(16).map { word -> String in
            // By scalar: a quote followed by a combining mark is one Character, which a Character
            // replacement would miss, leaving a bare quote that breaks the FTS5 query.
            var clean = String.UnicodeScalarView()
            clean.append(contentsOf: word.unicodeScalars.filter { $0 != "\"" })
            return "\"\(String(clean))\""
        }.filter { $0 != "\"\"" }
        guard let last = words.last else { return nil }
        return (words.dropLast() + [last + "*"]).joined(separator: " ")
    }
}
