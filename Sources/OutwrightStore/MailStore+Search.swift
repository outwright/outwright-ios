// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
import GRDB
public import OutwrightModel

/// Text as search compares it: folded (case and accents), split into runs of letters and numbers.
enum SearchText {
    /// Most characters of an occurrence's stored words.
    static let maxStored = 4_096
    /// Most words of a query.
    static let maxQueryWords = 16

    /// The words of `text`, folded, at most `limit` characters of it read.
    static func words(_ text: String, limit: Int) -> [String] {
        let folded = String(text.prefix(max(0, limit))).folding(
            options: [.caseInsensitive, .diacriticInsensitive], locale: nil
        ).lowercased()
        return folded.split { !($0.isLetter || $0.isNumber) }.map(String.init)
    }
}

extension MailStore {
    /// Events whose title, place, notes or people have words starting with each word of `text`
    /// (case and accents ignored). One per event: its first occurrence ending after `now`, else its
    /// last; the upcoming ones nearest first, then the past ones most recent first. As the calendar
    /// shows them: no hidden event, no invitation the owner declined alone.
    public func searchEvents(_ text: String, now: Date, limit: Int) throws(StoreError) -> [CalendarEvent] {
        let words = Array(SearchText.words(text, limit: 1_000).prefix(SearchText.maxQueryWords))
        guard !words.isEmpty else { return [] }
        let wanted = max(1, min(limit, 100))
        let conditions = words.map { _ in "o.searchText LIKE ?" }.joined(separator: " AND ")
        let instant = now.timeIntervalSince1970
        // One occurrence per event, chosen in SQL so a long past never crowds out what is next: the
        // first that has not ended, else the last.
        let rows = try read { database in
            try Row.fetchAll(
                database,
                sql: """
                    WITH matched AS (
                        SELECT o.rowid AS r, o.startUTC AS s, (o.endUTC > ?1) AS ahead,
                            ROW_NUMBER() OVER (
                                PARTITION BY o.eventId
                                ORDER BY (o.endUTC > ?1) DESC,
                                    CASE WHEN o.endUTC > ?1 THEN o.startUTC ELSE -o.startUTC END) AS rn
                        FROM occurrence o JOIN event e ON e.id = o.eventId
                        WHERE \(conditions) AND e.hidden = 0)
                    \(CalendarRecords.occurrenceSelect)
                    JOIN matched ON matched.r = o.rowid AND matched.rn = 1
                    ORDER BY matched.ahead DESC, CASE WHEN matched.ahead THEN matched.s ELSE -matched.s END,
                        o.eventId
                    LIMIT 1000
                    """,
                arguments: StatementArguments([instant] + words.map { "% \($0)%" }))
        }
        // As the calendar shows them: no invitation the owner declined alone.
        let events = rows.compactMap(CalendarRecords.event).filter { !($0.isInvitation && $0.ownResponse == .declined) }
        return Array(events.prefix(wanted))
    }

    /// Words of the mail on the phone that start with the last word of `prefix` (at least two
    /// letters), longer than it, the ones in most messages first.
    public func suggestedWords(startingWith prefix: String, limit: Int) throws(StoreError) -> [String] {
        guard let last = SearchText.words(prefix, limit: 1_000).last, last.count >= 2, last.count <= 64 else {
            return []
        }
        let wanted = max(1, min(limit, 20))
        return try read { database in
            try String.fetchAll(
                database,
                sql: """
                    SELECT term FROM message_vocab WHERE term >= ?1 AND term < ?2 AND term != ?1
                    ORDER BY doc DESC, term LIMIT ?3
                    """,
                arguments: [last, last + "\u{10FFFF}", wanted])
        }
    }
}

/// What search narrows mail by: any of them on at once.
public struct SearchFilter: Hashable, Sendable {
    public var unread: Bool
    public var flagged: Bool
    public var attachments: Bool
    /// Only mail from before this instant.
    public var olderThan: Date?

    public init(unread: Bool = false, flagged: Bool = false, attachments: Bool = false, olderThan: Date? = nil) {
        self.unread = unread
        self.flagged = flagged
        self.attachments = attachments
        self.olderThan = olderThan
    }

    /// How many of unread, flagged and attachments are on.
    public var count: Int { [unread, flagged, attachments].filter { $0 }.count }

    /// SQL conditions on `message m`, with their values in order.
    func conditions() -> ([String], [any DatabaseValueConvertible]) {
        var sql: [String] = []
        var values: [any DatabaseValueConvertible] = []
        if unread { sql.append("m.isRead = 0") }
        if flagged { sql.append("m.isFlagged = 1") }
        if attachments { sql.append("m.hasAttachment = 1") }
        if let olderThan {
            sql.append("m.date < ?")
            values.append(olderThan.timeIntervalSince1970)
        }
        return (sql, values)
    }
}

/// Mail a person sent (`from`), or mail to them or copied to them (`to`).
public enum PersonDirection: Hashable, Sendable {
    case from, to
}

extension MailStore {
    /// Most addresses one person's mail is looked up by.
    static let maxPersonAddresses = 20

    /// Contacts with a word of their name, organization or addresses starting with each word of
    /// `text` (case and accents ignored), or, when `text` holds at least three digits (leading zeros
    /// aside), a phone number holding those digits. In the contacts' order; a queued deletion is hidden.
    public func searchContacts(_ text: String, limit: Int) throws(StoreError) -> [Contact] {
        let words = Array(SearchText.words(text, limit: 1_000).prefix(SearchText.maxQueryWords))
        let digits = String(text.prefix(1_000).filter(\.isASCIIDigitCharacter).drop { $0 == "0" })
        guard !words.isEmpty || digits.count >= 3 else { return [] }
        let wanted = max(1, min(limit, 200))
        var found: [Contact] = []
        for contact in try contacts(in: nil, matching: nil) where found.count < wanted {
            let details = contact.details
            let fields = [details.displayName, details.givenName, details.familyName, details.organization]
                + details.emails.map(\.value)
            let own = Set(SearchText.words(fields.joined(separator: " "), limit: SearchText.maxStored))
            let byName = !words.isEmpty && words.allSatisfy { word in own.contains { $0.hasPrefix(word) } }
            let byPhone = digits.count >= 3 && details.phones.contains { phone in
                String(phone.value.prefix(100).filter(\.isASCIIDigitCharacter)).contains(digits)
            }
            if byName || byPhone { found.append(contact) }
        }
        return found
    }

    /// Mail from (`from`), or to or copied to (`to`), any of `emails`, matching `text`'s words when
    /// given and narrowed by `filter`; newest first.
    public func messages(
        involving emails: Set<String>, direction: PersonDirection, matching text: String?, filter: SearchFilter,
        limit: Int
    ) throws(StoreError) -> [MessageRow] {
        let keys = Array(
            Set(emails.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty })
        ).sorted().prefix(Self.maxPersonAddresses)
        guard !keys.isEmpty else { return [] }
        let wanted = max(1, min(limit, 1_000))
        var (conditions, values) = Self.personConditions(Array(keys), direction)
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let match = Records.ftsQuery(text) else { return [] }
            conditions.append("m.id IN (SELECT rowid FROM message_fts WHERE message_fts MATCH ?)")
            values.append(match)
        }
        let (narrowing, narrowingValues) = filter.conditions()
        conditions += narrowing
        values += narrowingValues
        let wantedKeys = Set(keys)
        return try read { database in
            var found: [MessageRow] = []
            let cursor = try Row.fetchCursor(
                database,
                sql: """
                    SELECT \(Records.messageColumns), 1 AS cnt FROM message m
                    WHERE \(conditions.joined(separator: " AND "))
                    ORDER BY m.date DESC, m.id DESC
                    """, arguments: StatementArguments(values))
            while found.count < wanted, let row = try cursor.next() {
                guard let message = Records.message(row) else { continue }
                switch direction {
                case .from:
                    found.append(message)
                case .to:
                    // The LIKE only narrows: `bo@` must not match inside `jbo@`.
                    let recipients = (message.to + message.cc).map { $0.email.lowercased() }
                    if recipients.contains(where: wantedKeys.contains) { found.append(message) }
                }
            }
            return found
        }
    }

    /// Who the mail is from, or to or copied to: for `to` a LIKE that only narrows.
    private static func personConditions(
        _ keys: [String], _ direction: PersonDirection
    ) -> ([String], [any DatabaseValueConvertible]) {
        switch direction {
        case .from:
            let marks = keys.map { _ in "?" }.joined(separator: ", ")
            return (["swiftLowercaseString(m.fromEmail) IN (\(marks))"], keys)
        case .to:
            let likes = keys.map { _ in
                "swiftLowercaseString(m.toJSON) LIKE ? ESCAPE '\\' OR swiftLowercaseString(m.ccJSON) LIKE ? ESCAPE '\\'"
            }
            let patterns = keys.flatMap { key -> [any DatabaseValueConvertible] in
                let pattern = "%" + likeEscaped(key) + "%"
                return [pattern, pattern]
            }
            return (["(" + likes.joined(separator: " OR ") + ")"], patterns)
        }
    }

    static func likeEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}

extension Character {
    fileprivate var isASCIIDigitCharacter: Bool { isASCII && isNumber }
}
