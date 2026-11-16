// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import CryptoKit
public import Foundation

/// A Microsoft-style OAuth token endpoint on 127.0.0.1 for tests. Its authority is
/// `http://127.0.0.1:port/common/oauth2/v2.0/`; only `token` answers. The authorization
/// endpoint answers nothing: a test asks `issueCode(challenge:)` for the code a sign-in sheet
/// would have returned, and builds the callback URL itself.
///
/// It checks PKCE (S256), the client id and the redirect URI, refuses a client secret,
/// rotates refresh tokens and issues synthetic, unsigned id tokens.
public actor FakeOAuthServer {
    public let clientID: String
    /// The registered redirect URI the client must send and is sent back to.
    public let redirectURI: String
    public let address: String
    public let name: String
    public let tenant: String
    /// Every access token issued, oldest first.
    public private(set) var issued: [String] = []
    /// Token requests received (scripted ones included).
    public private(set) var requests = 0
    /// The `scope` of each unscripted token request, oldest first.
    public private(set) var scopes: [String] = []
    /// The lifetime given to new access tokens, in seconds.
    public var expiresIn = 3600
    private var server: FakeHTTPServer?
    private var codes: [String: String] = [:]
    private var refreshTokens: Set<String> = []
    private var revoked: Set<String> = []
    private var scripted: [FakeHTTPResponse] = []
    private var counter = 0

    public init(
        clientID: String = "test-client", redirectURI: String = "outwright-test://auth",
        address: String = "jk@example.org", name: String = "J Karlsson", tenant: String = "tenant-1"
    ) {
        self.clientID = clientID
        self.redirectURI = redirectURI
        self.address = address
        self.name = name
        self.tenant = tenant
    }

    /// Starts serving and returns the authority to give `OAuthClient`.
    public func start() async throws -> URL {
        let server = FakeHTTPServer { [weak self] request in
            await self?.handle(request) ?? FakeHTTPResponse(status: 500)
        }
        self.server = server
        let port = try await server.start()
        guard let url = URL(string: "http://127.0.0.1:\(port)/common/oauth2/v2.0/") else {
            throw FakeError.cannotListen("authority")
        }
        return url
    }

    public func stop() {
        server?.stop()
    }

    /// The code the sign-in sheet would return for a request with this `code_challenge`.
    public func issueCode(challenge: String) -> String {
        counter += 1
        let code = "code-\(counter)"
        codes[code] = challenge
        return code
    }

    /// The refresh token stops working, as when the owner revokes the app's access.
    public func revoke(_ refresh: String) {
        revoked.insert(refresh)
    }

    /// The next token requests are answered with these, in order, before normal service.
    public func script(_ responses: [FakeHTTPResponse]) {
        scripted.append(contentsOf: responses)
    }

    public func setExpiresIn(_ seconds: Int) {
        expiresIn = seconds
    }

    // MARK: - Serving

    private func handle(_ request: FakeHTTPRequest) -> FakeHTTPResponse {
        if request.method == "GET", request.path.contains("/oauth2/v2.0/authorize") {
            return authorize(request.path)
        }
        guard request.method == "POST", request.path.hasSuffix("/oauth2/v2.0/token") else {
            return FakeHTTPResponse(status: 404)
        }
        requests += 1
        if !scripted.isEmpty {
            return scripted.removeFirst()
        }
        let form = Self.form(request.body)
        scopes.append(form["scope"] ?? "")
        guard form["client_id"] == clientID, form["client_secret"] == nil else {
            return Self.error("invalid_client")
        }
        switch form["grant_type"] {
        case "authorization_code":
            guard let code = form["code"], let challenge = codes.removeValue(forKey: code),
                let verifier = form["code_verifier"], Self.challenge(verifier) == challenge,
                form["redirect_uri"] == redirectURI
            else {
                return Self.error("invalid_grant")
            }
            return issue()
        case "refresh_token":
            guard let refresh = form["refresh_token"], refreshTokens.contains(refresh), !revoked.contains(refresh)
            else {
                return Self.error("invalid_grant")
            }
            return issue()
        default:
            return Self.error("unsupported_grant_type")
        }
    }

    /// The sign-in page, for the end-to-end tests: no page, a redirect to the app at once with a
    /// code for the request's challenge and its state.
    private func authorize(_ target: String) -> FakeHTTPResponse {
        let items = URLComponents(string: target)?.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value ?? "" }
        guard value("client_id") == clientID, value("redirect_uri") == redirectURI,
            !value("code_challenge").isEmpty
        else {
            return FakeHTTPResponse(status: 400)
        }
        let code = issueCode(challenge: value("code_challenge"))
        var back = URLComponents(string: redirectURI)
        back?.queryItems = [URLQueryItem(name: "code", value: code), URLQueryItem(name: "state", value: value("state"))]
        return FakeHTTPResponse(status: 302, headers: ["Location": back?.url?.absoluteString ?? ""])
    }

    private func issue() -> FakeHTTPResponse {
        counter += 1
        let access = "access-\(counter)"
        let refresh = "refresh-\(counter)"
        issued.append(access)
        refreshTokens.insert(refresh)
        let claims: [String: String] = ["preferred_username": address, "name": name, "tid": tenant]
        let payload = (try? JSONSerialization.data(withJSONObject: claims)) ?? Data()
        let idToken = Self.b64url(Data(#"{"alg":"none"}"#.utf8)) + "." + Self.b64url(payload) + ".c2ln"
        let body: [String: Any] = [
            "token_type": "Bearer", "access_token": access, "refresh_token": refresh,
            "expires_in": expiresIn, "id_token": idToken,
            "scope": "https://outlook.office.com/IMAP.AccessAsUser.All https://outlook.office.com/SMTP.Send"
        ]
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        return FakeHTTPResponse(status: 200, body: data, headers: ["Content-Type": "application/json"])
    }

    /// An RFC 6749 error answer, with a description that echoes nothing secret.
    private static func error(_ code: String) -> FakeHTTPResponse {
        .json(400, #"{"error":"\#(code)","error_description":"AADSTS00000: synthetic"}"#)
    }

    private static func challenge(_ verifier: String) -> String {
        b64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func b64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func form(_ body: Data) -> [String: String] {
        var fields: [String: String] = [:]
        for pair in fakeText(body).split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let decode = { (text: Substring) in
                text.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? ""
            }
            guard let key = parts.first else {
                continue
            }
            fields[decode(key)] = parts.count > 1 ? parts.last.map(decode) : ""
        }
        return fields
    }
}
