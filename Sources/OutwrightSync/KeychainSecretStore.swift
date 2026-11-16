// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
public import OutwrightModel
public import OutwrightNet
import Security

/// Secrets in the system keychain, generic passwords readable after the first unlock and
/// never synced to other devices or put in backups that leave this one. An account's password
/// is kept under its uuid, its OAuth refresh token under `<uuid>.microsoft-refresh` (a name kept
/// from before providers, so installed phones keep their sign-ins), a
/// subscribed calendar's address under `subscription.<key>`.
public struct KeychainSecretStore: SecretStore {
    static let service = "com.10boring.outwright"
    static let refreshSuffix = ".microsoft-refresh"
    static let subscriptionPrefix = "subscription."

    public init() {}

    private func query(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: key,
            kSecUseDataProtectionKeychain as String: true
        ]
    }

    private static func passwordKey(_ account: AccountID) -> String {
        account.raw.uuidString
    }

    private static func refreshKey(_ account: AccountID) -> String {
        account.raw.uuidString + refreshSuffix
    }

    public func password(for account: AccountID) throws(SyncError) -> Secret? {
        try read(Self.passwordKey(account))
    }

    public func setPassword(_ secret: Secret, for account: AccountID) throws(SyncError) {
        try write(secret, Self.passwordKey(account))
    }

    public func refreshToken(for account: AccountID) throws(SyncError) -> Secret? {
        try read(Self.refreshKey(account))
    }

    public func setRefreshToken(_ secret: Secret, for account: AccountID) throws(SyncError) {
        try write(secret, Self.refreshKey(account))
    }

    public func remove(for account: AccountID) throws(SyncError) {
        try delete(Self.passwordKey(account))
        try delete(Self.refreshKey(account))
    }

    public func subscriptionAddress(_ key: UUID) throws(SyncError) -> Secret? {
        try read(Self.subscriptionPrefix + key.uuidString)
    }

    public func setSubscriptionAddress(_ secret: Secret, for key: UUID) throws(SyncError) {
        try write(secret, Self.subscriptionPrefix + key.uuidString)
    }

    public func removeSubscriptionAddress(_ key: UUID) throws(SyncError) {
        try delete(Self.subscriptionPrefix + key.uuidString)
    }

    // MARK: - Items

    private func read(_ key: String) throws(SyncError) -> Secret? {
        var search = query(key)
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(search as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw .keychain(status)
        }
        guard let data = result as? Data, let text = String(data: data, encoding: .utf8) else {
            throw .keychain(errSecDecode)
        }
        return Secret(text)
    }

    private func write(_ secret: Secret, _ key: String) throws(SyncError) {
        let values: [String: Any] = [
            kSecValueData as String: Data(secret.reveal().utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query(key) as CFDictionary, values as CFDictionary)
        if status == errSecSuccess {
            return
        }
        guard status == errSecItemNotFound else {
            throw .keychain(status)
        }
        let item = query(key).merging(values) { _, new in new }
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else {
            throw .keychain(added)
        }
    }

    private func delete(_ key: String) throws(SyncError) {
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw .keychain(status)
        }
    }
}
