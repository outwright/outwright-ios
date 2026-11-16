// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation

/// Flags, moving, appending and expunging.
extension IMAPClient {
    public func setFlags(_ flags: Set<String>, on uids: [UInt32], add: Bool) async throws(IMAPError) {
        try await perform { () async throws(IMAPError) in
            let valid = flags.filter(Self.isFlag).sorted()
            guard !valid.isEmpty else {
                return
            }
            for chunk in Self.chunks(uids, size: Self.storeChunk) {
                _ = try await run([
                    .word("UID STORE"), .word(Self.set(chunk)), .word(add ? "+FLAGS.SILENT" : "-FLAGS.SILENT"),
                    .word("(" + valid.joined(separator: " ") + ")")
                ])
            }
        }
    }

    /// The flags of messages in the selected folder, by UID; a UID the server has no more is absent.
    public func flags(uids: [UInt32]) async throws(IMAPError) -> [UInt32: Set<String>] {
        try await perform { () async throws(IMAPError) in
            var found: [UInt32: Set<String>] = [:]
            for chunk in Self.chunks(uids, size: Self.storeChunk) {
                let completion = try await run([.word("UID FETCH"), .word(Self.set(chunk)), .word("(UID FLAGS)")])
                let wanted = Set(chunk)
                for items in Self.fetched(completion.untagged) {
                    if let uid = items.uid, wanted.contains(uid), let flags = items.flags {
                        found[uid] = flags
                    }
                }
            }
            return found
        }
    }

    /// Moves messages with MOVE when the server offers it, else with COPY, `\Deleted` and
    /// `UID EXPUNGE` (only with UIDPLUS: a plain EXPUNGE could remove other messages, so without
    /// it the originals are left marked `\Deleted`). Returns the new UID of each moved message
    /// as COPYUID tells it; empty when the server does not.
    public func move(_ uids: [UInt32], to path: String) async throws(IMAPError) -> [UInt32: UInt32] {
        try await perform { () async throws(IMAPError) in
            var moved: [UInt32: UInt32] = [:]
            for chunk in Self.chunks(uids, size: Self.storeChunk) {
                let set = Self.set(chunk)
                if capabilities.contains("MOVE") {
                    let completion = try await execute([.word("UID MOVE"), .word(set), .mailbox(path)])
                    try Self.check(completion, folder: path)
                    moved.merge(Self.copiedUIDs(completion)) { _, new in new }
                    continue
                }
                let completion = try await execute([.word("UID COPY"), .word(set), .mailbox(path)])
                try Self.check(completion, folder: path)
                moved.merge(Self.copiedUIDs(completion)) { _, new in new }
                _ = try await run([.word("UID STORE"), .word(set), .word("+FLAGS.SILENT (\\Deleted)")])
                if capabilities.contains("UIDPLUS") {
                    _ = try await run([.word("UID EXPUNGE"), .word(set)])
                }
            }
            return moved
        }
    }

    /// Stores a message in a folder; its UID when the server says (APPENDUID).
    public func append(_ message: Data, to path: String, flags: Set<String>) async throws(IMAPError) -> UInt32? {
        try await perform { () async throws(IMAPError) in
            guard message.count <= IMAPParser.maxLiteral else {
                throw .no("The message is larger than 64 MiB")
            }
            var arguments: [Argument] = [.word("APPEND"), .mailbox(path)]
            let valid = flags.filter(Self.isFlag).sorted()
            if !valid.isEmpty {
                arguments.append(.word("(" + valid.joined(separator: " ") + ")"))
            }
            arguments.append(.literal(message))
            let completion = try await execute(arguments)
            try Self.check(completion, folder: path)
            let parts = completion.code?.split(separator: " ") ?? []
            guard parts.count == 3, parts[0].uppercased() == "APPENDUID", parts[2].utf8.count <= 10 else {
                return nil
            }
            return UInt32(parts[2])
        }
    }

    /// Removes the named messages of the selected folder that are marked `\Deleted`, and no
    /// others. Needs UIDPLUS.
    public func expunge(_ uids: [UInt32]) async throws(IMAPError) {
        try await perform { () async throws(IMAPError) in
            guard capabilities.contains("UIDPLUS") else {
                throw .extensionMissing
            }
            for chunk in Self.chunks(uids, size: Self.storeChunk) {
                _ = try await run([.word("UID EXPUNGE"), .word(Self.set(chunk))])
            }
        }
    }

    /// Old UID to new from the COPYUID codes of a COPY or MOVE (RFC 4315 §3).
    static func copiedUIDs(_ completion: Completion) -> [UInt32: UInt32] {
        var codes = completion.untagged.compactMap { response -> String? in
            if case let .status(nil, .ok, code?, _) = response { code } else { nil }
        }
        if let code = completion.code {
            codes.append(code)
        }
        var mapping: [UInt32: UInt32] = [:]
        for code in codes {
            let parts = code.split(separator: " ")
            guard parts.count == 4, parts[0].uppercased() == "COPYUID",
                  let sources = uidSet(parts[2]), let targets = uidSet(parts[3]), sources.count == targets.count
            else {
                continue
            }
            for (source, target) in zip(sources, targets) {
                mapping[source] = target
            }
        }
        return mapping
    }

    /// The UIDs of a set such as `4:6,9`, in order; nil when it is malformed or names more
    /// than `limit`.
    static func uidSet(_ text: Substring, limit: Int = 10_000) -> [UInt32]? {
        var out: [UInt32] = []
        for part in text.split(separator: ",") {
            let ends = part.split(separator: ":", omittingEmptySubsequences: false)
            guard (1...2).contains(ends.count), ends.allSatisfy({ $0.utf8.count <= 10 }) else {
                return nil
            }
            let numbers = ends.compactMap { UInt32($0) }
            guard numbers.count == ends.count, let first = numbers.first, let last = numbers.last else {
                return nil
            }
            let range = min(first, last)...max(first, last)
            guard Int(range.upperBound - range.lowerBound) < limit - out.count else {
                return nil
            }
            out.append(contentsOf: range)
        }
        return out
    }
}
