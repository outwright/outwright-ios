// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation

/// Which messages a folder's sync asks for.
extension IMAPClient {
    /// UIDs not marked deleted that arrived on or after `since` (nil: any day), above `above` when
    /// given (what came into the folder after the highest held).
    public func uids(since: Date?, above: UInt32? = nil) async throws(IMAPError) -> [UInt32] {
        var keys: [Argument] = []
        if let above {
            let (first, overflow) = above.addingReportingOverflow(1)
            guard !overflow else { return [] }
            keys += [.word("UID"), .word("\(first):*")]
        }
        if let since {
            keys += [.word("SINCE"), .word(InternalDate.searchDate(since))]
        }
        keys.append(.word("UNDELETED"))
        let asked = keys
        let found = try await perform { () async throws(IMAPError) in try await search(asked) }
        // `n:*` names the highest uid even below n (RFC 3501 §6.4.8): it is left out.
        return above.map { floor in found.filter { $0 > floor } } ?? found
    }
}
