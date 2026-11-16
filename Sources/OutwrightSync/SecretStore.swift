// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
public import OutwrightModel
public import OutwrightNet
import Synchronization

/// Where account passwords, OAuth refresh tokens and subscribed calendars' addresses are kept:
/// the keychain in the app, memory in tests. An account's password and refresh token are kept apart;
/// `remove` takes both. A subscription's address is kept under the subscription's key.
public protocol SecretStore: Sendable {
    func password(for account: AccountID) throws(SyncError) -> Secret?
    func setPassword(_ secret: Secret, for account: AccountID) throws(SyncError)
    func refreshToken(for account: AccountID) throws(SyncError) -> Secret?
    func setRefreshToken(_ secret: Secret, for account: AccountID) throws(SyncError)
    func remove(for account: AccountID) throws(SyncError)
    func subscriptionAddress(_ key: UUID) throws(SyncError) -> Secret?
    func setSubscriptionAddress(_ secret: Secret, for key: UUID) throws(SyncError)
    func removeSubscriptionAddress(_ key: UUID) throws(SyncError)
}

/// Secrets held for the life of the process only (tests and previews).
public final class InMemorySecretStore: SecretStore {
    private let values = Mutex<[AccountID: Secret]>([:])
    private let refreshTokens = Mutex<[AccountID: Secret]>([:])
    private let addresses = Mutex<[UUID: Secret]>([:])

    public init() {}

    public func password(for account: AccountID) throws(SyncError) -> Secret? {
        values.withLock { $0[account] }
    }

    public func setPassword(_ secret: Secret, for account: AccountID) throws(SyncError) {
        values.withLock { $0[account] = secret }
    }

    public func refreshToken(for account: AccountID) throws(SyncError) -> Secret? {
        refreshTokens.withLock { $0[account] }
    }

    public func setRefreshToken(_ secret: Secret, for account: AccountID) throws(SyncError) {
        refreshTokens.withLock { $0[account] = secret }
    }

    public func remove(for account: AccountID) throws(SyncError) {
        _ = values.withLock { $0.removeValue(forKey: account) }
        _ = refreshTokens.withLock { $0.removeValue(forKey: account) }
    }

    public func subscriptionAddress(_ key: UUID) throws(SyncError) -> Secret? {
        addresses.withLock { $0[key] }
    }

    public func setSubscriptionAddress(_ secret: Secret, for key: UUID) throws(SyncError) {
        addresses.withLock { $0[key] = secret }
    }

    public func removeSubscriptionAddress(_ key: UUID) throws(SyncError) {
        _ = addresses.withLock { $0.removeValue(forKey: key) }
    }
}
