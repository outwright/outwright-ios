// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation

/// What a SEARCH asks for: each criterion given must hold.
public struct IMAPSearch: Sendable, Equatable {
    public var text: String?
    public var from: String?
    public var to: String?
    public var cc: String?
    public var before: Date?

    public init(text: String? = nil, from: String? = nil, to: String? = nil, cc: String? = nil, before: Date? = nil) {
        self.text = text
        self.from = from
        self.to = to
        self.cc = cc
        self.before = before
    }
}

extension IMAPClient {
    /// UIDs in the selected folder matching every criterion given (header and text contain, sent
    /// before the day of `before`); none given asks nothing and finds nothing.
    public func search(_ criteria: IMAPSearch) async throws(IMAPError) -> [UInt32] {
        try await perform { () async throws(IMAPError) in
            var keys: [Argument] = []
            var values: [String] = []
            let given = [("FROM", criteria.from), ("TO", criteria.to), ("CC", criteria.cc), ("TEXT", criteria.text)]
            for (key, value) in given {
                guard let value else { continue }
                let clean = Self.stripped(value)
                guard !clean.isEmpty else { continue }
                keys += [.word(key), .string(clean)]
                values.append(clean)
            }
            if let before = criteria.before {
                keys += [.word("BEFORE"), .word(InternalDate.searchDate(before))]
            }
            guard !keys.isEmpty else {
                return []
            }
            if !values.allSatisfy({ $0.unicodeScalars.allSatisfy(\.isASCII) }) {
                keys.insert(.word("CHARSET UTF-8"), at: 0)
            }
            return try await search(keys)
        }
    }
}
