// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
import Security
import Synchronization

/// Where push secrets are kept (the relay device secret, Web Push private keys, the App Attest
/// key id): the keychain in the app and its extensions, memory in tests.
public protocol PushVault: Sendable {
    func data(for key: String) throws(SyncError) -> Data?
    func set(_ data: Data, for key: String) throws(SyncError)
    func remove(_ key: String) throws(SyncError)
}

/// Push secrets held for the life of the process only (tests and previews).
public final class InMemoryPushVault: PushVault {
    private let values = Mutex<[String: Data]>([:])

    public init() {}

    public func data(for key: String) throws(SyncError) -> Data? {
        values.withLock { $0[key] }
    }

    public func set(_ data: Data, for key: String) throws(SyncError) {
        values.withLock { $0[key] = data }
    }

    public func remove(_ key: String) throws(SyncError) {
        _ = values.withLock { $0.removeValue(forKey: key) }
    }
}

/// Push secrets in the system keychain under the service `com.10boring.outwright.push`, readable
/// after the first unlock (the notification extension runs while the phone is locked) and never
/// synced or backed up off this device.
public struct KeychainPushVault: PushVault {
    static let service = "com.10boring.outwright.push"

    public init() {}

    private func query(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: key,
            kSecUseDataProtectionKeychain as String: true
        ]
    }

    public func data(for key: String) throws(SyncError) -> Data? {
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
        guard let data = result as? Data else {
            throw .keychain(errSecDecode)
        }
        return data
    }

    public func set(_ data: Data, for key: String) throws(SyncError) {
        let values: [String: Any] = [
            kSecValueData as String: data,
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

    public func remove(_ key: String) throws(SyncError) {
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw .keychain(status)
        }
    }
}
