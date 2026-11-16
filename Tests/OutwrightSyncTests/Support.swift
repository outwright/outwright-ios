// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightFakes
import OutwrightIMAP
import OutwrightMIME
import OutwrightModel
import OutwrightNet
import OutwrightStore
import OutwrightSync
import Testing

/// The tests' clock: 6 November 2026, 12:00 UTC.
let fixedNow = Date(timeIntervalSince1970: 1_793_966_400)
/// An OAuth provider with Graph, as the tests sign accounts in with.
let testOAuthProvider = ProviderID(raw: "oauth-test")

func daysAgo(_ days: Double) -> Date {
    fixedNow.addingTimeInterval(-days * 86_400)
}

private let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .gmt
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
    return formatter
}()

/// A synthetic message. `list` makes it bulk (a List-Id header).
func mail(
    _ subject: String, from: String = "bo@example.org", to: String = "jk@example.org", date: Date = daysAgo(1),
    id: String? = nil, inReplyTo: String? = nil, list: Bool = false, body: String = "Hello there"
) -> Data {
    var lines = [
        "From: \(from)", "To: \(to)", "Subject: \(subject)", "Date: \(dateFormatter.string(from: date))",
    ]
    if let id { lines.append("Message-ID: <\(id)>") }
    if let inReplyTo { lines.append("In-Reply-To: <\(inReplyTo)>") }
    if list { lines.append("List-Id: <news.shop.example>") }
    return Data((lines.joined(separator: "\r\n") + "\r\n\r\n" + body + "\r\n").utf8)
}

/// A fake server with the usual special folders.
func standardServer(offersMove: Bool = true, offersUIDPlus: Bool = true) async -> FakeIMAPServer {
    let server = FakeIMAPServer(offersMove: offersMove, offersUIDPlus: offersUIDPlus)
    await server.addFolder("Sent", specialUse: "\\Sent")
    await server.addFolder("Drafts", specialUse: "\\Drafts")
    await server.addFolder("Trash", specialUse: "\\Trash")
    return server
}

struct Harness {
    let imap: FakeIMAPServer
    let smtp: FakeSMTPServer
    let imapPort: UInt16
    let store: MailStore
    let secrets: InMemorySecretStore
    let account: Account

    func syncer() -> AccountSyncer {
        AccountSyncer(account: account, store: store, secrets: secrets, now: { fixedNow })
    }

    func folder(_ kind: FolderKind) throws -> Folder {
        try #require(try store.folders(account.id).first { $0.kind == kind })
    }

    /// The folder's messages, oldest uid first.
    func rows(_ kind: FolderKind) throws -> [MessageRow] {
        let index = try store.folderIndex(try folder(kind).id)
        return try index.keys.sorted().compactMap { uid in try index[uid].flatMap { try store.message($0) } }
    }

    /// A client of its own, signed in, for changing the server behind the syncer's back.
    func sideClient() async throws -> IMAPClient {
        let client = try await IMAPClient.connect(ServerEndpoint(host: "127.0.0.1", port: imapPort, security: .plainLoopbackOnly))
        try await client.login(user: FakeIMAPServer.user, password: Secret(FakeIMAPServer.password))
        return client
    }

    static func account(imapPort: UInt16, smtpPort: UInt16) -> Account {
        Account(
            id: AccountID(), displayName: "Jörgen", email: "jk@example.org", colorIndex: 0,
            imap: MailEndpoint(host: "127.0.0.1", port: imapPort, security: "plainLoopbackOnly"),
            smtp: MailEndpoint(host: "127.0.0.1", port: smtpPort, security: "plainLoopbackOnly"),
            user: FakeIMAPServer.user, signature: "", sortOrder: 0)
    }
}

/// Starts both fakes, an in-memory store and secrets holding the right password, runs `body`,
/// and stops the fakes whatever happens.
func withHarness(
    _ imap: FakeIMAPServer? = nil, smtp: FakeSMTPServer = FakeSMTPServer(), _ body: (Harness) async throws -> Void
) async throws {
    let server: FakeIMAPServer
    if let imap {
        server = imap
    } else {
        server = await standardServer()
    }
    let imapPort = try await server.start()
    let smtpPort = try await smtp.start()
    do {
        let store = try MailStore(path: nil)
        let account = Harness.account(imapPort: imapPort, smtpPort: smtpPort)
        try store.save(account)
        let secrets = InMemorySecretStore()
        try secrets.setPassword(Secret(FakeIMAPServer.password), for: account.id)
        try await body(Harness(
            imap: server, smtp: smtp, imapPort: imapPort, store: store, secrets: secrets, account: account))
    } catch {
        await server.stop()
        await smtp.stop()
        throw error
    }
    await server.stop()
    await smtp.stop()
}

/// Waits up to `seconds` for `condition`. The limit is generous because CI shares a busy machine;
/// a wait that is met returns at once.
func eventually(seconds: Double = 60, _ condition: () async throws -> Bool) async rethrows -> Bool {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while ContinuousClock.now < deadline {
        if try await condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return try await condition()
}

/// The only way the tests build a coordinator: discovery asks the fake resolver and (unless a test
/// gives its own) a probe that finds nothing, and reminders are recorded, so nothing leaves the process.
func offlineCoordinator(
    store: MailStore, secrets: any SecretStore, now: @escaping @Sendable () -> Date = { fixedNow },
    phoneZone: @escaping @Sendable () -> TimeZone = { .current }, actionDelay: Duration = .seconds(1), idleTimeout: Duration = AccountSyncer.idleTimeout,
    backoff: ClosedRange<Duration> = .seconds(2) ... .seconds(60),
    resolver: any DoHResolving = FakeDoH(), davSession: URLSession = URLSession(configuration: .ephemeral),
    probe: @escaping @Sendable (URL) async -> URL? = { _ in nil }, phoneContacts: (any PhoneContacts)? = nil,
    reminders: any Reminders = RecordingReminders(), protections: [any MailProtection] = []
) -> SyncCoordinator {
    SyncCoordinator(
        store: store, secrets: secrets, now: now, phoneZone: phoneZone, backoff: backoff, actionDelay: actionDelay,
        idleTimeout: idleTimeout, resolver: resolver, davSession: davSession, probe: probe, phoneContacts: phoneContacts,
        reminders: reminders, protections: protections)
}
