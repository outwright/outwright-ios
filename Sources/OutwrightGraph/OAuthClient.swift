// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import CryptoKit
public import Foundation
public import OutwrightNet

/// One sign-in in progress: the URL the sign-in sheet opens, and the `state` and PKCE
/// verifier to check and redeem its answer with. Neither leaves memory.
public struct OAuthRequest: Sendable {
    public let url: URL
    public let state: String
    public let verifier: String
}

/// Printing, `String(reflecting:)` and `dump` show nothing of the request: its URL carries the
/// state, and the verifier is the secret half of the exchange.
extension OAuthRequest: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "OAuthRequest(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

/// The service an access token is for. Some providers issue a token for one resource at a
/// time; the same refresh token is redeemed for each.
public enum OAuthResource: Sendable, Hashable {
    /// IMAP and SMTP (XOAUTH2); the sign-in's own token.
    case mail
    /// Graph: contacts and calendars.
    case graph
}

/// A provider's OAuth registration and endpoints: where to sign in, where the answer comes back,
/// and what to ask for. The provider supplies it; nothing here names one.
public struct OAuthConfiguration: Sendable {
    /// The authorization server's base; `authorize` and `token` are under it.
    public let authority: URL
    /// The registered redirect URI the answer comes back to.
    public let redirectURI: String
    /// What the sign-in asks the owner to allow.
    public let authorizeScopes: String
    /// What to redeem a refresh token with, per resource.
    public let scopes: @Sendable (OAuthResource) -> String
    /// Extra query items for the authorize URL (such as a prompt).
    public let authorizeExtras: [URLQueryItem]

    public init(
        authority: URL, redirectURI: String, authorizeScopes: String,
        scopes: @escaping @Sendable (OAuthResource) -> String, authorizeExtras: [URLQueryItem] = []
    ) {
        self.authority = authority
        self.redirectURI = redirectURI
        self.authorizeScopes = authorizeScopes
        self.scopes = scopes
        self.authorizeExtras = authorizeExtras
    }

    /// The scheme of the redirect URI, lowercased: what the sign-in sheet waits for.
    public var callbackScheme: String {
        (URLComponents(string: redirectURI)?.scheme ?? "").lowercased()
    }
}

/// Sign-in as a public native client: the authorization code flow with PKCE S256 (RFC 6749,
/// 7636, 8252), no client secret. Tokens come back as `Secret`s; nothing here stores or logs
/// them.
public struct OAuthClient: Sendable {
    public let clientID: String
    public let configuration: OAuthConfiguration
    private let session: URLSession

    public init(clientID: String, configuration: OAuthConfiguration, session: URLSession = HTTPSession.shared) {
        self.clientID = clientID
        self.configuration = configuration
        self.session = session
    }

    private var authority: URL { configuration.authority }

    /// A fresh state and verifier, and the authorize URL that carries them; `loginHint`, the
    /// address the owner already gave, is filled in on the sign-in page.
    public func start(loginHint: String? = nil) -> OAuthRequest {
        let state = Self.base64URLEncode(Self.randomBytes(32))
        let verifier = Self.base64URLEncode(Self.randomBytes(32))
        let challenge = Self.base64URLEncode(SHA256.hash(data: Data(verifier.utf8)))
        let url = authority.appending(path: "authorize").appending(queryItems: [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURI),
            URLQueryItem(name: "response_mode", value: "query"),
            URLQueryItem(name: "scope", value: configuration.authorizeScopes),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ] + configuration.authorizeExtras + Self.hint(loginHint))
        return OAuthRequest(url: url, state: state, verifier: verifier)
    }

    private static func hint(_ address: String?) -> [URLQueryItem] {
        let address = address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return address.isEmpty ? [] : [URLQueryItem(name: "login_hint", value: address)]
    }

    /// The authorization code in the sign-in sheet's callback, once its `state` is ours.
    public func code(from callback: URL, expecting state: String) throws(OAuthError) -> String {
        guard callback.scheme?.lowercased() == configuration.callbackScheme,
            let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems
        else {
            throw .malformed
        }
        let value = { (name: String) in items.first { $0.name == name }?.value }
        guard let returned = value("state"), !state.isEmpty, returned == state else {
            throw .wrongState
        }
        if let error = value("error") {
            throw OAuthError.refusal(error)
        }
        guard let code = value("code"), !code.isEmpty, code.utf8.count <= Self.maxCode else {
            throw .malformed
        }
        return code
    }

    /// Redeems an authorization code (RFC 6749 section 4.1.3, RFC 7636 section 4.5).
    public func redeem(code: String, verifier: String) async throws(OAuthError) -> OAuthTokens {
        try await token([
            ("client_id", clientID),
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", configuration.redirectURI),
            ("code_verifier", verifier),
            ("scope", configuration.scopes(.mail))
        ])
    }

    /// New tokens for a refresh token (RFC 6749 section 6), for one `resource`. A provider may
    /// rotate the refresh token; store the one that comes back. `invalidGrant` means sign in
    /// again.
    public func refresh(
        _ refreshToken: Secret, for resource: OAuthResource = .mail
    ) async throws(OAuthError) -> OAuthTokens {
        try await token([
            ("client_id", clientID),
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken.reveal()),
            ("scope", configuration.scopes(resource))
        ])
    }

    // MARK: - The token endpoint

    static let maxCode = 8 * 1024
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private func token(_ form: [(String, String)]) async throws(OAuthError) -> OAuthTokens {
        let endpoint = authority.appending(path: "token")
        guard Self.isSecure(endpoint) else {
            throw .transport
        }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(Self.formEncode(form).utf8)
        let (status, body) = try await fetch(request)
        return try Self.tokens(from: body, status: status, now: Date())
    }

    /// https, or plain http to loopback (the tests' fake).
    private static func isSecure(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https": url.host?.isEmpty == false
        case "http": Loopback.hosts.contains(url.host?.lowercased() ?? "")
        default: false
        }
    }

    private static func formEncode(_ form: [(String, String)]) -> String {
        form.map { name, value in
            let encoded = value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
            return name + "=" + encoded
        }.joined(separator: "&")
    }

    /// The status and at most `maxAnswer` bytes of body; redirects are not followed.
    private func fetch(_ request: URLRequest) async throws(OAuthError) -> (Int, Data) {
        switch await CappedFetch.run(request, session: session, limit: Self.maxAnswer) {
        case let .success(answer): return answer
        case .failure(.tooLarge), .failure(.notHTTP): throw .malformed
        case .failure(.transport): throw .transport
        }
    }

    private static func randomBytes(_ count: Int) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    }
}
