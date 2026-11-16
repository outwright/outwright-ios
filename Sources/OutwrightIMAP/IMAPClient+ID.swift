// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/// The server's identity (IMAP ID, RFC 2971).
extension IMAPClient {
    /// The fields the server names itself with (`name`, `version`, …); empty when it does not
    /// offer ID or names nothing. Sends `ID NIL`: the app tells the server nothing about itself.
    public func serverID() async throws(IMAPError) -> [String: String] {
        guard capabilities.contains("ID") else {
            return [:]
        }
        return try await perform { () async throws(IMAPError) in
            let completion = try await run([.word("ID"), .word("NIL")])
            return IMAPParser.idFields(from: completion.untagged)
        }
    }
}

extension IMAPParser {
    /// The fields of an `ID` response with a text value; `ID NIL`, NIL values and anything else
    /// are left out. Field names are lowercased (RFC 2971 field names are case-insensitive).
    static func idFields(from responses: [IMAPResponse]) -> [String: String] {
        var fields: [String: String] = [:]
        for case let .data(nil, keyword, values) in responses where keyword.uppercased() == "ID" {
            guard values.count == 1, case let .list(pairs) = values[0] else {
                continue
            }
            var index = 0
            while index + 1 < pairs.count, fields.count < 30 {
                if let name = pairs[index].text, let value = pairs[index + 1].text {
                    fields[name.lowercased()] = value
                }
                index += 2
            }
        }
        return fields
    }
}
