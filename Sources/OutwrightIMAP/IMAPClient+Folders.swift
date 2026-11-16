// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// Making folders, and where the server keeps them.
extension IMAPClient {
    /// Creates a folder from a display name, written in modified UTF-7 (`R&D` is `R&-D`). A
    /// folder that already exists (`[ALREADYEXISTS]`, RFC 5530) is no failure.
    public func create(_ name: String) async throws(IMAPError) {
        try await perform { () async throws(IMAPError) in
            let completion = try await execute([.word("CREATE"), .mailbox(ModifiedUTF7.encode(Self.stripped(name)))])
            let code = completion.code?.split(separator: " ").first?.uppercased()
            guard completion.kind == .ok || (completion.kind == .no && code == "ALREADYEXISTS") else {
                throw Self.failure(completion.kind, completion.text, code: completion.code)
            }
        }
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
