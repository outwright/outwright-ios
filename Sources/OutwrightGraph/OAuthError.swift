// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/// Why an OAuth sign-in or token request failed. Descriptions never carry a code, a
/// verifier, a token, a URL query or a server's own text.
public enum OAuthError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The owner closed the sign-in sheet.
    case cancelled
    /// The callback's `state` is not the one this sign-in sent.
    case wrongState
    /// The server refused; carries only the RFC 6749 error code (e.g. "access_denied"),
    /// or "other" for a code outside the known set.
    case refused(String)
    /// The refresh token or code is no longer accepted: the account needs signing in again.
    case invalidGrant
    case malformed
    case transport
    case http(Int)

    public var description: String {
        switch self {
        case .cancelled: "sign-in cancelled"
        case .wrongState: "sign-in answer does not belong to this sign-in"
        case let .refused(code): "the sign-in was refused (\(code))"
        case .invalidGrant: "sign-in has expired; sign in again"
        case .malformed: "malformed sign-in answer"
        case .transport: "sign-in unreachable"
        case let .http(status): "sign-in answered HTTP \(status)"
        }
    }

    /// The RFC 6749 (sections 4.1.2.1 and 5.2) and OpenID Connect error codes kept as they
    /// are; anything else becomes "other", so a server cannot put its own text in an error.
    static func refusal(_ code: String) -> OAuthError {
        if code == "invalid_grant" {
            return .invalidGrant
        }
        return .refused(knownCodes.contains(code) ? code : "other")
    }

    private static let knownCodes: Set<String> = [
        "invalid_request", "invalid_client", "unauthorized_client", "unsupported_grant_type",
        "invalid_scope", "access_denied", "unsupported_response_type", "server_error",
        "temporarily_unavailable", "interaction_required", "login_required", "consent_required",
        "account_selection_required", "invalid_resource", "expired_token"
    ]
}
