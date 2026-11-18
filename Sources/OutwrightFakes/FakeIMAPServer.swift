// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
import OutwrightMIME

/// An in-process IMAP server on 127.0.0.1 for tests: plain transport, one account
/// (`jk@example.org`, password `secret`), folders by their wire names (modified UTF-7).
/// It speaks IMAP4rev1 with IDLE, UIDPLUS, SPECIAL-USE and, unless told not to, MOVE and UNSELECT;
/// XOAUTH2 (and SASL-IR) once given a token with `acceptToken`.
/// STARTTLS can be advertised but is always refused: the fake has no certificate.
public actor FakeIMAPServer {
    public static let user = "jk@example.org"
    public static let password = "secret"

    struct Stored {
        var uid: UInt32
        var flags: Set<String>
        var data: Data
        var internalDate: Date
        var modSeq: UInt64 = 0
        /// Its whole body is never sent (a server that cannot read a broken message).
        var bodyWithheld = false
    }

    struct Folder {
        var specialUse: String?
        var uidValidity: UInt32
        var uidNext: UInt32 = 1
        var messages: [Stored] = []
        var highestModSeq: UInt64 = 1
        var expunged: [Expunged] = []
    }

    struct Session {
        let connection: FakeConnection
        var authenticated = false
        var selected: String?
        var idleTag: String?
        /// An AUTHENTICATE waiting for its response (`awaitingAck`: after the error challenge).
        var saslTag: String?
        var saslAwaitingAck = false
        var commandsLeft: Int?
        var enabled: Set<String> = []
    }

    enum Outcome {
        case keepOpen, close
    }

    let offersStartTLS: Bool
    let offersMove: Bool
    let offersUIDPlus: Bool
    var idleWaiters: [CheckedContinuation<Void, Never>] = []
    var listener: FakeListener?
    var folderOrder: [String] = ["INBOX"]
    var folders: [String: Folder] = ["INBOX": Folder(uidValidity: 1)]
    var sessions: [Int: Session] = [:]
    var nextSession = 0
    var startTimes: [ContinuousClock.Instant] = []
    var refusalTimes: [ContinuousClock.Instant] = []
    var pendingDrop: Int?
    var silent = false
    var unlisted: Set<String> = []
    var delimiter = "/"
    var underInbox = false
    var announcesNamespace = false
    var appendDrop: (path: String, afterStoring: Bool)?
    var appendRefusal: String?
    var fetchDelay: Duration = .zero
    var loginDelay: Duration = .zero
    var heldSelects: Set<String> = []
    var omitsUIDNext = false
    var refusesStores = false
    var refusesQResyncSelect = false
    var resyncBeforeClosed = false
    var offersUnselect = true
    var resyncOffer = ResyncOffer.qresync
    var modSeqWithheld: Set<String> = []
    var served: [String] = []
    public internal(set) var loginAttempts = 0
    /// Dovecot's limits, once `keepDovecotLimits` is called.
    var dovecotLimits: DovecotLimits?
    /// The most connections signed in at once since the start.
    public internal(set) var peakSignedIn = 0
    /// The sign-ins Dovecot's connection limit refused.
    public internal(set) var limitRefusals = 0
    /// The access token accepted for each address over XOAUTH2; none: XOAUTH2 not offered.
    var oauthTokens: [String: String] = [:]
    var offersSASLIR = true
    var offersMetadata = false
    var refusesMetadataWrites = false
    var metadataFailure: String?
    /// What the server names itself with over ID (RFC 2971); nil: ID not offered.
    var identity: [String: String]?
    /// How many ID commands came, offered or not.
    public internal(set) var idRequests = 0
    /// The server entries of METADATA (RFC 5464), by entry name.
    public internal(set) var serverMetadata: [String: String] = [:]
    var appendHandlers: [@Sendable (String, Data) async -> Void] = []
    public internal(set) var tokenAttempts: [FakeTokenAttempt] = []

    public init(offersStartTLS: Bool = false, offersMove: Bool = true, offersUIDPlus: Bool = true) {
        self.offersStartTLS = offersStartTLS
        self.offersMove = offersMove
        self.offersUIDPlus = offersUIDPlus
    }

    // MARK: - Test controls

    public func start() async throws -> UInt16 {
        let listener = FakeListener { [weak self] connection in
            await self?.serve(connection)
        }
        self.listener = listener
        return try await listener.start()
    }

    public func stop() {
        listener?.stop()
        for session in sessions.values {
            session.connection.close()
        }
        sessions = [:]
        let waiters = idleWaiters
        idleWaiters = []
        waiters.forEach { $0.resume() }
    }

    // MARK: - Serving

    func serve(_ connection: FakeConnection) async {
        let id = nextSession
        nextSession += 1
        startTimes.append(.now)
        sessions[id] = Session(connection: connection, commandsLeft: pendingDrop)
        pendingDrop = nil
        connection.send(Self.line("* OK [CAPABILITY \(greetingCapabilities)] Fake IMAP ready"))
        var longest = 0
        while let command = await Self.readCommand(connection, longest: &longest) {
            if sessions[id]?.commandsLeft == 0 {
                break
            }
            if let limit = dovecotLimits?.lineBytes, longest > limit {
                longest = 0
                let tag = Self.command(command)?.tag ?? "*"
                reply(id, "\(tag) BAD Error in IMAP command received by server: Too long argument.")
                continue
            }
            longest = 0
            sessions[id]?.commandsLeft? -= 1
            if sessions[id]?.idleTag == nil {
                record(command)
            }
            await slowAnswer(command)
            if handle(id, command) == .close {
                break
            }
        }
        connection.close()
        sessions[id] = nil
    }

    struct Command {
        var tag: String
        var verb: String
        var arguments: [Token]
        var byUID: Bool
    }

    func handle(_ id: Int, _ bytes: [UInt8]) -> Outcome {
        guard let session = sessions[id] else {
            return .close
        }
        guard !silent else {
            return .keepOpen
        }
        if session.saslTag != nil {
            continueAuthentication(id, fakeText(bytes))
            return .keepOpen
        }
        if let idleTag = session.idleTag {
            sessions[id]?.idleTag = nil
            let done = fakeText(bytes).uppercased() == "DONE"
            reply(id, done ? "\(idleTag) OK IDLE terminated" : "\(idleTag) BAD Expected DONE")
            return .keepOpen
        }
        guard let command = Self.command(bytes) else {
            reply(id, "* BAD Unreadable command")
            return .keepOpen
        }
        if let outcome = handleSession(id, command) {
            return outcome
        }
        guard session.authenticated else {
            reply(id, "\(command.tag) BAD Sign in first")
            return .keepOpen
        }
        handleMailbox(id, command)
        return .keepOpen
    }

    private static func command(_ bytes: [UInt8]) -> Command? {
        guard let tokens = Token.parse(bytes), case let .atom(tag)? = tokens.first,
              case let .atom(name)? = tokens.dropFirst().first
        else {
            return nil
        }
        var command = Command(tag: tag, verb: name.uppercased(), arguments: Array(tokens.dropFirst(2)), byUID: false)
        if command.verb == "UID", case let .atom(sub)? = command.arguments.first {
            command.verb = sub.uppercased()
            command.byUID = true
            command.arguments.removeFirst()
        }
        return command
    }

    /// Commands allowed before signing in; nil for any other.
    private func handleSession(_ id: Int, _ command: Command) -> Outcome? {
        let tag = command.tag
        switch command.verb {
        case "CAPABILITY":
            let signedIn = sessions[id]?.authenticated == true
            reply(id, "* CAPABILITY \(signedIn ? capabilityList : greetingCapabilities)")
            reply(id, "\(tag) OK CAPABILITY completed")
        case "NOOP":
            reply(id, "\(tag) OK NOOP completed")
        case "LOGOUT":
            reply(id, "* BYE Fake IMAP logging out")
            reply(id, "\(tag) OK LOGOUT completed")
            return .close
        case "STARTTLS":
            reply(id, offersStartTLS ? "\(tag) NO The fake has no certificate" : "\(tag) BAD STARTTLS not offered")
        case "LOGIN":
            return login(id, tag, command.arguments)
        case "AUTHENTICATE":
            authenticate(id, tag, command.arguments)
        case "ID":
            answerID(id, tag)
        default:
            return nil
        }
        return .keepOpen
    }

    private func handleMailbox(_ id: Int, _ command: Command) {
        let (tag, arguments) = (command.tag, command.arguments)
        switch command.verb {
        case "LIST": list(id, tag)
        case "SELECT", "EXAMINE": answerSelect(id, tag, arguments)
        case "UNSELECT": unselect(id, tag)
        case "CREATE": create(id, tag, arguments)
        case "APPEND": append(id, tag, arguments)
        case "ENABLE": enable(id, tag, arguments)
        case "GETMETADATA" where offersMetadata: getMetadata(id, tag, arguments)
        case "SETMETADATA" where offersMetadata: setMetadata(id, tag, arguments)
        case "IDLE":
            sessions[id]?.idleTag = tag
            reply(id, "+ idling")
            let waiters = idleWaiters
            idleWaiters = []
            waiters.forEach { $0.resume() }
        default:
            handleMessages(id, command)
        }
    }

    private func handleMessages(_ id: Int, _ command: Command) {
        let (tag, arguments, byUID) = (command.tag, command.arguments, command.byUID)
        switch command.verb {
        case "SEARCH": search(id, tag, arguments, byUID: byUID)
        case "FETCH": fetch(id, tag, arguments, byUID: byUID)
        case "STORE" where refusesStores: reply(id, "\(tag) NO Flags cannot be changed")
        case "STORE": storeFlags(id, tag, arguments, byUID: byUID)
        case "COPY": copy(id, tag, arguments, byUID: byUID, move: false)
        case "MOVE" where offersMove: copy(id, tag, arguments, byUID: byUID, move: true)
        case "EXPUNGE": expunge(id, tag, arguments, byUID: byUID)
        case "NAMESPACE" where announcesNamespace:
            reply(id, "* NAMESPACE ((\"INBOX.\" \".\")) NIL NIL")
            reply(id, "\(tag) OK NAMESPACE completed")
        default: reply(id, "\(tag) BAD Unknown command")
        }
    }
}

/// Bytes as text, invalid UTF-8 replaced.
func fakeText(_ bytes: some Collection<UInt8>) -> String {
    // swiftlint:disable:next optional_data_string_conversion
    String(decoding: bytes, as: UTF8.self)
}

/// Ways the fake can be made to answer like other servers.
extension FakeIMAPServer {
    /// The next connection is closed when it sends the command after `afterCommands` of them.
    public func dropNextConnection(afterCommands: Int) {
        pendingDrop = afterCommands
    }

    /// The next APPEND to `path` closes its connection instead of answering: before the message is
    /// stored, or (`afterStoring`) once it is, so the client never hears that it was.
    public func dropAtAppend(to path: String, afterStoring: Bool) {
        appendDrop = (Self.key(path), afterStoring)
    }

    /// Folders live under the Inbox, as `INBOX.Sent` (a Courier-style server): LIST names `.` as
    /// the delimiter, CREATE refuses a folder anywhere else, and NAMESPACE (RFC 2342) says so
    /// unless `announcingNamespace` is false.
    public func keepFoldersUnderInbox(announcingNamespace: Bool = true) {
        delimiter = "."
        underInbox = true
        announcesNamespace = announcingNamespace
    }

    /// The next APPEND to `path` is answered NO (a full mailbox), the connection kept.
    public func refuseNextAppend(to path: String) {
        appendRefusal = Self.key(path)
    }
}
