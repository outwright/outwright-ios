// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightMIME

/// The commands that work on folders and messages.
extension FakeIMAPServer {
    /// With Dovecot's limits, a sign-in past `connections` for the user is refused with a BYE and
    /// the connection closed, as `mail_max_userip_connections` does.
    func login(_ id: Int, _ tag: String, _ arguments: [Token]) -> Outcome {
        loginAttempts += 1
        guard arguments.count == 2, arguments[0].text == Self.user, arguments[1].text == Self.password else {
            refusalTimes.append(.now)
            reply(id, "\(tag) NO [AUTHENTICATIONFAILED] Invalid credentials")
            return .keepOpen
        }
        guard signIn(id) else { return .close }
        reply(id, "\(tag) OK [CAPABILITY \(capabilityList)] Logged in")
        return .keepOpen
    }

    func list(_ id: Int, _ tag: String) {
        for path in folderOrder where !unlisted.contains(path) {
            var attributes = ["\\HasNoChildren"]
            if let special = folders[path]?.specialUse {
                attributes.append(special)
            }
            reply(id, "* LIST (\(attributes.joined(separator: " "))) \"\(delimiter)\" \(Self.quoted(path))")
        }
        reply(id, "\(tag) OK LIST completed")
    }

    func select(_ id: Int, _ tag: String, _ arguments: [Token], resync: Bool = true) {
        guard let path = arguments.first?.text.map(Self.key), let folder = folders[path] else {
            sessions[id]?.selected = nil
            reply(id, "\(tag) NO [NONEXISTENT] No such mailbox")
            return
        }
        sessions[id]?.selected = path
        reply(id, "* \(folder.messages.count) EXISTS")
        reply(id, "* 0 RECENT")
        reply(id, "* FLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft)")
        reply(id, "* OK [UIDVALIDITY \(folder.uidValidity)] UIDs valid")
        reply(id, "* OK [UIDNEXT \(folder.uidNext)] Predicted next UID")
        selectModSeq(id, path, folder, arguments, resync: resync)
        reply(id, "\(tag) OK [READ-WRITE] SELECT completed")
    }

    func create(_ id: Int, _ tag: String, _ arguments: [Token]) {
        guard let path = arguments.first?.text.map(Self.key), !path.isEmpty else {
            reply(id, "\(tag) BAD Missing mailbox")
            return
        }
        guard folders[path] == nil else {
            reply(id, "\(tag) NO [ALREADYEXISTS] Mailbox exists")
            return
        }
        guard !underInbox || path.uppercased().hasPrefix("INBOX.") else {
            reply(id, "\(tag) NO Mailboxes live under INBOX")
            return
        }
        addFolder(path, specialUse: nil)
        reply(id, "\(tag) OK CREATE completed")
    }

    func append(_ id: Int, _ tag: String, _ arguments: [Token]) {
        guard let path = arguments.first?.text.map(Self.key), case let .string(data)? = arguments.last else {
            reply(id, "\(tag) BAD APPEND needs a mailbox and a message")
            return
        }
        guard folders[path] != nil else {
            reply(id, "\(tag) NO [TRYCREATE] No such mailbox")
            return
        }
        var flags: Set<String> = []
        if arguments.count > 2, case let .list(values) = arguments[1] {
            flags = Set(values.compactMap(\.text))
        }
        let date = (try? MIMEParser.parseHeaders(data).date) ?? Date()
        if appendRefusal == path {
            appendRefusal = nil
            reply(id, "\(tag) NO [OVERQUOTA] Mailbox is full")
            return
        }
        if let drop = appendDrop, drop.path == path {
            appendDrop = nil
            if drop.afterStoring {
                _ = store(data, flags: flags, date: date, in: path)
            }
            sessions[id]?.connection.close()
            return
        }
        let uid = store(data, flags: flags, date: date, in: path) ?? 0
        let appendUID = offersUIDPlus ? "[APPENDUID \(folders[path]?.uidValidity ?? 0) \(uid)] " : ""
        let handlers = appendHandlers
        guard !handlers.isEmpty else {
            reply(id, "\(tag) OK \(appendUID)APPEND completed")
            return
        }
        // As a server's push script does: the hooks run before the APPEND is answered.
        Task {
            for handler in handlers {
                await handler(path, data)
            }
            reply(id, "\(tag) OK \(appendUID)APPEND completed")
        }
    }

    /// What a SEARCH asks for (the keys the tests use; anything else matches everything).
    struct SearchCriteria {
        var since: Date?
        var before: Date?
        var texts: [String] = []
        var headers: [(String, String)] = []

        func matches(_ message: Stored, head: [String], content: String) -> Bool {
            if let since, message.internalDate < since { return false }
            if let before, message.internalDate >= before { return false }
            let headerHit = headers.allSatisfy { name, wanted in
                head.contains { $0.hasPrefix(name + ":") && $0.dropFirst(name.count + 1).contains(wanted) }
            }
            return headerHit && texts.allSatisfy { content.contains($0) }
        }
    }

    static func searchCriteria(_ arguments: [Token]) -> SearchCriteria {
        var criteria = SearchCriteria()
        var index = 0
        while index < arguments.count {
            let key = arguments[index].text?.uppercased() ?? ""
            let value = index + 1 < arguments.count ? arguments[index + 1].text : nil
            switch key {
            case "CHARSET":
                index += 2
            case "SINCE":
                criteria.since = value.flatMap(Self.day)
                index += 2
            case "BEFORE":
                criteria.before = value.flatMap(Self.day)
                index += 2
            case "HEADER":
                let wanted = index + 2 < arguments.count ? arguments[index + 2].text : nil
                criteria.headers.append(((value ?? "").lowercased(), (wanted ?? "").lowercased()))
                index += 3
            case "FROM", "TO", "CC":
                criteria.headers.append((key.lowercased(), (value ?? "").lowercased()))
                index += 2
            case "TEXT", "BODY", "SUBJECT":
                criteria.texts.append(value?.lowercased() ?? "")
                index += 2
            default:
                index += 1
            }
        }
        return criteria
    }

    func search(_ id: Int, _ tag: String, _ arguments: [Token], byUID: Bool) {
        guard let path = sessions[id]?.selected, let folder = folders[path] else {
            reply(id, "\(tag) BAD No mailbox selected")
            return
        }
        let criteria = Self.searchCriteria(arguments)
        var hits: [UInt32] = []
        for (position, message) in folder.messages.enumerated() {
            let content = fakeText(message.data).lowercased()
            let head = fakeText(Self.split(message.data).0).lowercased().components(separatedBy: "\r\n")
            if criteria.matches(message, head: head, content: content) {
                hits.append(byUID ? message.uid : UInt32(position + 1))
            }
        }
        reply(id, (["* SEARCH"] + hits.map(String.init)).joined(separator: " "))
        reply(id, "\(tag) OK SEARCH completed")
    }

    func fetch(_ id: Int, _ tag: String, _ arguments: [Token], byUID: Bool) {
        guard let path = sessions[id]?.selected, let folder = folders[path], arguments.count >= 2,
              let set = arguments[0].text
        else {
            reply(id, "\(tag) BAD FETCH needs a set and items")
            return
        }
        let items: [String] = if case let .list(values) = arguments[1] {
            values.compactMap(\.text).map { $0.uppercased() }
        } else {
            [arguments[1].text?.uppercased() ?? ""]
        }
        let since = Self.changedSince(arguments)
        let withModSeq = since != nil || items.contains("MODSEQ")
        for (position, message) in Self.matching(set, in: folder, byUID: byUID)
            where since.map({ message.modSeq > $0 }) ?? true {
            var out = Data("* \(position) FETCH (".utf8)
            var parts: [Data] = []
            if byUID || items.contains("UID") {
                parts.append(Data("UID \(message.uid)".utf8))
            }
            parts += items.compactMap { Self.item($0, of: message) }
            if withModSeq {
                parts.append(Data("MODSEQ (\(message.modSeq))".utf8))
            }
            for (index, part) in parts.enumerated() {
                if index > 0 {
                    out.append(UInt8(ascii: " "))
                }
                out.append(part)
            }
            out.append(contentsOf: Array(")\r\n".utf8))
            sessions[id]?.connection.send(out)
        }
        reply(id, "\(tag) OK FETCH completed")
    }

    func storeFlags(_ id: Int, _ tag: String, _ arguments: [Token], byUID: Bool) {
        guard let path = sessions[id]?.selected, let folder = folders[path], arguments.count >= 3,
              let set = arguments[0].text, let mode = arguments[1].text?.uppercased(),
              case let .list(values) = arguments[2]
        else {
            reply(id, "\(tag) BAD STORE needs a set, a mode and flags")
            return
        }
        let flags = Set(values.compactMap(\.text))
        let targets = Set(Self.matching(set, in: folder, byUID: byUID).map(\.1.uid))
        for index in folder.messages.indices where targets.contains(folder.messages[index].uid) {
            var current = folder.messages[index].flags
            if mode.hasPrefix("+") {
                current.formUnion(flags)
            } else if mode.hasPrefix("-") {
                current.subtract(flags)
            } else {
                current = flags
            }
            if current != folder.messages[index].flags {
                folders[path]?.messages[index].flags = current
                let modSeq = nextModSeq(path)
                folders[path]?.messages[index].modSeq = modSeq
            }
            if !mode.hasSuffix(".SILENT") {
                let flagList = current.sorted().joined(separator: " ")
                let modSeq = sessions[id]?.enabled.contains("CONDSTORE") == true
                    ? " MODSEQ (\(folders[path]?.messages[index].modSeq ?? 0))" : ""
                reply(id, "* \(index + 1) FETCH (UID \(folder.messages[index].uid) FLAGS (\(flagList))\(modSeq))")
            }
        }
        reply(id, "\(tag) OK STORE completed")
    }

    func copy(_ id: Int, _ tag: String, _ arguments: [Token], byUID: Bool, move: Bool) {
        guard let path = sessions[id]?.selected, let folder = folders[path], arguments.count >= 2,
              let set = arguments[0].text, let destination = arguments[1].text.map(Self.key)
        else {
            reply(id, "\(tag) BAD needs a set and a mailbox")
            return
        }
        guard folders[destination] != nil else {
            reply(id, "\(tag) NO [TRYCREATE] No such mailbox")
            return
        }
        let chosen = Self.matching(set, in: folder, byUID: byUID)
        var created: [UInt32] = []
        for (_, message) in chosen {
            var flags = message.flags
            flags.remove("\\Deleted")
            created.append(store(message.data, flags: flags, date: message.internalDate, in: destination) ?? 0)
        }
        let validity = folders[destination]?.uidValidity ?? 0
        let sources = chosen.map { String($0.1.uid) }.joined(separator: ",")
        let copyUID = offersUIDPlus && !chosen.isEmpty
            ? "[COPYUID \(validity) \(sources) \(created.map(String.init).joined(separator: ","))] "
            : ""
        if move {
            if !copyUID.isEmpty {
                reply(id, "* OK \(copyUID)Moved")
            }
            let moved = Set(chosen.map(\.1.uid))
            removeMessages(id, path: path) { moved.contains($0.uid) }
            reply(id, "\(tag) OK MOVE completed")
        } else {
            reply(id, "\(tag) OK \(copyUID)COPY completed")
        }
    }

    func expunge(_ id: Int, _ tag: String, _ arguments: [Token], byUID: Bool) {
        guard offersUIDPlus || !byUID else {
            reply(id, "\(tag) BAD UID EXPUNGE needs UIDPLUS")
            return
        }
        guard let path = sessions[id]?.selected, let folder = folders[path] else {
            reply(id, "\(tag) BAD No mailbox selected")
            return
        }
        let limit: Set<UInt32>? = byUID ? arguments.first?.text.map { set in
            Set(Self.matching(set, in: folder, byUID: true).map(\.1.uid))
        } : nil
        removeMessages(id, path: path) { message in
            message.flags.contains("\\Deleted") && (limit?.contains(message.uid) ?? true)
        }
        reply(id, "\(tag) OK EXPUNGE completed")
    }

    private static func item(_ item: String, of message: Stored) -> Data? {
        switch item {
        case "FLAGS":
            Data("FLAGS (\(message.flags.sorted().joined(separator: " ")))".utf8)
        case "INTERNALDATE":
            Data("INTERNALDATE \"\(Self.internalDate(message.internalDate))\"".utf8)
        case "RFC822.SIZE":
            Data("RFC822.SIZE \(message.data.count)".utf8)
        case "BODY.PEEK[HEADER]", "BODY[HEADER]":
            Self.literal("BODY[HEADER]", Self.split(message.data).0)
        case "BODY.PEEK[TEXT]<0.4096>", "BODY[TEXT]<0.4096>":
            Self.literal("BODY[TEXT]<0>", Self.split(message.data).1.prefix(4096))
        case "BODY.PEEK[]", "BODY[]":
            Self.literal("BODY[]", message.data)
        default:
            nil
        }
    }

    func store(_ data: Data, flags: Set<String>, date: Date, in path: String) -> UInt32? {
        guard var folder = folders[path] else {
            return nil
        }
        let uid = folder.uidNext
        folder.uidNext += 1
        folder.highestModSeq &+= 1
        folder.messages.append(
            Stored(uid: uid, flags: flags, data: data, internalDate: date, modSeq: folder.highestModSeq))
        folders[path] = folder
        return uid
    }

    func removeMessages(_ id: Int, path: String, where shouldRemove: (Stored) -> Bool) {
        guard let messages = folders[path]?.messages else {
            return
        }
        for index in messages.indices.reversed() where shouldRemove(messages[index]) {
            let uid = messages[index].uid
            folders[path]?.messages.remove(at: index)
            let modSeq = nextModSeq(path)
            folders[path]?.expunged.append(Expunged(uid: uid, modSeq: modSeq))
            if let count = folders[path]?.expunged.count, count > Self.expungedKept {
                folders[path]?.expunged.removeFirst(count - Self.expungedKept)
            }
            if let session = sessions[id] {
                reply(id, expungeNotice(session, uid: uid, position: index + 1))
            }
            for (other, session) in sessions where other != id && session.idleTag != nil && session.selected == path {
                session.connection.send(Self.line(expungeNotice(session, uid: uid, position: index + 1)))
            }
        }
    }

    func reply(_ id: Int, _ text: String) {
        sessions[id]?.connection.send(Self.line(text))
    }
}
