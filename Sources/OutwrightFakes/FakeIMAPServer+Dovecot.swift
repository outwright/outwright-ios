// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/// Dovecot's limits on a client, as Debian's Dovecot 2.3 keeps them by default.
struct DovecotLimits {
    /// `mail_max_userip_connections`: the connections one user may have signed in from one address.
    var connections: Int
    /// `imap_max_line_length`: the longest command line, literals not counted.
    var lineBytes: Int
}

extension FakeIMAPServer {
    /// From now on the fake keeps Dovecot's limits: a sign-in past `connections` at once is refused
    /// with a BYE, a command line past `lineBytes` is answered BAD, and before signing in only
    /// what Dovecot offers then is said (no QRESYNC, MOVE, UIDPLUS or SPECIAL-USE): the rest comes
    /// with the sign-in.
    public func keepDovecotLimits(connections: Int = 10, lineBytes: Int = 65_536) {
        dovecotLimits = DovecotLimits(connections: connections, lineBytes: lineBytes)
    }

    /// The capabilities said in the greeting and before signing in.
    var greetingCapabilities: String {
        guard dovecotLimits != nil else { return capabilityList }
        var list = ["IMAP4rev1", "SASL-IR", "LOGIN-REFERRALS", "ID", "ENABLE", "IDLE", "LITERAL+", "AUTH=PLAIN"]
        if offersStartTLS {
            list.append("STARTTLS")
        }
        return list.joined(separator: " ")
    }

    /// Signs the connection in, unless Dovecot's connection limit refuses it: then a BYE, counted in
    /// `limitRefusals`, and false (the caller closes the connection).
    func signIn(_ id: Int) -> Bool {
        let signedIn = sessions.values.filter(\.authenticated).count
        if let limit = dovecotLimits?.connections, signedIn >= limit {
            limitRefusals += 1
            reply(id, "* BYE Maximum number of connections from user+IP exceeded "
                + "(mail_max_userip_connections=\(limit))")
            return false
        }
        sessions[id]?.authenticated = true
        peakSignedIn = max(peakSignedIn, signedIn + 1)
        return true
    }
}
