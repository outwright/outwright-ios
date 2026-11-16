// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/// What a push needs: the mail that came after a known UID.
extension IMAPClient {
    /// UIDs in the selected folder above `uid`, ascending. `UID n:*` always matches the
    /// folder's last message, even one below `n`, so the answer is filtered.
    public func uids(above uid: UInt32) async throws(IMAPError) -> [UInt32] {
        let (first, overflow) = uid.addingReportingOverflow(1)
        guard !overflow else {
            return []
        }
        return try await perform { () async throws(IMAPError) in
            try await search([.word("UID"), .word("\(first):*")]).filter { $0 > uid }
        }
    }

    /// The highest UID in the selected folder; nil when it is empty. For a SELECT that left
    /// UIDNEXT out (RFC 3501 allows it).
    public func highestUID() async throws(IMAPError) -> UInt32? {
        try await perform { () async throws(IMAPError) in
            try await search([.word("UID"), .word("*")]).max()
        }
    }

    /// UIDs in the selected folder marked `\Deleted` whose subject contains `subject`.
    public func uids(deletedWithSubject subject: String) async throws(IMAPError) -> [UInt32] {
        try await perform { () async throws(IMAPError) in
            try await search([.word("DELETED"), .word("SUBJECT"), .string(subject)])
        }
    }
}
