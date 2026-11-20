// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
public import OutwrightNet

/// Signing in with an OAuth access token: `AUTHENTICATE XOAUTH2` (RFC 3501 section 6.2.2,
/// SASL-IR by RFC 4959).
extension IMAPClient {
    /// With SASL-IR the initial response goes on the command line, else after the server's `+`.
    /// A refused token comes back as a `+` with an error challenge; it is answered with an
    /// empty line, the server ends the command, and this throws `.authenticationFailed`.
    public func authenticate(user: String, accessToken: Secret) async throws(IMAPError) {
        try await perform { () async throws(IMAPError) in
            guard let response = XOAuth2.initialResponse(user: user, accessToken: accessToken) else {
                throw .authenticationFailed
            }
            guard capabilities.contains("AUTH=XOAUTH2") else {
                throw .extensionMissing
            }
            let initial = capabilities.contains("SASL-IR")
            let tag = nextTag()
            var collected = Collected()
            try await write(Data("\(tag) AUTHENTICATE XOAUTH2\(initial ? " " + response : "")\r\n".utf8))
            var completion = try await responses(until: tag, continuation: true, into: &collected)
            if completion == nil, !initial {
                try await write(Data((response + "\r\n").utf8))
                completion = try await responses(until: tag, continuation: true, into: &collected)
            }
            if completion == nil {
                // The error challenge: an empty response asks the server to end with NO.
                try await write(Data("\r\n".utf8))
                completion = try await responses(until: tag, continuation: false, into: &collected)
            }
            // The server's words after an AUTHENTICATE may repeat what it was sent; never pass them on.
            guard let completion, completion.kind == .ok else {
                throw .authenticationFailed
            }
            try await refreshCapabilities(from: completion.code)
            try await enableResync()
        }
    }
}
