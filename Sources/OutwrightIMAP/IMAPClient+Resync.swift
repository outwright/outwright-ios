// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// CONDSTORE and QRESYNC (RFC 7162): asking a folder what changed since a mod-sequence.
extension IMAPClient {
    /// How many ranges one VANISHED answer may hold, all of a command's answers together.
    static let maxVanishedRanges = 10_000

    /// What this connection enabled of RFC 7162.
    public var resyncMode: ResyncMode {
        if enabled.contains("QRESYNC") {
            .qresync
        } else if enabled.contains("CONDSTORE") {
            .condstore
        } else {
            .none
        }
    }

    /// Turns on QRESYNC, or CONDSTORE alone, when the capabilities offer it: the step after any
    /// authentication, run inside its turn. What is on is what the server's ENABLED says; a NO or
    /// BAD leaves nothing on.
    func enableResync() async throws(IMAPError) {
        enabled = []
        let wanted: String
        guard capabilities.contains("ENABLE") else {
            return
        }
        if capabilities.contains("QRESYNC") {
            wanted = "QRESYNC"
        } else if capabilities.contains("CONDSTORE") {
            wanted = "CONDSTORE"
        } else {
            return
        }
        let completion = try await execute([.word("ENABLE"), .word(wanted)])
        guard completion.kind == .ok else {
            return
        }
        for case let .data(nil, "ENABLED", values) in completion.untagged {
            enabled.formUnion(values.compactMap(\.text).map { $0.uppercased() })
        }
        if enabled.contains("QRESYNC") {
            enabled.insert("CONDSTORE")
        }
    }

    /// Selects a folder. With QRESYNC on and a point given, the server is asked what changed since
    /// it: the uids expunged and the flags changed, within the point's known uids. Otherwise a plain
    /// SELECT, and nil for the changes: none were asked for.
    public func select(_ path: String, from point: QResyncPoint?) async throws(IMAPError)
        -> (FolderStatus, ResyncChanges?) {
        try await perform { () async throws(IMAPError) in
            var arguments: [Argument] = [.word("SELECT"), .mailbox(path)]
            var asking = point.flatMap { resyncMode == .qresync ? $0 : nil }
            if asking != nil, hasSelected, try await !unselect() {
                asking = nil
            }
            if let asking {
                let known = asking.known.map { " \($0.lowerBound):\($0.upperBound)" } ?? ""
                arguments.append(.word("(QRESYNC (\(asking.uidValidity) \(asking.modSeq)\(known)))"))
            }
            // A SELECT that fails leaves no folder selected (RFC 3501 §6.3.1).
            hasSelected = false
            let completion = try await execute(arguments)
            try Self.check(completion, folder: path)
            hasSelected = true
            let untagged = Self.afterClosed(completion.untagged)
            let status = try Self.status(of: untagged)
            guard asking != nil else {
                return (status, nil)
            }
            guard let changes = Self.resyncChanges(untagged) else {
                throw .protocolViolation
            }
            return (status, changes)
        }
    }

    /// Leaves the selected folder without expunging; false when the server can't (no UNSELECT),
    /// true too when nothing is selected.
    public func leaveSelected() async throws(IMAPError) -> Bool {
        try await perform { () async throws(IMAPError) -> Bool in
            guard hasSelected else { return true }
            return try await unselect()
        }
    }

    /// Leaves the selected folder without expunging (UNSELECT, RFC 3691; part of IMAP4rev2), so
    /// the next SELECT's answer has no `[CLOSED]` to be split by: some servers (Stalwart v0.16) say
    /// what changed in the folder selected before `[CLOSED]`, where it reads as said of the one
    /// left. False when the server has no UNSELECT or refuses it, the folder still selected.
    private func unselect() async throws(IMAPError) -> Bool {
        guard capabilities.contains("UNSELECT") || capabilities.contains("IMAP4REV2") else {
            return false
        }
        guard try await execute([.word("UNSELECT")]).kind == .ok else {
            return false
        }
        hasSelected = false
        return true
    }

    /// The responses that speak of the folder just selected: under QRESYNC everything before
    /// `[CLOSED]` was about the folder left (RFC 7162 §3.2.11).
    static func afterClosed(_ untagged: [IMAPResponse]) -> [IMAPResponse] {
        let closed = untagged.lastIndex { response in
            guard case let .status(nil, .ok, code?, _) = response else {
                return false
            }
            return code.uppercased() == "CLOSED"
        }
        guard let closed else {
            return untagged
        }
        return Array(untagged[untagged.index(after: closed)...])
    }

    /// The VANISHED uids and the changed flags among `untagged`; nil when VANISHED is malformed
    /// or holds more than `maxVanishedRanges` ranges.
    static func resyncChanges(_ untagged: [IMAPResponse]) -> ResyncChanges? {
        var changes = ResyncChanges.none
        for case let .data(nil, "VANISHED", values) in untagged {
            guard let set = values.last?.text,
                  let ranges = uidRanges(Substring(set), maxRanges: maxVanishedRanges - changes.vanished.count)
            else {
                return nil
            }
            changes.vanished += ranges
        }
        for items in fetched(untagged) {
            if let uid = items.uid, let flags = items.flags {
                changes.flags[uid] = flags
            }
        }
        return changes
    }

    /// Flags of the messages in the selected folder changed since `modSeq` (CHANGEDSINCE), within
    /// `span` when one is given.
    public func changedFlags(
        since modSeq: UInt64, within span: ClosedRange<UInt32>? = nil
    ) async throws(IMAPError) -> [UInt32: Set<String>] {
        try await perform { () async throws(IMAPError) in
            let completion = try await run([
                .word("UID FETCH"), .word(span.map { "\($0.lowerBound):\($0.upperBound)" } ?? "1:*"),
                .word("(UID FLAGS)"), .word("(CHANGEDSINCE \(modSeq))")
            ])
            var found: [UInt32: Set<String>] = [:]
            for items in Self.fetched(completion.untagged) {
                if let uid = items.uid, let flags = items.flags {
                    found[uid] = flags
                }
            }
            return found
        }
    }

    /// Which of `uids` the selected folder still has, asked in sets short enough for one line.
    public func presentUIDs(_ uids: [UInt32]) async throws(IMAPError) -> Set<UInt32> {
        try await perform { () async throws(IMAPError) in
            var present: Set<UInt32> = []
            for chunk in Self.chunks(uids, size: Self.storeChunk) {
                let asked = Set(chunk)
                present.formUnion(try await search([.word("UID"), .word(Self.set(chunk))]).filter(asked.contains))
            }
            return present
        }
    }

    /// The ranges of a uid set such as `4:6,9`, unexpanded; nil when it is malformed (a zero, a
    /// `*`, an empty part) or has more than `maxRanges` parts.
    static func uidRanges(_ text: Substring, maxRanges: Int = maxVanishedRanges) -> [ClosedRange<UInt32>]? {
        var out: [ClosedRange<UInt32>] = []
        for part in text.split(separator: ",", omittingEmptySubsequences: false) {
            guard out.count < maxRanges else {
                return nil
            }
            let ends = part.split(separator: ":", omittingEmptySubsequences: false)
            guard (1...2).contains(ends.count) else {
                return nil
            }
            let numbers = ends.compactMap { number($0, digits: 10).flatMap { UInt32(exactly: $0) } }
            guard numbers.count == ends.count, let first = numbers.first, let last = numbers.last,
                  first > 0, last > 0
            else {
                return nil
            }
            out.append(min(first, last)...max(first, last))
        }
        return out
    }
}
