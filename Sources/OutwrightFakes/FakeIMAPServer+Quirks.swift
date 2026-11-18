// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/// Answers a real server may give that RFC 3501 allows but the usual fake does not.
extension FakeIMAPServer {
    /// Every LOGIN waits this long before it is answered (a slow sign-in).
    public func delayLogins(_ delay: Duration) {
        loginDelay = delay
    }

    /// How many connections are open now.
    public var openSessions: Int {
        sessions.count
    }

    /// When each connection served since the start came in, in order.
    public var sessionStarts: [ContinuousClock.Instant] {
        startTimes
    }

    /// When each LOGIN with the wrong password was refused, in order.
    public var loginRefusals: [ContinuousClock.Instant] {
        refusalTimes
    }

    /// From now on every STORE is answered NO (a server that will not change flags).
    public func refuseStores() {
        refusesStores = true
    }

    /// The message `uid` in `path` is never sent whole (its header and summary still are).
    public func withholdBody(of uid: UInt32, in path: String) {
        let key = Self.key(path)
        guard let index = folders[key]?.messages.firstIndex(where: { $0.uid == uid }) else { return }
        folders[key]?.messages[index].bodyWithheld = true
    }

    /// From now on SELECT leaves out `OK [UIDNEXT n]`.
    public func omitUIDNext() {
        omitsUIDNext = true
    }

    /// The wait a slow server makes before it answers `command` (see `delayFetches`, `delayLogins`).
    func slowAnswer(_ command: [UInt8]) async {
        let text = fakeText(command).uppercased()
        if fetchDelay > .zero, text.contains(" FETCH ") {
            try? await Task.sleep(for: fetchDelay)
        }
        if loginDelay > .zero, text.contains(" LOGIN ") {
            try? await Task.sleep(for: loginDelay)
        }
        while selectIsHeld(text), !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// From now on a SELECT or EXAMINE of `path` is not answered until `releaseSelects` (a folder
    /// so large its sync takes as long as a test likes).
    public func holdSelects(of path: String) {
        heldSelects.insert(path.uppercased())
    }

    /// The held SELECTs are answered, and later ones at once.
    public func releaseSelects() {
        heldSelects = []
    }

    /// Whether `text`, a command in capitals, selects a folder held by `holdSelects`.
    private func selectIsHeld(_ text: String) -> Bool {
        let words = text.split(separator: " ", maxSplits: 3).map(String.init)
        guard words.count >= 3, words[1] == "SELECT" || words[1] == "EXAMINE" else { return false }
        let path = String(words[2].filter { $0 != "\"" })
        return heldSelects.contains(path)
    }

    /// SELECT and EXAMINE, with or without UIDNEXT.
    func answerSelect(_ id: Int, _ tag: String, _ arguments: [Token]) {
        if refusesQResyncSelect, Self.asksQResync(arguments) {
            refusesQResyncSelect = false
            reply(id, "\(tag) BAD That point is not taken")
            return
        }
        var resync = true
        // RFC 7162 §3.2.11: under QRESYNC, what was said of the folder left ends with [CLOSED].
        if sessions[id]?.selected != nil, sessions[id]?.enabled.contains("QRESYNC") == true {
            if resyncBeforeClosed, let path = arguments.first?.text.map(Self.key), let folder = folders[path] {
                resyncAnswer(id, path, folder, arguments).forEach { reply(id, $0) }
                resync = false
            }
            reply(id, "* OK [CLOSED] Previous mailbox closed")
        }
        if omitsUIDNext {
            selectWithoutUIDNext(id, tag, arguments, resync: resync)
        } else {
            select(id, tag, arguments, resync: resync)
        }
    }

    /// From now on a QRESYNC SELECT made while another folder is selected says what changed in
    /// the folder it selects before `[CLOSED]`, not after it (as Stalwart v0.16 does).
    public func answerResyncBeforeClosed() {
        resyncBeforeClosed = true
    }

    /// From now on UNSELECT is neither offered nor understood.
    public func withholdUnselect() {
        offersUnselect = false
    }

    /// UNSELECT (RFC 3691): the folder is left without expunging anything.
    func unselect(_ id: Int, _ tag: String) {
        guard offersUnselect else {
            reply(id, "\(tag) BAD Unknown command")
            return
        }
        guard sessions[id]?.selected != nil else {
            reply(id, "\(tag) BAD No mailbox selected")
            return
        }
        sessions[id]?.selected = nil
        reply(id, "\(tag) OK UNSELECT completed")
    }

    private func selectWithoutUIDNext(_ id: Int, _ tag: String, _ arguments: [Token], resync: Bool) {
        guard let path = arguments.first?.text.map(Self.key), let folder = folders[path] else {
            sessions[id]?.selected = nil
            reply(id, "\(tag) NO [NONEXISTENT] No such mailbox")
            return
        }
        sessions[id]?.selected = path
        reply(id, "* \(folder.messages.count) EXISTS")
        reply(id, "* OK [UIDVALIDITY \(folder.uidValidity)] UIDs valid")
        selectModSeq(id, path, folder, arguments, resync: resync)
        reply(id, "\(tag) OK [READ-WRITE] SELECT completed")
    }
}
