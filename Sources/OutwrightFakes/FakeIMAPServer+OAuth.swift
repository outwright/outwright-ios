// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/// `AUTHENTICATE XOAUTH2`, with or without SASL-IR, as Microsoft's servers answer it.
extension FakeIMAPServer {
    /// Accepts this access token for the address over XOAUTH2 (replacing any earlier one) and
    /// offers `AUTH=XOAUTH2` from now on.
    public func acceptToken(_ token: String, for address: String = FakeIMAPServer.user) {
        oauthTokens[address] = token
    }

    /// Whether `SASL-IR` is offered beside `AUTH=XOAUTH2` (it is unless told otherwise).
    public func offerSASLIR(_ offered: Bool) {
        offersSASLIR = offered
    }

    func authenticate(_ id: Int, _ tag: String, _ arguments: [Token]) {
        guard arguments.first?.text?.uppercased() == "XOAUTH2", !oauthTokens.isEmpty else {
            reply(id, "\(tag) NO [CANNOT] Unsupported mechanism")
            return
        }
        sessions[id]?.saslTag = tag
        sessions[id]?.saslAwaitingAck = false
        if let initial = arguments.dropFirst().first?.text {
            guard offersSASLIR else {
                sessions[id]?.saslTag = nil
                reply(id, "\(tag) BAD SASL-IR not offered")
                return
            }
            check(id, initial, initialResponse: true)
        } else {
            reply(id, "+ ")
        }
    }

    /// A line sent while an AUTHENTICATE is under way.
    func continueAuthentication(_ id: Int, _ text: String) {
        guard let tag = sessions[id]?.saslTag else {
            return
        }
        if sessions[id]?.saslAwaitingAck == true || text == "*" {
            sessions[id]?.saslTag = nil
            reply(id, "\(tag) NO [AUTHENTICATIONFAILED] AUTHENTICATE failed")
            return
        }
        check(id, text, initialResponse: false)
    }

    private func check(_ id: Int, _ response: String, initialResponse: Bool) {
        guard let tag = sessions[id]?.saslTag else {
            return
        }
        let decoded = FakeXOAuth2.decode(response)
        let accepted = decoded.map { oauthTokens[$0.user] == $0.token } ?? false
        tokenAttempts.append(
            FakeTokenAttempt(user: decoded?.user ?? "", accepted: accepted, initialResponse: initialResponse))
        guard accepted else {
            sessions[id]?.saslAwaitingAck = true
            reply(id, "+ \(FakeXOAuth2.errorChallenge)")
            return
        }
        sessions[id]?.saslTag = nil
        guard signIn(id) else {
            sessions[id]?.connection.close()
            return
        }
        reply(id, "\(tag) OK [CAPABILITY \(capabilityList)] AUTHENTICATE completed")
    }
}
