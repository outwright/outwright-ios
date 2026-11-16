// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// The SASL XOAUTH2 initial response IMAP and SMTP send for an OAuth access token:
/// base64 of `user=<address>^Aauth=Bearer <token>^A^A`.
public enum XOAuth2 {
    /// Nil when the token is empty or has a control character (CR, LF, NUL, ^A...): it would
    /// break the framing, and is refused before anything is sent. Control characters are taken
    /// out of the user.
    public static func initialResponse(user: String, accessToken: Secret) -> String? {
        let token = accessToken.reveal()
        guard !token.isEmpty, !token.unicodeScalars.contains(where: isControl) else {
            return nil
        }
        let name = String(String.UnicodeScalarView(user.unicodeScalars.filter { !isControl($0) }))
        return Data("user=\(name)\u{1}auth=Bearer \(token)\u{1}\u{1}".utf8).base64EncodedString()
    }

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || scalar.value == 0x7F
    }
}
