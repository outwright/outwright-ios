// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
public import OutwrightGraph
public import OutwrightIMAP
public import OutwrightModel
public import OutwrightNet
public import OutwrightSMTP
import Synchronization

/// The one way an account proves who it is to its servers: a password account with its
/// keychain password, an OAuth account with an access token from its `TokenSource`. A token
/// a server refuses is renewed once and tried once more. Copies share their token sources, so
/// every sync and send of an account shares one renewal.
public struct CredentialProvider: Sendable {
    public let secrets: any SecretStore
    /// Each OAuth provider's token renewal, by provider.
    private let tokens: [ProviderID: any TokenRefreshing]
    private let now: @Sendable () -> Date
    private let sources = Sources()

    /// An OAuth account whose provider has no renewal here cannot sign in (`.needsSignIn`).
    public init(
        secrets: any SecretStore, tokens: [ProviderID: any TokenRefreshing] = [:],
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.secrets = secrets
        self.tokens = tokens
        self.now = now
    }

    /// The account's token source, renewed by its provider, the same one each time.
    public func tokenSource(for account: AccountID, provider: ProviderID) throws(SyncError) -> TokenSource {
        guard let oauth = tokens[provider] else {
            throw .needsSignIn(account)
        }
        return sources.source(for: account) {
            TokenSource(account: account, secrets: secrets, oauth: oauth, now: now)
        }
    }

    /// Stores a sign-in's refresh token and holds its access token.
    public func store(_ tokens: OAuthTokens, for account: AccountID, provider: ProviderID) async throws(SyncError) {
        try storeSignIn(tokens, for: account, secrets: secrets)
        if let source = try? tokenSource(for: account, provider: provider) {
            await source.hold(tokens)
        }
    }

    /// A Graph client for an account whose calendars or contacts come over Graph, on its `graph`
    /// token. A refused sign-in fails the
    /// request as `.unauthorized`; any other trouble getting a token (the endpoint, the network,
    /// the keychain) as the network, tried again next time. A 401 drops the token it refused, so
    /// the retry renews it.
    public func graphClient(
        for account: Account, base: URL, session: URLSession = .shared
    ) throws(SyncError) -> GraphClient {
        let source = try tokenSource(for: account.id, provider: account.provider)
        return GraphClient(
            base: base, session: session,
            token: { () async throws(GraphError) -> String in
                do throws(SyncError) {
                    return try await source.accessToken(for: .graph).reveal()
                } catch .needsSignIn {
                    throw .unauthorized
                } catch {
                    throw .net
                }
            },
            renew: { refused in await source.invalidate(Secret(refused), for: .graph) })
    }

    /// Drops a removed account's token source (its keychain items go with `secrets.remove`).
    public func forget(_ account: AccountID) {
        sources.remove(account)
    }

    /// Opens an IMAP connection signed in for the account. The password or token is in hand
    /// before the server is called, so a missing one is reported as such, not as the network.
    public func connect(_ endpoint: ServerEndpoint, account: Account) async throws(SyncError) -> IMAPClient {
        let first = try await credential(for: account)
        let client = try await imap { try await IMAPClient.connect(endpoint) }
        do {
            try await signIn(client, account: account, first: first)
        } catch {
            await client.logout()
            throw error
        }
        return client
    }

    /// Signs `client` in. Its connection stays open whatever happens; the caller closes it.
    public func signIn(_ client: IMAPClient, account: Account) async throws(SyncError) {
        try await signIn(client, account: account, first: try await credential(for: account))
    }

    private func signIn(_ client: IMAPClient, account: Account, first: SMTPCredential) async throws(SyncError) {
        switch first {
        case let .password(password):
            do {
                try await client.login(user: account.user, password: password)
            } catch {
                throw .imap(error)
            }
        case let .accessToken(token):
            do {
                try await client.authenticate(user: account.user, accessToken: token)
                return
            } catch .authenticationFailed {
                guard try await tokenSource(for: account.id, provider: account.provider).invalidate(token) else {
                    throw .imap(.authenticationFailed)
                }
            } catch {
                throw Self.imapError(error)
            }
            let renewed = try await tokenSource(for: account.id, provider: account.provider).accessToken()
            do {
                try await client.authenticate(user: account.user, accessToken: renewed)
            } catch {
                throw Self.imapError(error)
            }
        }
    }

    /// What signs the account in to SMTP now.
    public func smtpCredential(for account: Account) async throws(SyncError) -> SMTPCredential {
        try await credential(for: account)
    }

    /// The account's password, or its current access token (the same for IMAP and SMTP).
    private func credential(for account: Account) async throws(SyncError) -> SMTPCredential {
        switch account.auth {
        case .password:
            guard let password = try secrets.password(for: account.id) else {
                throw .noPassword
            }
            return .password(password)
        case .oauth:
            return .accessToken(try await tokenSource(for: account.id, provider: account.provider).accessToken())
        }
    }

    /// Runs `body` with the account's SMTP credential (`first`, when already in hand); for a
    /// OAuth account whose token is refused, renews it and runs `body` once more. `body`'s
    /// errors come back as `.smtp`. (A refused sign-in comes before any message is handed over,
    /// so the second run cannot send twice.)
    public func withSMTP<T>(
        for account: Account, first: SMTPCredential? = nil, _ body: (SMTPCredential) async throws(SMTPError) -> T
    ) async throws(SyncError) -> T {
        let credential: SMTPCredential
        if let first {
            credential = first
        } else {
            credential = try await smtpCredential(for: account)
        }
        do {
            return try await body(credential)
        } catch .xoauth2NotOffered {
            throw .noTokenSignIn
        } catch .authenticationFailed where account.auth == .oauth {
            if let source = try? tokenSource(for: account.id, provider: account.provider),
                case let .accessToken(token) = credential {
                guard await source.invalidate(token) else {
                    throw .smtp(.authenticationFailed)
                }
            }
        } catch {
            throw .smtp(error)
        }
        let renewed = try await smtpCredential(for: account)
        do {
            return try await body(renewed)
        } catch {
            throw .smtp(error)
        }
    }

    private static func imapError(_ error: IMAPError) -> SyncError {
        error == .extensionMissing ? .noTokenSignIn : .imap(error)
    }
}

/// The token sources of every account, shared by the provider's copies.
private final class Sources: Sendable {
    private let all = Mutex<[AccountID: TokenSource]>([:])

    func source(for account: AccountID, make: () -> TokenSource) -> TokenSource {
        all.withLock { all in
            if let source = all[account] {
                return source
            }
            let source = make()
            all[account] = source
            return source
        }
    }

    func remove(_ account: AccountID) {
        _ = all.withLock { $0.removeValue(forKey: account) }
    }
}
