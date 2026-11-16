// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import CryptoKit
public import Foundation
public import OutwrightPush

#if canImport(DeviceCheck)
import DeviceCheck
#endif

/// Proves to the relay that requests come from a genuine copy of the app (App Attest). The
/// relay checks a `clientDataHash` that is the SHA-256 of the UTF-8 challenge.
public protocol DeviceAttester: Sendable {
    /// The device's attestation key id, made on first use.
    func keyID() async throws(PushError) -> String
    func attest(keyID: String, challenge: String) async throws(PushError) -> Data
    func assert(keyID: String, challenge: String) async throws(PushError) -> Data
    /// Drops the key, so the next `keyID` makes (and the next registration attests) a new one.
    func forgetKey() async
}

extension DeviceAttester {
    /// What the relay expects signed for a challenge.
    static func clientDataHash(_ challenge: String) -> Data {
        Data(SHA256.hash(data: Data(challenge.utf8)))
    }
}

#if canImport(DeviceCheck)
/// App Attest through `DCAppAttestService`, the key id kept in the vault. Unsupported devices
/// (the simulator, macOS) throw `.attest`.
public struct AppAttester: DeviceAttester {
    static let keyIDKey = "appAttestKeyID"
    private let vault: any PushVault

    public init(vault: any PushVault = KeychainPushVault()) {
        self.vault = vault
    }

    public func keyID() async throws(PushError) -> String {
        if let stored = try? vault.data(for: Self.keyIDKey), let id = String(data: stored, encoding: .utf8),
            !id.isEmpty {
            return id
        }
        let service = DCAppAttestService.shared
        guard service.isSupported else {
            throw .attest
        }
        let id: String
        do {
            id = try await service.generateKey()
        } catch {
            throw .attest
        }
        do {
            try vault.set(Data(id.utf8), for: Self.keyIDKey)
        } catch {
            throw .storage
        }
        return id
    }

    public func attest(keyID: String, challenge: String) async throws(PushError) -> Data {
        do {
            return try await DCAppAttestService.shared.attestKey(
                keyID, clientDataHash: Self.clientDataHash(challenge))
        } catch {
            forgetIfInvalid(error)
            throw .attest
        }
    }

    public func assert(keyID: String, challenge: String) async throws(PushError) -> Data {
        do {
            return try await DCAppAttestService.shared.generateAssertion(
                keyID, clientDataHash: Self.clientDataHash(challenge))
        } catch {
            forgetIfInvalid(error)
            throw .attest
        }
    }

    public func forgetKey() async {
        try? vault.remove(Self.keyIDKey)
    }

    /// A key the system no longer knows (a restore to another device) is dropped, so the next
    /// `keyID` makes a new one.
    private func forgetIfInvalid(_ error: any Error) {
        if (error as? DCError)?.code == .invalidKey {
            try? vault.remove(Self.keyIDKey)
        }
    }
}
#endif
