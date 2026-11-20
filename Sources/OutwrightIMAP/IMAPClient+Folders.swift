// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// Making folders, and where the server keeps them.
extension IMAPClient {
    /// Creates a folder from a display name, written in modified UTF-7 (`R&D` is `R&-D`). A
    /// folder that already exists (`[ALREADYEXISTS]`, RFC 5530) is no failure.
    public func create(_ name: String) async throws(IMAPError) {
        try await create(path: ModifiedUTF7.encode(Self.stripped(name)))
    }

    /// Creates a folder from its wire path, sent as it is. A folder that already exists is no failure.
    public func create(path: String) async throws(IMAPError) {
        try await perform { () async throws(IMAPError) in
            let completion = try await execute([.word("CREATE"), .mailbox(Self.stripped(path))])
            let code = completion.code?.split(separator: " ").first?.uppercased()
            guard completion.kind == .ok || (completion.kind == .no && code == "ALREADYEXISTS") else {
                throw Self.failure(completion.kind, completion.text, code: completion.code)
            }
        }
    }

    /// Renames a folder and, as RFC 3501 has it, every folder under it. Both are wire paths.
    public func rename(from path: String, to newPath: String) async throws(IMAPError) {
        try await perform { () async throws(IMAPError) in
            let completion = try await execute([
                .word("RENAME"), .mailbox(Self.stripped(path)), .mailbox(Self.stripped(newPath))
            ])
            guard completion.kind == .ok else {
                throw Self.failure(completion.kind, completion.text, code: completion.code)
            }
        }
    }

    /// Deletes a folder by its wire path. One already gone (`[NONEXISTENT]`, RFC 5530) is no failure.
    public func delete(_ path: String) async throws(IMAPError) {
        try await perform { () async throws(IMAPError) in
            let completion = try await execute([.word("DELETE"), .mailbox(Self.stripped(path))])
            let code = completion.code?.split(separator: " ").first?.uppercased()
            guard completion.kind == .ok || (completion.kind == .no && code == "NONEXISTENT") else {
                throw Self.failure(completion.kind, completion.text, code: completion.code)
            }
        }
    }

    /// Adds a folder to the server's subscriptions (RFC 3501 §6.3.6).
    public func subscribe(_ path: String) async throws(IMAPError) {
        try await subscription("SUBSCRIBE", path)
    }

    /// Takes a folder out of the server's subscriptions (RFC 3501 §6.3.7).
    public func unsubscribe(_ path: String) async throws(IMAPError) {
        try await subscription("UNSUBSCRIBE", path)
    }

    private func subscription(_ verb: String, _ path: String) async throws(IMAPError) {
        try await perform { () async throws(IMAPError) in
            let completion = try await execute([.word(verb), .mailbox(Self.stripped(path))])
            guard completion.kind == .ok else {
                throw Self.failure(completion.kind, completion.text, code: completion.code)
            }
        }
    }

    /// The wire paths of the folders the server has subscribed (LSUB, RFC 3501 §6.3.9).
    public func subscribedFolders() async throws(IMAPError) -> Set<String> {
        try await perform { () async throws(IMAPError) -> Set<String> in
            let completion = try await execute([.word("LSUB"), .string(""), .string("*")])
            guard completion.kind == .ok else {
                throw Self.failure(completion.kind, completion.text, code: completion.code)
            }
            return Set(completion.untagged.compactMap { response -> String? in
                guard case let .data(nil, keyword, values) = response, keyword.uppercased() == "LSUB" else {
                    return nil
                }
                return IMAPParser.folder(from: .data(number: nil, keyword: "LIST", values: values))?.path
            })
        }
    }

    /// How many messages a folder holds, by `STATUS (MESSAGES)` (RFC 3501 §6.3.10), without selecting it.
    public func messageCount(_ path: String) async throws(IMAPError) -> Int {
        try await perform { () async throws(IMAPError) -> Int in
            let completion = try await execute([.word("STATUS"), .mailbox(Self.stripped(path)), .word("(MESSAGES)")])
            guard completion.kind == .ok else {
                throw Self.failure(completion.kind, completion.text, code: completion.code)
            }
            return try Self.messageCount(of: completion.untagged)
        }
    }

    /// The `MESSAGES` item of the first untagged STATUS; a missing or unreadable count is `.bad`.
    static func messageCount(of untagged: [IMAPResponse]) throws(IMAPError) -> Int {
        for case let .data(_, keyword, values) in untagged where keyword.uppercased() == "STATUS" {
            guard values.count >= 2, case let .list(items) = values[1] else {
                continue
            }
            var index = items.startIndex
            while index < items.endIndex {
                let next = items.index(after: index)
                guard next < items.endIndex else { break }
                if items[index].text?.uppercased() == "MESSAGES", let text = items[next].text,
                   let value = number(Substring(text), digits: 9) {
                    return Int(value)
                }
                index = items.index(after: next)
            }
        }
        throw .bad("No message count in STATUS")
    }

    /// The prefix and delimiter of the owner's own folders (RFC 2342), asked once per connection;
    /// nil when the server does not offer NAMESPACE or names no usable personal namespace.
    public func personalNamespace() async throws(IMAPError) -> IMAPNamespace? {
        if let namespaceAnswer {
            return namespaceAnswer.value
        }
        guard capabilities.contains("NAMESPACE") else {
            return nil
        }
        let found = try await perform { () async throws(IMAPError) -> IMAPNamespace? in
            // A server that offers NAMESPACE and then refuses it has said nothing.
            let completion = try await execute([.word("NAMESPACE")])
            guard completion.kind == .ok else {
                return nil
            }
            return completion.untagged.lazy.compactMap(IMAPParser.namespace(from:)).first
        }
        namespaceAnswer = NamespaceAnswer(value: found)
        return found
    }
}
