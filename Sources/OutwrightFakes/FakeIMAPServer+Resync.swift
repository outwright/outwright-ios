// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// CONDSTORE and QRESYNC (RFC 7162): mod-sequences, ENABLE, the QRESYNC SELECT, CHANGEDSINCE and
/// VANISHED.
extension FakeIMAPServer {
    /// What the fake offers of RFC 7162.
    enum ResyncOffer {
        case qresync, condstoreOnly, none
    }

    /// An expunged message as QRESYNC reports it.
    struct Expunged {
        var uid: UInt32
        var modSeq: UInt64
    }

    /// A QRESYNC SELECT's parameter: where the client last saw the folder.
    struct ResyncPoint {
        var validity: UInt32
        var modSeq: UInt64
        var known: String?
    }

    /// How many expunged uids a folder keeps for VANISHED (EARLIER); the oldest go first.
    static let expungedKept = 10_000

    // MARK: - Test controls

    /// From now on the capabilities name CONDSTORE but not QRESYNC.
    public func offerCondstoreOnly() {
        resyncOffer = .condstoreOnly
    }

    /// From now on neither CONDSTORE nor QRESYNC is offered, and ENABLE enables nothing.
    public func offerNoCondstore() {
        resyncOffer = .none
    }

    /// SELECT of the folder answers `[NOMODSEQ]` (a folder that keeps no mod-sequences).
    public func withholdModSeq(_ path: String) {
        modSeqWithheld.insert(Self.key(path))
    }

    /// The folder's mod-sequences start over at 1, its UIDVALIDITY kept (a server restored from
    /// a backup).
    public func rewindModSeq(_ path: String) {
        let key = Self.key(path)
        guard var folder = folders[key] else {
            return
        }
        folder.highestModSeq = 1
        for index in folder.messages.indices {
            folder.messages[index].modSeq = 1
        }
        folder.expunged = []
        folders[key] = folder
    }

    /// The next SELECT carrying a QRESYNC parameter is answered BAD (a server that will not take
    /// the point it was given).
    public func refuseNextQResyncSelect() {
        refusesQResyncSelect = true
    }

    /// The folder's HIGHESTMODSEQ now.
    public func highestModSeq(_ path: String) -> UInt64 {
        folders[Self.key(path)]?.highestModSeq ?? 0
    }

    /// Every command line served since the start (or the last `forgetServedCommands`), upper-cased,
    /// a LOGIN's arguments left out.
    public var servedCommands: [String] {
        served
    }

    public func forgetServedCommands() {
        served = []
    }

    // MARK: - Serving

    var resyncCapabilities: [String] {
        switch resyncOffer {
        case .qresync: ["ENABLE", "CONDSTORE", "QRESYNC"]
        case .condstoreOnly: ["ENABLE", "CONDSTORE"]
        case .none: ["ENABLE"]
        }
    }

    func record(_ command: [UInt8]) {
        let text = fakeText(command).uppercased()
        let words = text.split(separator: " ", maxSplits: 2)
        if words.count > 1, words[1] == "LOGIN" {
            served.append("\(words[0]) LOGIN ***")
        } else {
            served.append(text)
        }
    }

    func enable(_ id: Int, _ tag: String, _ arguments: [Token]) {
        let asked = Set(arguments.compactMap(\.text).map { $0.uppercased() })
        var granted: [String] = []
        if resyncOffer != .none, asked.contains("CONDSTORE") {
            granted.append("CONDSTORE")
        }
        if resyncOffer == .qresync, asked.contains("QRESYNC") {
            granted.append("QRESYNC")
        }
        sessions[id]?.enabled.formUnion(granted)
        if granted.contains("QRESYNC") {
            sessions[id]?.enabled.insert("CONDSTORE")
        }
        reply(id, (["* ENABLED"] + granted).joined(separator: " "))
        reply(id, "\(tag) OK ENABLE completed")
    }

    /// The mod-sequence part of a SELECT: `(CONDSTORE)` enables CONDSTORE, the HIGHESTMODSEQ
    /// code once it is on, and for `(QRESYNC (uidvalidity modseq [known]))` with a matching
    /// UIDVALIDITY the expunges and changes since, unless `resync` is false (said already).
    func selectModSeq(_ id: Int, _ path: String, _ folder: Folder, _ arguments: [Token], resync: Bool = true) {
        if arguments.count > 1, case let .list(parameters) = arguments[1],
           parameters.contains(where: { $0.text?.uppercased() == "CONDSTORE" }), resyncOffer != .none {
            sessions[id]?.enabled.insert("CONDSTORE")
        }
        guard sessions[id]?.enabled.contains("CONDSTORE") == true else {
            return
        }
        guard !modSeqWithheld.contains(path) else {
            reply(id, "* OK [NOMODSEQ] No mod-sequences here")
            return
        }
        reply(id, "* OK [HIGHESTMODSEQ \(folder.highestModSeq)] Highest")
        if resync {
            resyncAnswer(id, path, folder, arguments).forEach { reply(id, $0) }
        }
    }

    /// What a QRESYNC SELECT says changed since its point: VANISHED (EARLIER) and the FETCHes of
    /// the messages changed, within the known uids. Nothing without QRESYNC on or a matching
    /// UIDVALIDITY.
    func resyncAnswer(_ id: Int, _ path: String, _ folder: Folder, _ arguments: [Token]) -> [String] {
        guard let point = Self.resyncPoint(arguments), sessions[id]?.enabled.contains("QRESYNC") == true,
              point.validity == folder.uidValidity, !modSeqWithheld.contains(path)
        else {
            return []
        }
        var lines: [String] = []
        let known = point.known.map { Self.uids(in: $0) }
        let vanished = folder.expunged.filter { $0.modSeq > point.modSeq && (known?.contains($0.uid) ?? true) }
        if !vanished.isEmpty {
            lines.append("* VANISHED (EARLIER) \(Self.setText(vanished.map(\.uid)))")
        }
        for (position, message) in folder.messages.enumerated()
            where message.modSeq > point.modSeq && (known?.contains(message.uid) ?? true) {
            let items = "UID \(message.uid) \(Self.flagsItem(message)) MODSEQ (\(message.modSeq))"
            lines.append("* \(position + 1) FETCH (\(items))")
        }
        return lines
    }

    /// The `(QRESYNC (uidvalidity modseq [known]))` of a SELECT; nil when it has none.
    static func resyncPoint(_ arguments: [Token]) -> ResyncPoint? {
        guard arguments.count > 1, case let .list(parameters) = arguments[1] else {
            return nil
        }
        for index in parameters.indices where parameters[index].text?.uppercased() == "QRESYNC" {
            guard index + 1 < parameters.count, case let .list(values) = parameters[index + 1], values.count >= 2,
                  let validity = values[0].text.flatMap({ UInt32($0) }),
                  let modSeq = values[1].text.flatMap({ UInt64($0) })
            else {
                return nil
            }
            return ResyncPoint(validity: validity, modSeq: modSeq, known: values.count > 2 ? values[2].text : nil)
        }
        return nil
    }

    /// Whether a SELECT carries a `(QRESYNC (…))` parameter.
    static func asksQResync(_ arguments: [Token]) -> Bool {
        guard arguments.count > 1, case let .list(parameters) = arguments[1] else {
            return false
        }
        return parameters.contains { $0.text?.uppercased() == "QRESYNC" }
    }

    /// A `(CHANGEDSINCE n)` after the items of a FETCH; nil when there is none.
    static func changedSince(_ arguments: [Token]) -> UInt64? {
        guard arguments.count > 2, case let .list(values) = arguments[2], values.count >= 2,
              values[0].text?.uppercased() == "CHANGEDSINCE"
        else {
            return nil
        }
        return values[1].text.flatMap { UInt64($0) }
    }

    /// Raises the folder's HIGHESTMODSEQ and returns the new value.
    func nextModSeq(_ path: String) -> UInt64 {
        let value = (folders[path]?.highestModSeq ?? 0) &+ 1
        folders[path]?.highestModSeq = value
        return value
    }

    /// An expunge as `session` hears it: VANISHED once it enabled QRESYNC, else EXPUNGE.
    func expungeNotice(_ session: Session, uid: UInt32, position: Int) -> String {
        session.enabled.contains("QRESYNC") ? "* VANISHED \(uid)" : "* \(position) EXPUNGE"
    }

    static func flagsItem(_ message: Stored) -> String {
        "FLAGS (\(message.flags.sorted().joined(separator: " ")))"
    }

    /// A uid set (`1:3,7`) as the set of uids in it; ranges past 100 000 uids are cut there.
    static func uids(in set: String) -> Set<UInt32> {
        var found: Set<UInt32> = []
        for part in set.split(separator: ",") {
            let ends = part.split(separator: ":").compactMap { UInt32($0) }
            guard let first = ends.first, let last = ends.last else {
                continue
            }
            let low = min(first, last)
            let high = min(max(first, last), low.addingReportingOverflow(100_000).partialValue)
            found.formUnion(low...high)
        }
        return found
    }

    /// Uids written as a set with ranges (`1:3,7`).
    static func setText(_ uids: [UInt32]) -> String {
        var parts: [String] = []
        var start: UInt32?
        var last: UInt32 = 0
        for uid in uids.sorted() {
            if start != nil, uid == last &+ 1 {
                last = uid
                continue
            }
            if let first = start {
                parts.append(first == last ? "\(first)" : "\(first):\(last)")
            }
            start = uid
            last = uid
        }
        if let first = start {
            parts.append(first == last ? "\(first)" : "\(first):\(last)")
        }
        return parts.joined(separator: ",")
    }
}
