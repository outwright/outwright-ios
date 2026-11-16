// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/// The server's identity (IMAP ID, RFC 2971), off unless a test gives one.
extension FakeIMAPServer {
    /// Offers ID and answers it with these fields.
    public func identify(as fields: [String: String]) {
        identity = fields
    }

    /// `ID (client fields)` or `ID NIL`: answered with the server's fields.
    func answerID(_ id: Int, _ tag: String) {
        idRequests += 1
        guard let identity else {
            reply(id, "\(tag) BAD ID not offered")
            return
        }
        let pairs = identity.sorted { $0.key < $1.key }.map { "\(Self.quoted($0.key)) \(Self.quoted($0.value))" }
        reply(id, "* ID (\(pairs.joined(separator: " ")))")
        reply(id, "\(tag) OK ID completed")
    }
}
