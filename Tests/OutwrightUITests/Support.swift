// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightMIME
import OutwrightModel
import OutwrightStore
import OutwrightSync
@testable import OutwrightUI

/// An in-memory store with accounts and their standard folders, and a way to add synthetic mail.
struct Mailbox {
    let store: MailStore
    var accounts: [Account] = []

    init() throws {
        store = try MailStore(path: nil)
    }

    @discardableResult
    /// `cardDAV`: the account keeps contacts (only an account with a CardDAV address does); `calDAV` the same
    /// for calendars.
    mutating func addAccount(
        _ email: String, extraFolders: [String] = [], delimiter: String? = nil, cardDAV: Bool = false,
        calDAV: Bool = false
    ) throws -> Account {
        let endpoint = MailEndpoint(host: "mail.example.org", port: 993, security: "tls")
        let account = Account(
            id: AccountID(raw: UUID()), displayName: email, email: email, colorIndex: accounts.count,
            imap: endpoint, smtp: endpoint, user: email, signature: "", sortOrder: accounts.count,
            cardDAV: cardDAV ? "https://dav.example.org/" : nil, calDAV: calDAV ? "https://dav.example.org/" : nil)
        try store.save(account)
        let kinds: [(String, FolderKind)] = [
            ("Trash", .trash), ("INBOX", .inbox), ("Sent", .sent), ("Drafts", .drafts), ("Junk", .junk),
            ("Archive", .archive),
        ] + extraFolders.map { ($0, .other) }
        try store.replaceFolders(
            kinds.map { path, kind in
                var folder = Folder(
                    id: FolderID(raw: 0), accountID: account.id, path: path,
                    name: delimiter.flatMap { path.components(separatedBy: $0).last } ?? path, kind: kind,
                    uidValidity: 1, unread: 0, isFavorite: false)
                folder.delimiter = delimiter
                return folder
            }, for: account.id)
        accounts.append(account)
        return account
    }

    func folder(_ account: Account, _ kind: FolderKind) throws -> Folder {
        guard let found = try store.folders(account.id).first(where: { $0.kind == kind }) else {
            throw StoreError.noSuchFolder
        }
        return found
    }

    @discardableResult
    func add(
        _ account: Account, _ kind: FolderKind = .inbox, uid: UInt32, thread: String? = nil,
        from: String = "bo@example.org", subject: String = "Hej", date: Date = Date(timeIntervalSince1970: 1_800_000_000),
        read: Bool = false, flagged: Bool = false, cls: InboxClass = .focused, body: Data? = nil,
        to: [String]? = nil
    ) throws -> MessageID {
        let folder = try folder(account, kind)
        let row = MessageRow(
            id: MessageID(raw: 0), accountID: account.id, folderID: folder.id, uid: uid,
            threadID: ThreadID(raw: thread ?? "t\(uid)-\(account.email)"),
            from: Address(name: "Bo", email: from), to: (to ?? [account.email]).map { Address(name: nil, email: $0) }, cc: [],
            subject: subject, preview: "preview \(uid)", date: date, isRead: read, isFlagged: flagged,
            hasAttachment: false, isInvitation: false, inboxClass: cls, hasBody: body != nil, threadCount: 1)
        guard let id = try store.upsert([row]).first else { throw StoreError.noSuchMessage }
        if let body { try store.setBody(body, for: id) }
        return id
    }
}

extension Mailbox {
    /// A contact in the account's address book (made on first use); the account needs `cardDAV`.
    func addContact(_ account: Account, _ details: ContactDetails) throws {
        if try store.addressBooks(account.id).isEmpty {
            try store.replaceAddressBooks([(href: "/book/", name: "Contacts", isReadOnly: false)], for: account.id)
        }
        guard let book = try store.addressBooks(account.id).first else { throw StoreError.noSuchFolder }
        try store.upsertRemote(
            href: "/book/\(UUID().uuidString).vcf", etag: "e1", vcard: Data("BEGIN:VCARD".utf8), details: details,
            photo: nil, in: book.id)
    }

    /// An event in the account's calendar (made on first use), laid out a year around `now`; the
    /// account needs `calDAV`.
    func addEvent(_ account: Account, _ details: EventDetails, now: Date, rule: RecurrenceRule? = nil) throws {
        if try store.calendars(account.id).isEmpty {
            try store.replaceCalendars(
                [(href: "/cal/", name: "Work", color: nil, isReadOnly: false)], for: account.id)
        }
        guard let cal = try store.calendars(account.id).first else { throw StoreError.noSuchFolder }
        let uid = UUID().uuidString
        try store.upsertRemote(
            href: "/cal/\(uid).ics", etag: "e1", ics: Data("BEGIN:VCALENDAR".utf8),
            series: EventSeries(uid: uid, base: details, rule: rule), in: cal.id,
            window: now.addingTimeInterval(-200 * 86_400)...now.addingTimeInterval(200 * 86_400),
            phoneZone: TimeZone(identifier: "UTC") ?? .gmt, scheduleTag: nil)
    }
}

func message(subject: String, text: String) throws -> Data {
    try MIMEWriter.write(
        OutgoingMessage(
            from: Address(name: "Bo", email: "bo@example.org"), to: [Address(name: nil, email: "anna@example.org")],
            cc: [], bcc: [], subject: subject, textBody: text, htmlBody: nil, attachments: [], inReplyTo: nil,
            references: [], date: Date(timeIntervalSince1970: 1_800_000_000), messageID: "m@example.org"),
        includeBcc: false)
}

/// Reminders that go nowhere; the last set handed over is kept, and the handovers and permission
/// questions counted.
actor KeptReminders: Reminders {
    private(set) var last: [PlannedReminder] = []
    private(set) var questions = 0
    /// How many times a set was handed over.
    private(set) var handovers = 0
    private let allowed: Bool

    init(allowed: Bool = true) {
        self.allowed = allowed
    }

    func authorization() async -> Bool { allowed }
    func requestAuthorization() async -> Bool {
        questions += 1
        return allowed
    }
    func replace(_ planned: [PlannedReminder]) async {
        last = planned
        handovers += 1
    }
}

/// The only way the UI tests build a coordinator: discovery asks a resolver with no answers and (unless
/// a test gives its own) a probe that finds nothing, and reminders go nowhere, so nothing leaves the process.
func offlineSync(
    store: MailStore, secrets: any SecretStore,
    backoff: ClosedRange<Duration> = .seconds(2) ... .seconds(60), resolver: any DoHResolving = FixedDoH(answers: [:]),
    probe: @escaping @Sendable (URL) async -> URL? = { _ in nil }, phoneContacts: (any PhoneContacts)? = nil,
    reminders: KeptReminders = KeptReminders(), available: Set<ProviderID>? = nil
) -> SyncCoordinator {
    SyncCoordinator(
        store: store, secrets: secrets, available: available, backoff: backoff, resolver: resolver,
        davSession: URLSession(configuration: .ephemeral), probe: probe, phoneContacts: phoneContacts,
        reminders: reminders)
}

/// What a message being written shows: the body, and the quoted original under it.
@MainActor func shownText(_ model: ComposeModel) -> String {
    String(model.body.characters) + (model.quoted?.shown ?? "")
}
