// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
public import OutwrightGraph
public import OutwrightModel
public import OutwrightNet

/// Renews an OAuth access token from a refresh token.
public protocol TokenRefreshing: Sendable {
    func refresh(_ token: Secret, for resource: OAuthResource) async throws(OAuthError) -> OAuthTokens
}

extension OAuthClient: TokenRefreshing {}

/// Keeps an OAuth account signed in after the sign-in sheet: stores the sign-in's refresh
/// token in the keychain. Throws `.oauth(.malformed)` for an answer without one (no
/// `offline_access`), as the account could not be kept.
public func storeSignIn(_ tokens: OAuthTokens, for account: AccountID, secrets: any SecretStore) throws(SyncError) {
    guard let refresh = tokens.refreshToken else {
        throw .oauth(.malformed)
    }
    try secrets.setRefreshToken(refresh, for: account)
}

/// One OAuth account's access tokens, one per resource (`OAuthResource`): held in
/// memory only, renewed from the keychain's refresh token when less than five minutes remain
/// (half its life for a token given less than ten). One renewal runs at a time per account,
/// whichever resource asked; callers that ask while one is under way wait for it. Each renewal
/// stores the rotated refresh token. A refresh token the server refused (`invalid_grant`, or
/// Conditional Access asking for the owner) is not tried again, for any resource:
/// `.needsSignIn` until a sign-in stores another.
public actor TokenSource {
    static let margin: TimeInterval = 300
    /// How long a renewed token that is refused is trusted to be refused for good.
    static let retryAfter: TimeInterval = 60
    /// Renewals of other resources a caller waits through before starting its own.
    private static let waits = 4

    public nonisolated let account: AccountID
    private let secrets: any SecretStore
    private let oauth: any TokenRefreshing
    private let now: @Sendable () -> Date
    private var current: [OAuthResource: (token: Secret, keepUntil: Date)] = [:]
    private var refused: Secret?
    private var renewedAt: [OAuthResource: Date] = [:]
    private var renewal: (resource: OAuthResource, task: Task<Result<Secret, SyncError>, Never>)?
    /// Counts the renewals started, so one clears the slot only while it is still its own.
    private var generation = 0

    public init(
        account: AccountID, secrets: any SecretStore, oauth: any TokenRefreshing,
        now: @escaping @Sendable () -> Date
    ) {
        self.account = account
        self.secrets = secrets
        self.oauth = oauth
        self.now = now
    }

    public func accessToken(for resource: OAuthResource = .mail) async throws(SyncError) -> Secret {
        for _ in 0..<Self.waits {
            if let held = current[resource], now() < held.keepUntil {
                return held.token
            }
            guard let renewal else {
                break
            }
            let result = await renewal.task.value
            if renewal.resource == resource {
                return try result.get()
            }
            // Another resource's renewal: a refusal of the refresh token is this one's too.
            if case let .failure(.needsSignIn(id)) = result {
                throw .needsSignIn(id)
            }
        }
        // A new renewal starts only when none is under way: each await lets another caller start one.
        for _ in 0..<Self.waits {
            if let held = current[resource], now() < held.keepUntil {
                return held.token
            }
            guard let pending = renewal else { break }
            _ = await pending.task.value
        }
        if let held = current[resource], now() < held.keepUntil {
            return held.token
        }
        guard renewal == nil else {
            // Others keep renewing: this caller gives up for now rather than run a second renewal.
            throw .oauth(.transport)
        }
        generation &+= 1
        let mine = generation
        let task = Task { await self.renew(resource, generation: mine) }
        renewal = (resource, task)
        return try await task.value.get()
    }

    /// `refused` was refused by a server: when it is the held token for `resource`, the next
    /// `accessToken` renews it, and the answer is true. An Outlook token renewed less than a minute
    /// ago is kept and the answer is false: the caller fails as signed-in-but-refused, with no new
    /// redemption. A token already replaced by another caller changes nothing (true).
    @discardableResult
    public func invalidate(_ refused: Secret, for resource: OAuthResource = .mail) -> Bool {
        guard let held = current[resource], held.token.reveal() == refused.reveal() else {
            // Another caller already replaced it: the next `accessToken` hands out the new one.
            return true
        }
        // Renewed a moment ago and refused again (a tenant with IMAP/SMTP AUTH disabled): a second
        // redemption would be refused the same way. Graph asks at most once per request, so it
        // always gets its one renewal.
        if resource == .mail, let renewedAt = renewedAt[resource],
            now().timeIntervalSince(renewedAt) < Self.retryAfter {
            return false
        }
        current[resource] = nil
        return true
    }

    /// Holds a sign-in's access token, so the first sync after signing in needs no renewal.
    func hold(_ tokens: OAuthTokens, for resource: OAuthResource = .mail) {
        current[resource] = (tokens.accessToken, keepUntil(tokens.expiresAt))
        refused = nil
        renewedAt[resource] = nil
    }

    private func renew(_ resource: OAuthResource, generation mine: Int) async -> Result<Secret, SyncError> {
        let result = await redeem(resource)
        // Only this renewal's own slot is cleared.
        if generation == mine { renewal = nil }
        return result
    }

    private func redeem(_ resource: OAuthResource) async -> Result<Secret, SyncError> {
        let stored: Secret?
        do {
            stored = try secrets.refreshToken(for: account)
        } catch {
            return .failure(error)
        }
        guard let stored, stored.reveal() != refused?.reveal() else {
            return .failure(.needsSignIn(account))
        }
        let tokens: OAuthTokens
        do {
            tokens = try await oauth.refresh(stored, for: resource)
        } catch {
            guard Self.needsOwner(error) else {
                return .failure(.oauth(error))
            }
            refused = stored
            current = [:]
            return .failure(.needsSignIn(account))
        }
        // The rotated token is kept first: if the keychain refuses it, nothing is held, so the
        // next call renews again rather than run on a token whose successor was lost.
        if let rotated = tokens.refreshToken {
            do {
                try secrets.setRefreshToken(rotated, for: account)
            } catch {
                return .failure(error)
            }
        }
        current[resource] = (tokens.accessToken, keepUntil(tokens.expiresAt))
        renewedAt[resource] = now()
        return .success(tokens.accessToken)
    }
    /// When a token expiring at `expiresAt` stops being handed out: `margin` before, or half
    /// its remaining life before for one that lives less than twice the margin.
    private func keepUntil(_ expiresAt: Date) -> Date {
        let life = max(0, expiresAt.timeIntervalSince(now()))
        return expiresAt.addingTimeInterval(-min(Self.margin, life / 2))
    }

    /// Whether only the owner, signing in again, can get past this refusal.
    private static func needsOwner(_ error: OAuthError) -> Bool {
        switch error {
        case .invalidGrant, .refused("interaction_required"), .refused("login_required"): true
        default: false
        }
    }
}
