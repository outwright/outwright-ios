// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import CryptoKit
import Foundation
import OutwrightFakes
import OutwrightNet
import Testing

@testable import OutwrightGraph

@Suite struct OAuthTests {
    private let clientID = "11111111-2222-3333-4444-555555555555"
    static let mailScopes = "offline_access openid email https://mail.example.org/all"
    static let graphScopes = "offline_access https://graph.example.org/all"
    static let defaultAuthority = URL(string: "https://login.example.org/oauth2/") ?? URL(filePath: "/")

    /// A provider's registration as the tests make it: example.org addresses, one consent for
    /// both resources, a prompt as an extra.
    static func client(
        _ clientID: String, authority: URL = defaultAuthority, session: URLSession = .shared
    ) -> OAuthClient {
        OAuthClient(
            clientID: clientID,
            configuration: OAuthConfiguration(
                authority: authority, redirectURI: "outwright-test://auth",
                authorizeScopes: mailScopes + " https://graph.example.org/all",
                scopes: { $0 == .graph ? graphScopes : mailScopes },
                authorizeExtras: [URLQueryItem(name: "prompt", value: "select_account")]),
            session: session)
    }

    private func withServer(_ body: (FakeOAuthServer, OAuthClient) async throws -> Void) async throws {
        let server = FakeOAuthServer(clientID: clientID)
        let authority = try await server.start()
        let oauth = Self.client(clientID, authority: authority, session: URLSession(configuration: .ephemeral))
        do {
            try await body(server, oauth)
        } catch {
            await server.stop()
            throw error
        }
        await server.stop()
    }

    private static func query(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    private static func b64url(_ data: some Sequence<UInt8>) -> String {
        Data(data).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func callback(_ items: [String: String]) throws -> URL {
        var parts = URLComponents()
        parts.scheme = "outwright-test"
        parts.host = "auth"
        parts.queryItems = items.map { URLQueryItem(name: $0.key, value: $0.value) }
        return try #require(parts.url)
    }

    /// Signs in against the fake: start, the fake issues a code for the challenge, redeem.
    private func signIn(_ server: FakeOAuthServer, _ oauth: OAuthClient) async throws -> OAuthTokens {
        let request = oauth.start()
        let challenge = try #require(Self.query(request.url)["code_challenge"])
        let code = await server.issueCode(challenge: challenge)
        return try await oauth.redeem(code: code, verifier: request.verifier)
    }

    // MARK: - The authorization request

    /// The authorize URL asks for what the configuration's consent covers.
    @Test func authorizeAsksForTheConfiguredScopes() throws {
        let oauth = Self.client(clientID)
        #expect(Self.query(oauth.start().url)["scope"] == oauth.configuration.authorizeScopes)
    }

    /// The address the owner already typed goes along as a hint; without one, none is sent.
    @Test func authorizeCarriesTheAddressAsAHint() {
        let oauth = Self.client(clientID)
        #expect(Self.query(oauth.start(loginHint: "jk@example.org").url)["login_hint"] == "jk@example.org")
        #expect(Self.query(oauth.start().url)["login_hint"] == nil)
        #expect(Self.query(oauth.start(loginHint: " ").url)["login_hint"] == nil)
    }

    @Test func callbackSchemeIsTheRedirectURIsScheme() {
        #expect(Self.client(clientID).configuration.callbackScheme == "outwright-test")
    }

    /// A token is for one resource: each refresh asks for that resource's scopes only.
    @Test func refreshSendsTheResourceScopes() async throws {
        try await withServer { server, oauth in
            let request = oauth.start()
            let challenge = try #require(Self.query(request.url)["code_challenge"])
            let code = await server.issueCode(challenge: challenge)
            let signIn = try await oauth.redeem(code: code, verifier: request.verifier)
            let refresh = try #require(signIn.refreshToken)
            let rotated = try await oauth.refresh(refresh, for: .graph)
            _ = try await oauth.refresh(try #require(rotated.refreshToken), for: .mail)
            let asked = await server.scopes
            #expect(asked == [Self.mailScopes, Self.graphScopes, Self.mailScopes])
        }
    }

    @Test func requestPrintsNeitherVerifierNorState() {
        let request = Self.client(clientID).start()
        var dumped = ""
        dump(request, to: &dumped)
        for text in [String(describing: request), String(reflecting: request), dumped, "\(request)"] {
            #expect(!text.contains(request.verifier))
            #expect(!text.contains(request.state))
        }
    }

    @Test func startBuildsAuthorizeURL() throws {
        let oauth = Self.client(clientID)
        let request = oauth.start()
        let url = request.url
        #expect(url.scheme == "https")
        #expect(url.host == "login.example.org")
        #expect(url.path == "/oauth2/authorize")
        let query = Self.query(url)
        #expect(query["client_id"] == clientID)
        #expect(query["response_type"] == "code")
        #expect(query["redirect_uri"] == "outwright-test://auth")
        #expect(query["state"] == request.state)
        #expect(query["prompt"] == "select_account")
        #expect(query["code_challenge_method"] == "S256")
        #expect(query["code_challenge"] == Self.b64url(SHA256.hash(data: Data(request.verifier.utf8))))
        #expect(query["client_secret"] == nil)

        let unreserved = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        #expect((43...128).contains(request.verifier.count))
        #expect(request.verifier.allSatisfy { unreserved.contains($0) })
        // 32 random bytes, base64url without padding.
        #expect(request.state.count == 43)
        let other = oauth.start()
        #expect(other.state != request.state)
        #expect(other.verifier != request.verifier)
    }

    @Test func callbackGivesCode() throws {
        let oauth = Self.client(clientID)
        let request = oauth.start()
        let url = try Self.callback(["code": "the-code", "state": request.state])
        #expect(try oauth.code(from: url, expecting: request.state) == "the-code")
    }

    @Test func callbackWithWrongStateIsRefused() throws {
        let oauth = Self.client(clientID)
        let request = oauth.start()
        let wrong = try Self.callback(["code": "the-code", "state": "someone-else"])
        #expect(throws: OAuthError.wrongState) { try oauth.code(from: wrong, expecting: request.state) }
        let missing = try Self.callback(["code": "the-code"])
        #expect(throws: OAuthError.wrongState) { try oauth.code(from: missing, expecting: request.state) }
    }

    @Test func callbackWithErrorIsRefused() throws {
        let oauth = Self.client(clientID)
        let request = oauth.start()
        let denied = try Self.callback([
            "error": "access_denied", "error_description": "The user said no", "state": request.state,
        ])
        #expect(throws: OAuthError.refused("access_denied")) { try oauth.code(from: denied, expecting: request.state) }
        let empty = try Self.callback(["state": request.state])
        #expect(throws: OAuthError.malformed) { try oauth.code(from: empty, expecting: request.state) }
    }

    // MARK: - The token endpoint

    @Test func redeemReadsTokensAndIdentity() async throws {
        try await withServer { server, oauth in
            let before = Date()
            let tokens = try await signIn(server, oauth)
            let issued = await server.issued
            #expect(issued.count == 1)
            #expect(tokens.accessToken.reveal() == issued.first)
            #expect(tokens.refreshToken != nil)
            #expect(tokens.expiresAt >= before.addingTimeInterval(3500))
            #expect(tokens.expiresAt <= Date().addingTimeInterval(3700))
            #expect(tokens.identity == OAuthIdentity(address: "jk@example.org", name: "J Karlsson", tenant: "tenant-1"))
        }
    }

    @Test func redeemWithWrongVerifierIsInvalidGrant() async throws {
        try await withServer { server, oauth in
            let request = oauth.start()
            let challenge = try #require(Self.query(request.url)["code_challenge"])
            let code = await server.issueCode(challenge: challenge)
            await #expect(throws: OAuthError.invalidGrant) {
                try await oauth.redeem(code: code, verifier: oauth.start().verifier)
            }
        }
    }

    @Test func refreshRotatesRefreshToken() async throws {
        try await withServer { server, oauth in
            let first = try await signIn(server, oauth)
            let refresh = try #require(first.refreshToken)
            let second = try await oauth.refresh(refresh)
            #expect(second.accessToken.reveal() != first.accessToken.reveal())
            #expect(second.accessToken.reveal() == (await server.issued).last)
            let rotated = try #require(second.refreshToken)
            #expect(rotated.reveal() != refresh.reveal())
            // The rotated one works in turn.
            _ = try await oauth.refresh(rotated)
            #expect(await server.issued.count == 3)
        }
    }

    @Test func revokedRefreshIsInvalidGrant() async throws {
        try await withServer { server, oauth in
            let tokens = try await signIn(server, oauth)
            let refresh = try #require(tokens.refreshToken)
            await server.revoke(refresh.reveal())
            await #expect(throws: OAuthError.invalidGrant) { try await oauth.refresh(refresh) }
            await #expect(throws: OAuthError.invalidGrant) { try await oauth.refresh(Secret("never-issued")) }
        }
    }

    @Test func scriptedAnswersMapToTypedErrors() async throws {
        try await withServer { server, oauth in
            await server.script([
                .json(400, #"{"error":"invalid_scope","error_description":"no"}"#),
                .json(503, "busy"),
                .json(200, "not json"),
                .json(200, #"{"access_token":"a","token_type":"Bearer","expires_in":60,"id_token":"only.two"}"#),
                .json(200, #"{"token_type":"Bearer","expires_in":60}"#),
            ])
            let refresh = Secret("r")
            await #expect(throws: OAuthError.refused("invalid_scope")) { try await oauth.refresh(refresh) }
            await #expect(throws: OAuthError.http(503)) { try await oauth.refresh(refresh) }
            await #expect(throws: OAuthError.malformed) { try await oauth.refresh(refresh) }
            await #expect(throws: OAuthError.malformed) { try await oauth.refresh(refresh) }
            await #expect(throws: OAuthError.malformed) { try await oauth.refresh(refresh) }
        }
    }

    @Test func plainHTTPOnlyToLoopback() async throws {
        let authority = try #require(URL(string: "http://login.example.org/common/oauth2/v2.0/"))
        let oauth = Self.client(clientID, authority: authority)
        await #expect(throws: OAuthError.transport) { try await oauth.refresh(Secret("r")) }
    }

    // MARK: - Hostile answers

    @Test func tokenAnswerOver64KiBIsMalformed() async throws {
        try await withServer { server, oauth in
            let padding = String(repeating: "x", count: 70 * 1024)
            await server.script([
                .json(200, #"{"access_token":"a","token_type":"Bearer","expires_in":60,"pad":"\#(padding)"}"#)
            ])
            await #expect(throws: OAuthError.malformed) { try await oauth.refresh(Secret("r")) }
        }
    }

    @Test func tokenAnswerParserNeverTraps() throws {
        var rng = SystemRandomNumberGenerator()
        let now = Date()
        let seeds = [
            #"{"access_token":"a","refresh_token":"r","token_type":"Bearer","expires_in":3600,"id_token":"e30.e30.e30"}"#,
            #"{"error":"invalid_grant","error_description":"gone"}"#,
            #"{"access_token":"a","token_type":"Bearer","expires_in":-9223372036854775808}"#,
            #"{"access_token":"a","token_type":"Bearer","expires_in":1e308,"id_token":"..."}"#,
        ].map { Data($0.utf8) }
        for round in 0..<2000 {
            var body: Data
            if round.isMultiple(of: 2) {
                let count = Int.random(in: 0...400, using: &rng)
                body = Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &rng) })
            } else {
                body = seeds[Int.random(in: 0..<seeds.count, using: &rng)]
                for _ in 0..<Int.random(in: 1...6, using: &rng) where !body.isEmpty {
                    let index = Int.random(in: 0..<body.count, using: &rng)
                    body[index] = UInt8.random(in: 0...255, using: &rng)
                }
            }
            let status = [200, 400, 401, 500, Int.random(in: -1...999, using: &rng)][round % 5]
            _ = try? OAuthClient.tokens(from: body, status: status, now: now)
        }
        // An id token whose payload is not JSON, or too big, or not base64url.
        for idToken in ["a.b.c", "a.!!!.c", "a..c", "a.\(String(repeating: "e", count: 30_000)).c", "a.b.c.d"] {
            let body = Data(#"{"access_token":"a","token_type":"Bearer","expires_in":60,"id_token":"\#(idToken)"}"#.utf8)
            #expect(throws: OAuthError.malformed) { try OAuthClient.tokens(from: body, status: 200, now: now) }
        }
    }

    @Test func errorsNeverContainSecrets() async throws {
        try await withServer { server, oauth in
            let request = oauth.start()
            let challenge = try #require(Self.query(request.url)["code_challenge"])
            let code = await server.issueCode(challenge: challenge)
            let wrongVerifier = oauth.start().verifier
            var errors: [OAuthError] = []
            do throws(OAuthError) {
                _ = try await oauth.redeem(code: code, verifier: wrongVerifier)
            } catch {
                errors.append(error)
            }
            let tokens = try await signIn(server, oauth)
            let refresh = try #require(tokens.refreshToken)
            await server.revoke(refresh.reveal())
            do throws(OAuthError) {
                _ = try await oauth.refresh(refresh)
            } catch {
                errors.append(error)
            }
            // A server that echoes the secret in its error code and description.
            await server.script([
                .json(400, #"{"error":"\#(refresh.reveal())","error_description":"\#(code) \#(wrongVerifier)"}"#)
            ])
            do throws(OAuthError) {
                _ = try await oauth.refresh(refresh)
            } catch {
                errors.append(error)
            }
            #expect(errors.count == 3)
            let secrets = [code, wrongVerifier, request.verifier, refresh.reveal(), tokens.accessToken.reveal()]
            for error in errors {
                for text in ["\(error)", String(reflecting: error), error.localizedDescription] {
                    for secret in secrets {
                        #expect(!text.contains(secret))
                    }
                }
            }
            let printed = "\(tokens) \(String(reflecting: tokens))"
            #expect(!printed.contains(tokens.accessToken.reveal()))
            #expect(!printed.contains(refresh.reveal()))
        }
    }
}
