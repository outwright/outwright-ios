// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// One XOAUTH2 sign-in a fake IMAP or SMTP server received.
public struct FakeTokenAttempt: Sendable, Equatable {
    public var user: String
    public var accepted: Bool
    /// The initial response came with the command (SASL-IR), not after a continuation.
    public var initialResponse: Bool
}

enum FakeXOAuth2 {
    /// The base64 JSON error challenge Microsoft-style servers send for a refused token.
    static let errorChallenge = Data(
        #"{"status":"401","schemes":"Bearer","scope":"https://outlook.office.com/"}"#.utf8
    ).base64EncodedString()

    /// The user and token in a base64 XOAUTH2 initial response, or nil when it is not one.
    static func decode(_ base64: String) -> (user: String, token: String)? {
        guard let data = Data(base64Encoded: base64.trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        let fields = fakeText(data).split(separator: "\u{1}", omittingEmptySubsequences: false)
        guard fields.count == 4, fields[2].isEmpty, fields[3].isEmpty, fields[0].hasPrefix("user="),
            fields[1].hasPrefix("auth=Bearer ")
        else {
            return nil
        }
        return (String(fields[0].dropFirst(5)), String(fields[1].dropFirst(12)))
    }
}
