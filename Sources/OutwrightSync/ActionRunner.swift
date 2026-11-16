// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightIMAP
import OutwrightMIME
import OutwrightModel
import OutwrightNet
import OutwrightSMTP
import OutwrightStore

/// Sends one account's queued changes to its server, oldest first, on a connection that is
/// signed in. An action is completed only once the server has confirmed it (or there is
/// nothing left to do, such as a move whose message has already left its folder).
///
/// Where a message is on the server is worked out for each action from what the actions
/// before it did: a move earlier in this run, else the folder and uid the action was queued
/// with, else the uid the row was given since, else its Message-ID searched for in that folder.
struct ActionRunner {
    /// Runs a change waits for its message to be found before it is given up.
    static let maxAttempts = 5

    /// Where a message went in this run.
    struct Moved {
        var folder: Folder
        var uid: UInt32?
        var header: String?
    }

    enum Location {
        case found(Folder, UInt32)
        /// It can't be told yet; ask again next time.
        case unknown
        /// There is nothing on the server to act on.
        case gone
    }

    let account: Account
    let store: MailStore
    let client: IMAPClient
    let credentials: CredentialProvider
    let now: Date
    var folders: [Folder]
    var moved: [MessageID: Moved] = [:]
    var blocked: Set<MessageID> = []
    var serverPaths: Set<String>?
    var selected: String?
    /// Folders the server has numbered anew since the store last saw them: no uid held for
    /// them means anything now.
    var renumbered: Set<FolderID> = []
    /// The first message the server refused for good in this run: done with, but the owner hears.
    var refusedSend: SyncError?
    /// A change given up in this run because its message was never found.
    var abandoned: SyncError?
    /// This runner's syncer was replaced: nothing more is done.
    var stopped = false
    /// The action just performed waits for something outside this run (a draft that can't be
    /// protected yet): it stays queued, never counted as a miss.
    var waiting = false
    /// The actions of the run under way.
    var queue: [PendingAction] = []

    /// Asked right before a message goes to SMTP: false once this runner's syncer was replaced.
    let mayContinue: @Sendable () async -> Bool
    /// The protections the build carries, by id.
    let protections: [ProtectionID: any MailProtection]

    init(
        account: Account, store: MailStore, client: IMAPClient, credentials: CredentialProvider, now: Date,
        folders: [Folder], protections: [any MailProtection] = [],
        mayContinue: @escaping @Sendable () async -> Bool = { true }
    ) {
        self.protections = Dictionary(protections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.mayContinue = mayContinue
        self.account = account
        self.store = store
        self.client = client
        self.credentials = credentials
        self.now = now
        self.folders = folders
    }

    init(
        account: Account, store: MailStore, client: IMAPClient, secrets: any SecretStore, now: Date,
        folders: [Folder], protections: [any MailProtection] = [],
        mayContinue: @escaping @Sendable () async -> Bool = { true }
    ) {
        self.init(
            account: account, store: store, client: client, credentials: CredentialProvider(secrets: secrets),
            now: now, folders: folders, protections: protections, mayContinue: mayContinue)
    }

    /// Runs `queue` in order. A broken connection is thrown at once; any other failure leaves
    /// that action, and every later one for the same message, queued, and the first such
    /// failure is returned.
    mutating func run(_ queue: [PendingAction]) async throws(SyncError) -> SyncError? {
        var refusal: SyncError?
        self.queue = queue
        for pending in queue {
            let target = pending.action.target
            guard !blocked.contains(target) else {
                continue
            }
            do {
                if try await perform(pending) {
                    try stored { try store.completeAction(pending.id) }
                } else if stopped {
                    blocked.insert(target)
                } else if waiting {
                    waiting = false
                    blocked.insert(target)
                } else {
                    try missed(pending)
                }
            } catch {
                if error.breaksConnection {
                    throw error
                }
                refusal = refusal ?? error
                blocked.insert(target)
                try forgetModSeq(pending)
            }
        }
        return refusal ?? refusedSend ?? abandoned
    }

    /// The action's message was not found on the server this time. It is done when the message is
    /// gone here too, given up (and said) after `maxAttempts` runs, else left for the next run.
    private mutating func missed(_ pending: PendingAction) throws(SyncError) {
        let target = pending.action.target
        if try stored({ try store.message(target) }) == nil {
            try stored { try store.completeAction(pending.id) }
            return
        }
        if try stored({ try store.noteMiss(pending.id) }) >= Self.maxAttempts {
            try forgetModSeq(pending)
            try stored { try store.completeAction(pending.id) }
            abandoned = abandoned ?? .actionAbandoned
            return
        }
        blocked.insert(target)
    }

    /// True when the action is done with.
    private mutating func perform(_ pending: PendingAction) async throws(SyncError) -> Bool {
        switch pending.action {
        case let .setRead(id, value):
            return try await setFlag("\\Seen", value, id, pending)
        case let .setFlagged(id, value):
            return try await setFlag("\\Flagged", value, id, pending)
        case let .move(id, kind):
            guard let destination = folder(kind) else {
                return true
            }
            return try await move(id, to: destination, pending)
        case let .moveTo(id, folderID):
            guard let destination = folders.first(where: { $0.id == folderID }) else {
                return true
            }
            return try await move(id, to: destination, pending)
        case let .delete(id):
            return try await delete(id, pending)
        case let .send(draft):
            return try await send(draft, pending)
        case let .saveDraft(draft):
            return try await saveDraft(draft, pending)
        case let .fileSent(message):
            return try await fileSent(message, pending)
        }
    }

    // MARK: - Flags, moves, deletes

    private mutating func setFlag(_ flag: String, _ value: Bool, _ id: MessageID, _ pending: PendingAction)
        async throws(SyncError) -> Bool {
        switch try await locate(id, pending) {
        case .gone:
            return true
        case .unknown:
            return false
        case let .found(folder, uid):
            try await select(folder)
            try await imap { try await client.setFlags([flag], on: [uid], add: value) }
            return true
        }
    }

    private mutating func move(_ id: MessageID, to destination: Folder, _ pending: PendingAction)
        async throws(SyncError) -> Bool {
        let header = try header(of: id)
        switch try await locate(id, pending) {
        case .gone:
            return true
        case .unknown:
            return false
        case let .found(source, uid):
            if source.id == destination.id {
                return true
            }
            try await ensureOnServer(destination)
            try await select(source)
            let flags = try await imap { try await client.flags(uids: [uid]) }
            var newUID: UInt32?
            if let current = flags[uid], !current.contains("\\Deleted") {
                newUID = try await transfer(uid, from: source, to: destination, header: header)
            } else if flags[uid] != nil {
                // Copied and marked before a drop: only the clean-up is left.
                try await removeFromServer(uid)
            }
            // Gone from the source altogether (moved by another client, or by MOVE before a drop): done.
            moved[id] = Moved(folder: destination, uid: newUID, header: header)
            // Settle only a row still waiting in that folder; a later move has it elsewhere.
            if let row = try stored({ try store.message(id) }), row.folderID == destination.id, row.uid == 0 {
                try stored { try store.settleMove(id, newUID: newUID) }
            }
            return true
        }
    }

    /// MOVE, or COPY and delete. Without MOVE a drop can come between the copy and the delete,
    /// so a copy already in the destination (by Message-ID) is not made again.
    private mutating func transfer(_ uid: UInt32, from source: Folder, to destination: Folder, header: String?)
        async throws(SyncError) -> UInt32? {
        if await !client.capabilities.contains("MOVE"), let header, !header.isEmpty,
           case let .found(_, existing) = try await search(header, in: destination) {
            try await select(source)
            try await removeFromServer(uid)
            return existing
        }
        try await select(source)
        return try await imap { try await client.move([uid], to: destination.path) }[uid]
    }

    /// To Trash, or for good when it was in Trash.
    private mutating func delete(_ id: MessageID, _ pending: PendingAction) async throws(SyncError) -> Bool {
        if pending.sourceFolderID.flatMap(folder(id:))?.kind == .trash {
            return try await deleteForGood(id, pending)
        }
        guard let trash = folder(.trash) else {
            return true
        }
        return try await move(id, to: trash, pending)
    }

    /// Deleting in Trash: marked `\Deleted` and expunged (only that uid, so only with UIDPLUS;
    /// without it the mark stays).
    private mutating func deleteForGood(_ id: MessageID, _ pending: PendingAction) async throws(SyncError) -> Bool {
        switch try await locate(id, pending) {
        case .gone:
            return true
        case .unknown:
            return false
        case let .found(folder, uid):
            try await select(folder)
            try await removeFromServer(uid)
            return true
        }
    }

    /// Where the message is on the server as of this action.
    mutating func locate(_ id: MessageID, _ pending: PendingAction) async throws(SyncError) -> Location {
        if let earlier = moved[id] {
            if let uid = earlier.uid {
                return .found(earlier.folder, uid)
            }
            return try await search(earlier.header, in: earlier.folder)
        }
        guard let folder = pending.sourceFolderID.flatMap(folder(id:)) else {
            return .gone
        }
        try await select(folder)
        if renumbered.contains(folder.id) {
            // The queued uid, and the row's, may now name another message: only the
            // Message-ID tells, and without a match the action waits, no longer tied to the number.
            if pending.sourceUID > 0 {
                try stored { try store.forgetSourceUID(of: pending.id) }
            }
            let header = try stored { try store.message(id) }?.messageIDHeader
            guard let header, !header.isEmpty else {
                return .unknown
            }
            let found = try await search(header, in: folder)
            if case .gone = found {
                return .unknown
            }
            return found
        }
        if pending.sourceUID > 0 {
            return .found(folder, pending.sourceUID)
        }
        let row = try stored { try store.message(id) }
        if let row, row.folderID == folder.id, row.uid > 0 {
            return .found(folder, row.uid)
        }
        // Queued before the server ever numbered it (a draft never saved there): what its
        // Message-ID doesn't find in that folder, the server never had.
        let found = try await search(row?.messageIDHeader, in: folder)
        if case .unknown = found {
            return .gone
        }
        return found
    }

    mutating func search(_ header: String?, in folder: Folder) async throws(SyncError) -> Location {
        guard let header, !header.isEmpty else {
            return .gone
        }
        try await select(folder)
        guard let uid = try await imap({ try await client.uids(messageID: header) }).max() else {
            return .unknown
        }
        return .found(folder, uid)
    }

    private func header(of id: MessageID) throws(SyncError) -> String? {
        try stored { try store.message(id) }?.messageIDHeader ?? moved[id]?.header
    }
}

/// The folders a runner works in, and removing from them on the server.
extension ActionRunner {
    func removeFromServer(_ uid: UInt32) async throws(SyncError) {
        try await removeFromServer([uid])
    }

    func removeFromServer(_ uids: [UInt32]) async throws(SyncError) {
        try await imap { try await client.setFlags(["\\Deleted"], on: uids, add: true) }
        do {
            try await client.expunge(uids)
        } catch {
            guard error == .extensionMissing else {
                throw .imap(error)
            }
        }
    }

    // MARK: - Folders

    func folder(_ kind: FolderKind) -> Folder? {
        folders.first { $0.kind == kind }
    }

    func folder(id: FolderID) -> Folder? {
        folders.first { $0.id == id }
    }

    mutating func select(_ folder: Folder) async throws(SyncError) {
        guard selected != folder.path else {
            return
        }
        selected = nil
        let status = try await imap { try await client.select(folder.path) }
        selected = folder.path
        if folder.uidValidity != 0, status.uidValidity != folder.uidValidity {
            renumbered.insert(folder.id)
        }
    }

    /// Makes a folder the server has not got yet (one made here for a kind the account lacked)
    /// before anything goes to it.
    mutating func ensureOnServer(_ folder: Folder) async throws(SyncError) {
        guard folder.uidValidity == 0 else {
            return
        }
        if serverPaths == nil {
            serverPaths = Set(try await imap { try await client.listFolders() }.map(\.path))
        }
        guard serverPaths?.contains(folder.path) == false else {
            return
        }
        // The path of a folder made here is ours and plain ASCII, so it is its own name. One made
        // meanwhile by another client is no failure; any other refusal leaves the change queued.
        try await imap { try await client.create(folder.path) }
        serverPaths?.insert(folder.path)
    }
}

extension ActionRunner {
    /// A flag change the server did not take leaves the row as the owner set it, while the server's
    /// mod-sequence never moved: the folder forgets its modseq so the next sync reconciles in full
    /// and puts the server's flags back.
    func forgetModSeq(_ pending: PendingAction) throws(SyncError) {
        switch pending.action {
        case let .setRead(id, _), let .setFlagged(id, _):
            try stored { try store.forgetHighestModSeq(holding: id) }
        default:
            break
        }
    }
}
