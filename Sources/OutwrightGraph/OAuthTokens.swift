// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
public import OutwrightNet

/// What a token request gave. The access token lives in memory only; the refresh token
/// goes to the keychain.
public struct OAuthTokens: Sendable {
    public var accessToken: Secret
    public var refreshToken: Secret?
    public var expiresAt: Date
    public var identity: OAuthIdentity?

    public init(accessToken: Secret, refreshToken: Secret?, expiresAt: Date, identity: OAuthIdentity?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.identity = identity
    }
}

/// Who signed in, from the id token's claims (`preferred_username` or `email`, `name`, `tid`).
/// The id token is read, not verified: it came straight from the token endpoint over TLS and
/// only names the account; it grants nothing.
public struct OAuthIdentity: Sendable, Equatable {
    public var address: String
    public var name: String
    public var tenant: String?

    public init(address: String, name: String, tenant: String?) {
        self.address = address
        self.name = name
        self.tenant = tenant
    }
}

/// Reading token endpoint answers (RFC 6749 sections 5.1 and 5.2) and id tokens.
extension OAuthClient {
    static let maxAnswer = 64 * 1024
    static let maxIDTokenPayload = 16 * 1024
    /// Lifetimes outside this range are clamped (a year is far above the usual hour).
    static let lifetimes: ClosedRange<Int64> = 0...(365 * 24 * 3600)

    /// The tokens in an answer from the token endpoint, or the typed reason it is not one.
    static func tokens(from body: Data, status: Int, now: Date) throws(OAuthError) -> OAuthTokens {
        guard body.count <= maxAnswer else {
            throw .malformed
        }
        let answer = try? JSONDecoder().decode(Answer.self, from: body)
        guard status == 200 else {
            if (400...401).contains(status), let code = answer?.error {
                throw OAuthError.refusal(code)
            }
            throw .http(status)
        }
        guard let answer, let access = answer.accessToken, !access.isEmpty, let lifetime = answer.expiresIn,
            answer.tokenType.map({ $0.caseInsensitiveCompare("Bearer") == .orderedSame }) ?? true
        else {
            throw .malformed
        }
        var identity: OAuthIdentity?
        if let idToken = answer.idToken {
            identity = try Self.identity(fromIDToken: idToken)
        }
        let refresh = answer.refreshToken.flatMap { $0.isEmpty ? nil : Secret($0) }
        return OAuthTokens(
            accessToken: Secret(access), refreshToken: refresh,
            expiresAt: now.addingTimeInterval(TimeInterval(lifetime.seconds)), identity: identity)
    }

    /// The identity in an id token's payload; nil when it names no address. Throws when
    /// the id token is not a JWS compact serialization with a JSON payload.
    static func identity(fromIDToken token: String) throws(OAuthError) -> OAuthIdentity? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let encoded = parts.dropFirst().first,
            encoded.utf8.count <= (maxIDTokenPayload / 3 + 1) * 4,
            let payload = base64URLDecode(encoded), payload.count <= maxIDTokenPayload,
            let claims = try? JSONDecoder().decode(Claims.self, from: payload)
        else {
            throw .malformed
        }
        guard let address = clean(claims.preferredUsername ?? claims.email, limit: 320), !address.isEmpty else {
            return nil
        }
        return OAuthIdentity(
            address: address, name: clean(claims.name, limit: 256) ?? "", tenant: clean(claims.tid, limit: 64))
    }

    /// Trims, drops control characters and caps a claim; nil stays nil.
    private static func clean(_ value: String?, limit: Int) -> String? {
        guard let value else {
            return nil
        }
        let kept = value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let text = String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespaces)
        return String(text.prefix(limit))
    }

    static func base64URLDecode(_ text: Substring) -> Data? {
        var standard = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        switch standard.utf8.count % 4 {
        case 0: break
        case 2: standard += "=="
        case 3: standard += "="
        default: return nil
        }
        return Data(base64Encoded: standard)
    }

    static func base64URLEncode(_ data: some Sequence<UInt8>) -> String {
        Data(data).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private struct Answer: Decodable {
    let accessToken: String?
    let refreshToken: String?
    let tokenType: String?
    let expiresIn: Lifetime?
    let idToken: String?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case idToken = "id_token"
        case error
    }
}

/// `expires_in` as a number or a numeric string, clamped to `lifetimes`.
private struct Lifetime: Decodable {
    let seconds: Int64

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value: Double
        if let number = try? container.decode(Double.self) {
            value = number
        } else {
            guard let number = Double(try container.decode(String.self)) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "lifetime")
            }
            value = number
        }
        guard value.isFinite else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "lifetime")
        }
        let bounds = OAuthClient.lifetimes
        seconds = Int64(min(max(value, Double(bounds.lowerBound)), Double(bounds.upperBound)))
    }
}

private struct Claims: Decodable {
    let preferredUsername: String?
    let email: String?
    let name: String?
    let tid: String?

    enum CodingKeys: String, CodingKey {
        case preferredUsername = "preferred_username"
        case email, name, tid
    }
}
