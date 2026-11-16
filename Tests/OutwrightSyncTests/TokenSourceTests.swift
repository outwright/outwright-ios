// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightFakes
import OutwrightGraph
import OutwrightModel
import OutwrightNet
@testable import OutwrightSync
import Synchronization
import Testing

/// A fake token endpoint, a client for it, and an account signed in to it (its refresh token
/// in `secrets`).
struct OAuthHarness {
    let server: FakeOAuthServer
    let oauth: OAuthClient
    let secrets: InMemorySecretStore
    let account: AccountID
    let tokens: OAuthTokens

    /// Moves the token source's clock: seconds from the real now.
    let offset = Offset()

    var now: @Sendable () -> Date {
        { [offset] in Date().addingTimeInterval(offset.value.withLock { $0 }) }
    }

    func source() -> TokenSource {
        TokenSource(account: account, secrets: secrets, oauth: oauth, now: now)
    }

    /// The JSON a token endpoint answers with, for `script`.
    static func answer(access: String, refresh: String = "scripted-refresh", expiresIn: Int = 3600) -> FakeHTTPResponse {
        .json(
            200,
            #"{"token_type":"Bearer","access_token":"\#(access)","refresh_token":"\#(refresh)","expires_in":\#(expiresIn)}"#)
    }
}

final class Offset: Sendable {
    let value = Mutex<TimeInterval>(0)
}

/// Signs in to the fake as a sign-in sheet would: start, a code for the challenge, redeem.
func signedIn(_ server: FakeOAuthServer, _ oauth: OAuthClient) async throws -> OAuthTokens {
    let request = oauth.start()
    let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    let challenge = try #require(items.first { $0.name == "code_challenge" }?.value)
    let code = await server.issueCode(challenge: challenge)
    return try await oauth.redeem(code: code, verifier: request.verifier)
}

/// A provider's OAuth registration as the tests make it: example.org scopes, the fake's redirect.
func testOAuthClient(clientID: String, authority: URL) -> OAuthClient {
    OAuthClient(
        clientID: clientID,
        configuration: OAuthConfiguration(
            authority: authority, redirectURI: "outwright-test://auth",
            authorizeScopes: "offline_access openid email https://mail.example.org/all https://graph.example.org/all",
            scopes: { $0 == .graph ? "offline_access https://graph.example.org/all" : "offline_access openid email https://mail.example.org/all" }),
        session: URLSession(configuration: .ephemeral))
}

func withOAuth(account: AccountID = AccountID(), _ body: (OAuthHarness) async throws -> Void) async throws {
    let server = FakeOAuthServer()
    let authority = try await server.start()
    do {
        let oauth = testOAuthClient(clientID: await server.clientID, authority: authority)
        let tokens = try await signedIn(server, oauth)
        let secrets = InMemorySecretStore()
        try storeSignIn(tokens, for: account, secrets: secrets)
        try await body(OAuthHarness(server: server, oauth: oauth, secrets: secrets, account: account, tokens: tokens))
    } catch {
        await server.stop()
        throw error
    }
    await server.stop()
}

/// Answers a refresh with a token naming its resource, and records how many ran at once.
final class ResourceRefresher: TokenRefreshing {
    let running = Mutex(0)
    let most = Mutex(0)
    let calls = Mutex<[OAuthResource]>([])
    let refuse = Mutex(false)
    /// The token endpoint can't be reached: every renewal fails, and is tried again.
    let unreachable = Mutex(false)

    func refresh(_ token: Secret, for resource: OAuthResource) async throws(OAuthError) -> OAuthTokens {
        let now = running.withLock { $0 += 1; return $0 }
        most.withLock { $0 = max($0, now) }
        calls.withLock { $0.append(resource) }
        try? await Task.sleep(for: .milliseconds(30))
        running.withLock { $0 -= 1 }
        if refuse.withLock({ $0 }) { throw .invalidGrant }
        if unreachable.withLock({ $0 }) { throw .transport }
        let count = calls.withLock { $0.count }
        return OAuthTokens(
            accessToken: Secret("\(resource)-\(count)"), refreshToken: Secret("refresh-\(count)"),
            expiresAt: Date().addingTimeInterval(3600), identity: nil)
    }
}

@Suite struct TokenSourceTests {
    private func resourceSource(_ refresher: ResourceRefresher) throws -> TokenSource {
        let secrets = InMemorySecretStore()
        let account = AccountID()
        try secrets.setRefreshToken(Secret("refresh-0"), for: account)
        return TokenSource(account: account, secrets: secrets, oauth: refresher, now: { Date() })
    }

    @Test func eachResourceHoldsItsOwnToken() async throws {
        let refresher = ResourceRefresher()
        let source = try resourceSource(refresher)
        let outlook = try await source.accessToken(for: .mail)
        let graph = try await source.accessToken(for: .graph)
        #expect(outlook.reveal() != graph.reveal())
        #expect(try await source.accessToken(for: .graph).reveal() == graph.reveal())
        #expect(refresher.calls.withLock { $0 } == [.mail, .graph])
    }

    @Test func oneRenewalAtATimePerAccount() async throws {
        let refresher = ResourceRefresher()
        let source = try resourceSource(refresher)
        async let outlook = source.accessToken(for: .mail)
        async let graph = source.accessToken(for: .graph)
        _ = try await (outlook, graph)
        #expect(refresher.most.withLock { $0 } == 1)
        #expect(Set(refresher.calls.withLock { $0 }) == [.mail, .graph])
    }

    /// Renewals that keep failing, asked for by many callers on both resources: still one at a time.
    @Test func failingRenewalsNeverOverlap() async throws {
        let refresher = ResourceRefresher()
        refresher.unreachable.withLock { $0 = true }
        let source = try resourceSource(refresher)
        await withTaskGroup(of: Void.self) { group in
            // Callers arrive while renewals of the other resource are under way, so some wait through
            // several of them before starting their own.
            for index in 0..<60 {
                group.addTask {
                    try? await Task.sleep(for: .milliseconds(index * 7))
                    _ = try? await source.accessToken(for: index.isMultiple(of: 2) ? .mail : .graph)
                }
            }
        }
        #expect(refresher.most.withLock { $0 } == 1)
    }

    @Test func graphInvalidateLeavesOutlookHeld() async throws {
        let refresher = ResourceRefresher()
        let source = try resourceSource(refresher)
        let outlook = try await source.accessToken(for: .mail)
        let graph = try await source.accessToken(for: .graph)
        await source.hold(OAuthTokens(accessToken: graph, refreshToken: nil, expiresAt: Date().addingTimeInterval(3600), identity: nil), for: .graph)
        #expect(await source.invalidate(graph, for: .graph))
        #expect(try await source.accessToken(for: .graph).reveal() != graph.reveal())
        #expect(try await source.accessToken(for: .mail).reveal() == outlook.reveal())
    }

    @Test func refusedRefreshBlocksBothResources() async throws {
        let refresher = ResourceRefresher()
        let source = try resourceSource(refresher)
        refresher.refuse.withLock { $0 = true }
        await #expect(throws: SyncError.needsSignIn(source.account)) { try await source.accessToken(for: .graph) }
        refresher.refuse.withLock { $0 = false }
        await #expect(throws: SyncError.needsSignIn(source.account)) { try await source.accessToken(for: .mail) }
    }

    @Test func tokenReusedUntilFiveMinutesBeforeExpiry() async throws {
        try await withOAuth { h in
            let source = h.source()
            let first = try await source.accessToken()
            let afterFirst = await h.server.requests

            h.offset.value.withLock { $0 = 3600 - 320 }
            #expect(try await source.accessToken().reveal() == first.reveal())
            #expect(await h.server.requests == afterFirst)

            h.offset.value.withLock { $0 = 3600 - 280 }
            let second = try await source.accessToken()
            #expect(second.reveal() != first.reveal())
            #expect(await h.server.requests == afterFirst + 1)
        }
    }

    /// A token that lives less than the five minutes is still reused for half its life.
    @Test func shortLivedTokenIsReused() async throws {
        try await withOAuth { h throws in
            await h.server.script([OAuthHarness.answer(access: "short", expiresIn: 120)])
            let source = h.source()
            #expect(try await source.accessToken().reveal() == "short")
            let afterFirst = await h.server.requests
            h.offset.value.withLock { $0 = 30 }
            #expect(try await source.accessToken().reveal() == "short")
            #expect(await h.server.requests == afterFirst)
        }
    }

    /// A fresh sign-in's token, refused, renews even right after an earlier renewal.
    @Test func refusedSignInTokenRenewsRightAfterARenewal() async throws {
        try await withOAuth { h in
            let source = h.source()
            _ = try await source.accessToken()
            await source.hold(h.tokens)
            #expect(await source.invalidate(h.tokens.accessToken))
        }
    }

    @Test func concurrentCallersShareOneRefresh() async throws {
        try await withOAuth { h in
            let source = h.source()
            let before = await h.server.requests
            let tokens = try await withThrowingTaskGroup(of: String.self) { group in
                for _ in 0..<8 {
                    group.addTask { try await source.accessToken().reveal() }
                }
                var all: [String] = []
                for try await token in group {
                    all.append(token)
                }
                return all
            }
            #expect(tokens.count == 8)
            #expect(Set(tokens).count == 1)
            #expect(await h.server.requests == before + 1)
        }
    }

    @Test func refreshRotatesStoredToken() async throws {
        try await withOAuth { h in
            let initial = try #require(h.tokens.refreshToken)
            _ = try await h.source().accessToken()
            let rotated = try #require(try h.secrets.refreshToken(for: h.account))
            #expect(rotated.reveal() != initial.reveal())
            // The rotated token is the one that works from now on.
            await h.server.revoke(initial.reveal())
            _ = try await h.source().accessToken()
        }
    }

    @Test func revokedRefreshMarksNeedsSignIn() async throws {
        try await withOAuth { h in
            await h.server.revoke(try #require(h.tokens.refreshToken).reveal())
            let source = h.source()
            await #expect(throws: SyncError.needsSignIn(h.account)) { try await source.accessToken() }
            let asked = await h.server.requests
            // Asked again, it does not go back to the server with the refused token.
            await #expect(throws: SyncError.needsSignIn(h.account)) { try await source.accessToken() }
            #expect(await h.server.requests == asked)

            // Signing in again brings the account back.
            let again = try await signedIn(h.server, h.oauth)
            try storeSignIn(again, for: h.account, secrets: h.secrets)
            _ = try await source.accessToken()
        }
    }

    @Test(arguments: ["interaction_required", "login_required"])
    func conditionalAccessMarksNeedsSignIn(code: String) async throws {
        try await withOAuth { h in
            await h.server.script([.json(400, #"{"error":"\#(code)"}"#)])
            await #expect(throws: SyncError.needsSignIn(h.account)) { try await h.source().accessToken() }
        }
    }

    @Test func unreachableTokenEndpointIsTriedAgainNextTime() async throws {
        try await withOAuth { h in
            await h.server.script([.json(503, "busy")])
            let source = h.source()
            await #expect(throws: SyncError.oauth(.http(503))) { try await source.accessToken() }
            _ = try await source.accessToken()
        }
    }

    @Test func failedKeychainWriteRenewsAgainNextTime() async throws {
        try await withOAuth { h in
            let secrets = FailingWrites(h.secrets)
            let source = TokenSource(account: h.account, secrets: secrets, oauth: h.oauth, now: h.now)
            secrets.failNext.withLock { $0 = true }
            await #expect(throws: SyncError.keychain(-25_308)) { try await source.accessToken() }
            let asked = await h.server.requests
            // The rotated token was not kept, so the next call renews and keeps it this time.
            _ = try await source.accessToken()
            #expect(await h.server.requests == asked + 1)
            let kept = try #require(try h.secrets.refreshToken(for: h.account))
            #expect(kept.reveal() != h.tokens.refreshToken?.reveal())
        }
    }

    @Test func refreshTokenIsKeptApartFromThePassword() throws {
        let secrets = InMemorySecretStore()
        let account = AccountID()
        try secrets.setPassword(Secret("pw"), for: account)
        try secrets.setRefreshToken(Secret("rt"), for: account)
        #expect(try secrets.password(for: account)?.reveal() == "pw")
        #expect(try secrets.refreshToken(for: account)?.reveal() == "rt")
        try secrets.remove(for: account)
        #expect(try secrets.password(for: account) == nil)
        #expect(try secrets.refreshToken(for: account) == nil)
    }
}

/// Refuses the next refresh-token write, as a locked keychain would; otherwise `base`.
final class FailingWrites: SecretStore {
    let base: InMemorySecretStore
    let failNext = Mutex(false)

    init(_ base: InMemorySecretStore) {
        self.base = base
    }

    func password(for account: AccountID) throws(SyncError) -> Secret? { try base.password(for: account) }
    func setPassword(_ secret: Secret, for account: AccountID) throws(SyncError) {
        try base.setPassword(secret, for: account)
    }
    func refreshToken(for account: AccountID) throws(SyncError) -> Secret? { try base.refreshToken(for: account) }
    func setRefreshToken(_ secret: Secret, for account: AccountID) throws(SyncError) {
        if failNext.withLock({ value in defer { value = false }; return value }) {
            throw .keychain(-25_308)
        }
        try base.setRefreshToken(secret, for: account)
    }
    func remove(for account: AccountID) throws(SyncError) { try base.remove(for: account) }
    func subscriptionAddress(_ key: UUID) throws(SyncError) -> Secret? { try base.subscriptionAddress(key) }
    func setSubscriptionAddress(_ secret: Secret, for key: UUID) throws(SyncError) {
        try base.setSubscriptionAddress(secret, for: key)
    }
    func removeSubscriptionAddress(_ key: UUID) throws(SyncError) { try base.removeSubscriptionAddress(key) }
}
