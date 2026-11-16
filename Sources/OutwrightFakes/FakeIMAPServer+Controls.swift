// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
import OutwrightMIME

/// What a test sets up and reads back.
extension FakeIMAPServer {
    public func addFolder(_ path: String, specialUse: String?) {
        let key = Self.key(path)
        guard folders[key] == nil else {
            folders[key]?.specialUse = specialUse
            return
        }
        folderOrder.append(key)
        folders[key] = Folder(specialUse: specialUse, uidValidity: UInt32(folderOrder.count))
    }

    /// Stores a message and returns its UID. Its internal date is its Date header, else now.
    /// Sessions idling in the folder are told at once.
    @discardableResult
    public func deliver(_ message: Data, to path: String, flags: Set<String> = []) -> UInt32 {
        let key = Self.key(path)
        if folders[key] == nil {
            addFolder(key, specialUse: nil)
        }
        let date = (try? MIMEParser.parseHeaders(message).date) ?? Date()
        guard let uid = store(message, flags: flags, date: date, in: key) else {
            return 0
        }
        let count = folders[key]?.messages.count ?? 0
        for session in sessions.values where session.idleTag != nil && session.selected == key {
            session.connection.send(Self.line("* \(count) EXISTS"))
        }
        return uid
    }

    // swiftlint:disable:next large_tuple
    public func messages(in path: String) -> [(uid: UInt32, flags: Set<String>, data: Data)] {
        (folders[Self.key(path)]?.messages ?? []).map { ($0.uid, $0.flags, $0.data) }
    }

    public func setUIDValidity(_ value: UInt32, for path: String) {
        folders[Self.key(path)]?.uidValidity = value
    }

    var capabilityList: String {
        var list = ["IMAP4rev1", "IDLE", "SPECIAL-USE", "LITERAL+"] + resyncCapabilities
        if offersUIDPlus {
            list.append("UIDPLUS")
        }
        if offersMove {
            list.append("MOVE")
        }
        if offersUnselect {
            list.append("UNSELECT")
        }
        if offersMetadata {
            list.append("METADATA")
        }
        if identity != nil {
            list.append("ID")
        }
        if offersStartTLS {
            list.append("STARTTLS")
        }
        if announcesNamespace {
            list.append("NAMESPACE")
        }
        if !oauthTokens.isEmpty {
            list.append("AUTH=XOAUTH2")
            if offersSASLIR {
                list.append("SASL-IR")
            }
        }
        return list.joined(separator: " ")
    }

    /// Numbers the folder's messages anew from 1, under a new UIDVALIDITY, as a server does
    /// when it rebuilds a folder.
    public func renumber(_ path: String, uidValidity: UInt32) {
        let key = Self.key(path)
        guard var folder = folders[key] else {
            return
        }
        for index in folder.messages.indices {
            folder.messages[index].uid = UInt32(index + 1)
        }
        folder.uidNext = UInt32(folder.messages.count + 1)
        folder.uidValidity = uidValidity
        folders[key] = folder
    }

    /// Every FETCH waits this long before it is answered (a slow server, or a large folder).
    public func delayFetches(_ delay: Duration) {
        fetchDelay = delay
    }

    /// LIST leaves the folder out (a server that answers LIST wrongly); it still works otherwise.
    public func leaveOutOfList(_ path: String) {
        unlisted.insert(Self.key(path))
    }

    /// From now on commands are read and never answered (a server that hangs).
    public func stopAnswering() {
        silent = true
    }

    /// How many sessions are idling now.
    public var idlingSessions: Int {
        sessions.values.filter { $0.idleTag != nil }.count
    }

    /// Returns once a session is idling: a test's signal to deliver.
    public func waitUntilIdling() async {
        guard !sessions.values.contains(where: { $0.idleTag != nil }) else {
            return
        }
        await withCheckedContinuation { idleWaiters.append($0) }
    }
}
