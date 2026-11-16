// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import OutwrightNet

/// How a submission signs in.
public enum SMTPCredential: Sendable {
    /// AUTH PLAIN, else AUTH LOGIN.
    case password(Secret)
    /// AUTH XOAUTH2 with an OAuth access token.
    case accessToken(Secret)
}

/// Signing in with an OAuth access token: `AUTH XOAUTH2` with its initial response (RFC 4954).
extension SMTPClient {
    /// A refused token comes back as a 334 error challenge; it is answered with an empty line
    /// and the server's final reply, whatever it is, fails as `.authenticationFailed`.
    static func authenticate(
        _ wire: Wire, features: Set<String>, user: String, accessToken: Secret
    ) async throws(SMTPError) {
        guard authMethods(features).contains("XOAUTH2") else {
            throw .xoauth2NotOffered
        }
        guard let response = XOAuth2.initialResponse(user: user, accessToken: accessToken) else {
            throw .authenticationFailed
        }
        try await wire.send("AUTH XOAUTH2 \(response)")
        let reply = try await wire.reply()
        switch reply.code {
        case 235:
            return
        case 334:
            try await wire.send("")
            _ = try await wire.reply()
            throw .authenticationFailed
        case 534, 535, 538, 454:
            throw .authenticationFailed
        default:
            // The server's words after a token may repeat it; never pass them on.
            throw .rejected(code: reply.code, text: "")
        }
    }
}
