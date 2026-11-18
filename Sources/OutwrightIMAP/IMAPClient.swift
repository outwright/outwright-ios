// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
public import OutwrightNet
import OutwrightMIME

/// An IMAP4rev1 client (RFC 3501) with SPECIAL-USE (6154), MOVE (6851), UIDPLUS (4315) and
/// IDLE (2177). Commands run one at a time, in the order they were called.
///
/// Paths are wire paths, as `listFolders()` gives them; only `create(_:)` takes a display name.
/// After any failure but a NO or BAD from the server (a timeout, a closed connection, a protocol
/// violation) the connection is closed and every later call fails with `.net(.closed)`.
public actor IMAPClient {
    static let maxResponse = 72 << 20
    static let maxCommandTotal = 128 << 20
    static let maxLiterals = 1024
    static let maxUntagged = 200_000
    static let fetchChunk = 100
    static let storeChunk = 500

    /// How long to wait: for each piece read, for a whole response, and for each byte of a
    /// literal on top of that (a 64 MiB message gets 1,024 more seconds).
    struct Timing: Sendable {
        var perRead: Duration = .seconds(30)
        var response: Duration = .seconds(120)
        var literalBytesPerSecond = 64 << 10
        /// How long past its timeout an IDLE may take to end (the answer to DONE).
        var idleGrace: Duration = .seconds(60)
        /// What one command (or one IDLE) may bring in all: `maxCommandTotal`, lower only in a test,
        /// so the cap is reached without sending 128 MiB.
        var commandTotal = IMAPClient.maxCommandTotal
    }

    let connection: LineConnection
    let timing: Timing
    public internal(set) var capabilities: Set<String> = []
    /// What NAMESPACE said on this connection, once asked.
    var namespaceAnswer: NamespaceAnswer?
    /// What ENABLE turned on for this connection (RFC 5161), as the server's ENABLED said.
    var enabled: Set<String> = []
    /// Whether a folder is selected on this connection: a SELECT this client saw succeed.
    var hasSelected = false
    var tagNumber = 0
    var busy = false
    var broken = false
    /// Callers waiting for the turn; one without an id can't be cancelled (a logout).
    var waiting: [(id: Int?, turn: CheckedContinuation<Bool, Never>)] = []
    var nextWaiter = 0
    var idleGeneration = 0
    var idleStage = IdleStage.ended

    private init(connection: LineConnection, timing: Timing) {
        self.connection = connection
        self.timing = timing
    }

    /// Connects and reads the greeting. For `.startTLS` the server must offer STARTTLS, or the
    /// connection is closed with `.startTLSNotOffered` before anything else is sent.
    public static func connect(_ endpoint: ServerEndpoint) async throws(IMAPError) -> IMAPClient {
        try await connect(endpoint, timing: Timing())
    }

    static func connect(_ endpoint: ServerEndpoint, timing: Timing) async throws(IMAPError) -> IMAPClient {
        let connection: LineConnection
        do {
            connection = try await LineConnection.open(endpoint, timeout: timing.perRead)
        } catch {
            throw .net(error)
        }
        let client = IMAPClient(connection: connection, timing: timing)
        do {
            try await client.perform { () async throws(IMAPError) in
                try await client.greet(security: endpoint.security)
            }
        } catch {
            // Refused (STARTTLS not offered, a BYE) or broken: either way nothing more is sent.
            await client.logoutWithoutCommand()
            throw error
        }
        return client
    }

    public func login(user: String, password: Secret) async throws(IMAPError) {
        try await perform { () async throws(IMAPError) in
            guard !capabilities.contains("LOGINDISABLED") else {
                throw .no("The server does not allow LOGIN on this connection")
            }
            let completion = try await execute([.word("LOGIN"), .string(user), .string(password.reveal())])
            // The server's words after a LOGIN may repeat what it was sent; never pass them on.
            guard completion.kind == .ok else {
                throw .authenticationFailed
            }
            try await refreshCapabilities(from: completion.code)
            try await enableResync()
        }
    }

    public func listFolders() async throws(IMAPError) -> [IMAPFolder] {
        try await perform { () async throws(IMAPError) in
            let completion = try await run([.word("LIST"), .string(""), .string("*")])
            return completion.untagged.compactMap(IMAPParser.folder(from:))
        }
    }

    public func select(_ path: String) async throws(IMAPError) -> FolderStatus {
        try await select(path, from: nil).0
    }

    static func status(of untagged: [IMAPResponse]) throws(IMAPError) -> FolderStatus {
        var validity: UInt32?
        var next: UInt32 = 0
        var exists = 0
        var modSeq: UInt64?
        for response in untagged {
            switch response {
            case let .data(number?, "EXISTS", _):
                exists = Int(number)
            case let .status(nil, .ok, code?, _):
                let parts = code.split(separator: " ")
                guard parts.count >= 2 else {
                    continue
                }
                switch parts[0].uppercased() {
                case "UIDVALIDITY":
                    validity = Self.number(parts[1], digits: 10).flatMap { UInt32(exactly: $0) } ?? validity
                case "UIDNEXT": next = Self.number(parts[1], digits: 10).flatMap { UInt32(exactly: $0) } ?? next
                case "HIGHESTMODSEQ": modSeq = Self.number(parts[1], digits: 20)
                default: break
                }
            default:
                break
            }
        }
        guard let validity else {
            throw .protocolViolation
        }
        return FolderStatus(uidValidity: validity, uidNext: next, exists: exists, highestModSeq: modSeq)
    }

    /// A number of at most `digits` decimal digits, nil for anything else.
    static func number(_ text: Substring, digits: Int) -> UInt64? {
        guard text.utf8.count <= digits, text.utf8.allSatisfy({ (0x30...0x39).contains($0) }) else {
            return nil
        }
        return UInt64(text)
    }

    /// UIDs in the selected folder whose internal date is on or after `since`'s day (UTC).
    public func uids(since: Date) async throws(IMAPError) -> [UInt32] {
        try await perform { () async throws(IMAPError) in
            try await search([.word("SINCE"), .word(InternalDate.searchDate(since))])
        }
    }

    /// UIDs of the mail that arrived before `before` (and on or after `since`, when given).
    public func uids(since: Date?, before: Date) async throws(IMAPError) -> [UInt32] {
        try await perform { () async throws(IMAPError) in
            var keys: [Argument] = [.word("BEFORE"), .word(InternalDate.searchDate(before))]
            if let since {
                keys += [.word("SINCE"), .word(InternalDate.searchDate(since))]
            }
            return try await search(keys)
        }
    }

    /// What a folder list fetches of each message (BODYSTRUCTURE for the calendar parts it names).
    static let summaryItems =
        "(UID FLAGS INTERNALDATE RFC822.SIZE BODYSTRUCTURE BODY.PEEK[HEADER] BODY.PEEK[TEXT]<0.4096>)"

    public func summaries(uids: [UInt32]) async throws(IMAPError) -> [MessageSummary] {
        try await perform { () async throws(IMAPError) in
            var found: [UInt32: MessageSummary] = [:]
            for chunk in Self.chunks(uids, size: Self.fetchChunk) {
                let completion = try await run([
                    .word("UID FETCH"), .word(Self.set(chunk)),
                    .word(Self.summaryItems)
                ])
                let wanted = Set(chunk)
                for items in Self.fetched(completion.untagged) {
                    if let summary = items.summary(), wanted.contains(summary.uid) {
                        found[summary.uid] = summary
                    }
                }
            }
            var seen: Set<UInt32> = []
            return uids.compactMap { uid in seen.insert(uid).inserted ? found[uid] : nil }
        }
    }

    /// The whole message, without marking it read.
    public func body(uid: UInt32) async throws(IMAPError) -> Data {
        try await perform { () async throws(IMAPError) in
            let completion = try await run([.word("UID FETCH"), .word(String(uid)), .word("(UID BODY.PEEK[])")])
            guard let body = Self.fetched(completion.untagged).first(where: { $0.uid == uid })?.section("BODY[]") else {
                throw .no("The message is not on the server")
            }
            return body
        }
    }

    /// UIDs in the selected folder whose header or text contains `query`.
    public func searchText(_ query: String, since: Date?) async throws(IMAPError) -> [UInt32] {
        try await perform { () async throws(IMAPError) in
            let text = Self.stripped(query)
            guard !text.isEmpty else {
                return []
            }
            var keys: [Argument] = []
            if !text.unicodeScalars.allSatisfy(\.isASCII) {
                keys.append(.word("CHARSET UTF-8"))
            }
            if let since {
                keys += [.word("SINCE"), .word(InternalDate.searchDate(since))]
            }
            keys += [.word("TEXT"), .string(text)]
            return try await search(keys)
        }
    }

    /// Most messages a Message-ID search checks one by one: the newest that SEARCH finds.
    static let maxMessageIDHits = 50

    /// UIDs in the selected folder whose Message-ID is `messageID` (with or without its angle
    /// brackets). SEARCH HEADER matches a substring, so each hit's own header is checked too, in
    /// the same turn on the connection; of more than `maxMessageIDHits` hits only the newest count.
    public func uids(messageID: String) async throws(IMAPError) -> [UInt32] {
        let id = Self.bareID(Self.stripped(messageID))
        guard !id.isEmpty else {
            return []
        }
        return try await perform { () async throws(IMAPError) in
            var keys: [Argument] = []
            if !id.unicodeScalars.allSatisfy(\.isASCII) {
                keys.append(.word("CHARSET UTF-8"))
            }
            let hits = try await search(keys + [.word("HEADER"), .string("Message-ID"), .string(id)])
            guard !hits.isEmpty else {
                return []
            }
            let checked = Array(hits.suffix(Self.maxMessageIDHits))
            let completion = try await run([
                .word("UID FETCH"), .word(Self.set(checked)), .word("(UID BODY.PEEK[HEADER])")
            ])
            let wanted = Set(checked)
            let matching = Self.fetched(completion.untagged).compactMap { items -> UInt32? in
                guard let uid = items.uid, wanted.contains(uid), let header = items.section("BODY[HEADER]") else {
                    return nil
                }
                let own = (try? MIMEParser.parseHeaders(header))?.messageID.map(Self.bareID) ?? ""
                return own.caseInsensitiveCompare(id) == .orderedSame ? uid : nil
            }
            return Set(matching).sorted()
        }
    }

    /// A Message-ID without its angle brackets and surrounding white space.
    static func bareID(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t"))
    }

    /// Sends LOGOUT and closes the connection, after the command that has the connection now;
    /// a cancel doesn't cut that wait short (it would break the turn-taking).
    public func logout() async {
        _ = await acquire(cancellable: false)
        defer { release() }
        if !broken {
            _ = try? await execute([.word("LOGOUT")])
        }
        broken = true
        await connection.close()
    }

    /// Closes the connection at once, without LOGOUT and without waiting for a command (an
    /// IDLE on a server that stopped answering) to end; that command fails.
    public func close() async {
        await logoutWithoutCommand()
    }

    func logoutWithoutCommand() async {
        broken = true
        await connection.close()
    }

    /// Runs `body` alone on the connection; a failure that leaves the connection out of step
    /// closes it for good. A task cancelled while it waits for its turn gets `.cancelled`.
    func perform<T>(_ body: () async throws(IMAPError) -> T) async throws(IMAPError) -> T {
        guard await acquire() else {
            throw .cancelled
        }
        defer { release() }
        guard !broken else {
            throw .net(.closed)
        }
        do {
            return try await body()
        } catch {
            if Self.breaksConnection(error) {
                broken = true
                await connection.close()
            }
            throw error
        }
    }

    static func breaksConnection(_ error: IMAPError) -> Bool {
        switch error {
        case .net, .protocolViolation: true
        default: false
        }
    }
}
