// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

public enum Threading {
    /// The first known id among `references` and `inReplyTo`. Failing that: a reply (it names ids, none
    /// known) joins the thread of its normalised subject; anything else starts a thread named by its own
    /// Message-ID, or, with none, by an id derived from account, folder path and uid. A protected
    /// message never joins by subject: its outer subject is the same for all of them.
    public static func threadID( // swiftlint:disable:this function_parameter_count
        messageID: String?, inReplyTo: [String], references: [String], subject: String,
        accountID: AccountID, folderPath: String, uid: UInt32, isProtected: Bool = false,
        existing: (String) -> ThreadID?
    ) -> ThreadID {
        let named = references.prefix(256) + inReplyTo.prefix(16)
        for id in named {
            if let known = existing(id) { return known }
        }
        if !named.isEmpty, !isProtected {
            let normal = normalisedSubject(subject)
            if !normal.isEmpty { return ThreadID(raw: "subject:" + normal) }
        }
        if let own = messageID, !own.isEmpty { return ThreadID(raw: own) }
        return ThreadID(raw: "local:\(accountID.raw.uuidString)/\(folderPath)/\(uid)")
    }

    static let prefixes = ["re:", "sv:", "fw:", "fwd:", "vb:"]

    static func normalisedSubject(_ subject: String) -> String {
        var text = Substring(subject.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        for _ in 0..<32 {
            guard let prefix = prefixes.first(where: { text.hasPrefix($0) }) else { break }
            text = text.dropFirst(prefix.count)
            text = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return String(text)
    }
}
