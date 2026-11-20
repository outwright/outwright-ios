// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// CREATE, RENAME, DELETE, SUBSCRIBE, UNSUBSCRIBE and STATUS, with refusals on demand.
extension FakeIMAPServer {
    /// The next `command` (RENAME, DELETE, CREATE, SUBSCRIBE, UNSUBSCRIBE) on `path` answers NO,
    /// with `code` as its response code when given (`UNAVAILABLE`).
    /// `times`: how many such commands in a row are refused.
    public func refuse(_ command: String, path: String, code: String? = nil, times: Int = 1) {
        refusals[command.uppercased() + " " + Self.key(path)] = (code.map { "[\($0)] " } ?? "", max(times, 1))
    }

    /// CREATE also makes the folders above the new one that are missing, as RFC 3501 §6.3.3 says a
    /// server SHOULD.
    public func makeSuperiorFolders() {
        makesSuperiors = true
    }

    /// RENAME and DELETE of a folder a session has selected answer `NO [INUSE]` (RFC 5530).
    public func refuseFoldersInUse() {
        refusesInUse = true
    }

    /// True when a session has `path` selected and the server refuses folders in use.
    func inUse(_ path: String) -> Bool {
        refusesInUse && sessions.values.contains { $0.selected == path }
    }

    /// Every folder the server has, by path.
    public func folderPaths() -> Set<String> {
        Set(folderOrder)
    }

    public func subscribedPaths() -> Set<String> {
        subscribed
    }

    /// CREATE, RENAME, DELETE, SUBSCRIBE, UNSUBSCRIBE or STATUS answered; false for any other command.
    func handleFolderEdit(_ id: Int, _ verb: String, _ tag: String, _ arguments: [Token]) -> Bool {
        switch verb {
        case "CREATE": create(id, tag, arguments)
        case "RENAME": rename(id, tag, arguments)
        case "DELETE": deleteFolder(id, tag, arguments)
        case "SUBSCRIBE", "UNSUBSCRIBE": subscription(id, tag, verb, arguments)
        case "STATUS": status(id, tag, arguments)
        case "LSUB":
            if let code = refusing("LSUB", "") {
                reply(id, "\(tag) NO \(code)Refused")
                return true
            }
            // RFC 3501: a subscribed name is listed whether or not the folder still exists.
            for path in subscribed.sorted() {
                reply(id, "* LSUB () \"\(delimiter)\" \(Self.quoted(path))")
            }
            reply(id, "\(tag) OK LSUB completed")
        default: return false
        }
        return true
    }

    /// The refusal's response code (`""` for none) once, when the next such command on `path` is
    /// to be refused; nil otherwise.
    func refusing(_ command: String, _ path: String) -> String? {
        let key = command + " " + path
        guard let (code, left) = refusals[key] else { return nil }
        refusals[key] = left > 1 ? (code, left - 1) : nil
        return code
    }

    private func subtree(_ path: String) -> [String] {
        folderOrder.filter { $0 == path || $0.hasPrefix(path + delimiter) }
    }

    func rename(_ id: Int, _ tag: String, _ arguments: [Token]) {
        guard arguments.count == 2, let from = arguments[0].text.map(Self.key),
              let to = arguments[1].text.map(Self.key), !to.isEmpty
        else {
            reply(id, "\(tag) BAD RENAME needs two mailboxes")
            return
        }
        if let code = refusing("RENAME", from) {
            reply(id, "\(tag) NO \(code)Refused")
            return
        }
        guard folders[from] != nil else {
            reply(id, "\(tag) NO [NONEXISTENT] No such mailbox")
            return
        }
        guard !inUse(from) else {
            reply(id, "\(tag) NO [INUSE] Mailbox in use")
            return
        }
        guard folders[to] == nil else {
            reply(id, "\(tag) NO [ALREADYEXISTS] Mailbox exists")
            return
        }
        for old in subtree(from) {
            let new = to + String(old.dropFirst(from.count))
            folders[new] = folders.removeValue(forKey: old)
            folderOrder = folderOrder.map { $0 == old ? new : $0 }
            // RFC 3501: RENAME leaves subscriptions where they were.
        }
        reply(id, "\(tag) OK RENAME completed")
    }

    /// As Dovecot: a folder with subfolders is refused (`[HASCHILDREN]`, RFC 5530).
    func deleteFolder(_ id: Int, _ tag: String, _ arguments: [Token]) {
        guard let path = arguments.first?.text.map(Self.key) else {
            reply(id, "\(tag) BAD DELETE needs a mailbox")
            return
        }
        if let code = refusing("DELETE", path) {
            reply(id, "\(tag) NO \(code)Refused")
            return
        }
        guard folders[path] != nil else {
            reply(id, "\(tag) NO [NONEXISTENT] No such mailbox")
            return
        }
        guard !inUse(path) else {
            reply(id, "\(tag) NO [INUSE] Mailbox in use")
            return
        }
        guard subtree(path).count == 1 else {
            reply(id, "\(tag) NO [HASCHILDREN] Mailbox has children")
            return
        }
        folders[path] = nil
        folderOrder.removeAll { $0 == path }
        reply(id, "\(tag) OK DELETE completed")
    }

    func subscription(_ id: Int, _ tag: String, _ verb: String, _ arguments: [Token]) {
        guard let path = arguments.first?.text.map(Self.key) else {
            reply(id, "\(tag) BAD \(verb) needs a mailbox")
            return
        }
        if let code = refusing(verb, path) {
            reply(id, "\(tag) NO \(code)Refused")
            return
        }
        if verb == "SUBSCRIBE" {
            subscribed.insert(path)
        } else {
            subscribed.remove(path)
        }
        reply(id, "\(tag) OK \(verb) completed")
    }

    func status(_ id: Int, _ tag: String, _ arguments: [Token]) {
        guard let path = arguments.first?.text.map(Self.key), let folder = folders[path] else {
            reply(id, "\(tag) NO [NONEXISTENT] No such mailbox")
            return
        }
        reply(id, "* STATUS \(Self.quoted(path)) (MESSAGES \(folder.messages.count))")
        reply(id, "\(tag) OK STATUS completed")
    }
}
