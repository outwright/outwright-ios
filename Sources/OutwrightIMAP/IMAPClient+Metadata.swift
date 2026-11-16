// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/// Server entries of IMAP METADATA (RFC 5464): the annotations of the mailbox `""`.
extension IMAPClient {
    /// Whether the server takes server entries: `METADATA` (server and mailbox entries) or
    /// `METADATA-SERVER` (server entries only).
    public var offersServerMetadata: Bool {
        capabilities.contains("METADATA") || capabilities.contains("METADATA-SERVER")
    }

    /// The named server entries the server has; one without a value is left out.
    public func serverMetadata(_ entries: [String]) async throws(IMAPError) -> [String: String] {
        guard !entries.isEmpty else {
            return [:]
        }
        return try await perform { () async throws(IMAPError) in
            try requireMetadata()
            let names = try entries.map { (name: String) throws(IMAPError) -> String in try Self.metadataText(name) }
                .joined(separator: " ")
            let completion = try await run([.word("GETMETADATA"), .string(""), .word("(" + names + ")")])
            return IMAPParser.metadataEntries(from: completion.untagged)
        }
    }

    /// Every server entry under `prefix`, at any depth.
    public func metadataEntries(under prefix: String) async throws(IMAPError) -> [String: String] {
        try await perform { () async throws(IMAPError) in
            try requireMetadata()
            let completion = try await run([
                .word("GETMETADATA"), .word("(DEPTH infinity)"), .string(""), .string(prefix)
            ])
            return IMAPParser.metadataEntries(from: completion.untagged)
        }
    }

    /// Sets server entries; a nil value removes the entry. Names and values are 7-bit text
    /// (all this app writes); anything else is refused before it is sent.
    public func setServerMetadata(_ entries: [String: String?]) async throws(IMAPError) {
        guard !entries.isEmpty else {
            return
        }
        try await perform { () async throws(IMAPError) in
            try requireMetadata()
            var list: [String] = []
            for (name, value) in entries.sorted(by: { $0.key < $1.key }) {
                list.append(try Self.metadataText(name))
                if let value {
                    list.append(try Self.metadataText(value))
                } else {
                    list.append("NIL")
                }
            }
            _ = try await run([.word("SETMETADATA"), .string(""), .word("(" + list.joined(separator: " ") + ")")])
        }
    }

    private func requireMetadata() throws(IMAPError) {
        guard offersServerMetadata else {
            throw .extensionMissing
        }
    }

    /// A quoted 7-bit string for a METADATA list.
    static func metadataText(_ text: String) throws(IMAPError) -> String {
        let clean = stripped(text)
        guard clean.unicodeScalars.allSatisfy(\.isASCII) else {
            throw .no("METADATA text must be 7-bit")
        }
        return quoted(clean)
    }
}

extension IMAPParser {
    /// The server entries (mailbox `""`) of `METADATA` responses with a text value; NIL, lists and
    /// other mailboxes' entries are left out.
    static func metadataEntries(from responses: [IMAPResponse]) -> [String: String] {
        var entries: [String: String] = [:]
        for case let .data(nil, keyword, values) in responses where keyword.uppercased() == "METADATA" {
            guard values.count == 2, values[0].text == "", case let .list(pairs) = values[1] else {
                continue
            }
            var index = 0
            while index + 1 < pairs.count {
                if let name = pairs[index].text, let value = pairs[index + 1].text {
                    entries[name] = value
                }
                index += 2
            }
        }
        return entries
    }
}
