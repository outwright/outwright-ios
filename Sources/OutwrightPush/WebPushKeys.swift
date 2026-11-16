// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import CryptoKit
public import Foundation

/// The phone's Web Push keys (RFC 8291 §2): a P-256 key pair and a 16-byte authentication secret.
/// The mail server encrypts its push bodies to `p256dh` and `authString`. Kept only in the keychain.
public struct WebPushKeys: Sendable {
    static let authCount = 16
    static let privateKeyCount = 32

    let privateKey: P256.KeyAgreement.PrivateKey
    let auth: Data

    init(privateKey: P256.KeyAgreement.PrivateKey, auth: Data) {
        self.privateKey = privateKey
        self.auth = auth
    }

    /// A fresh key pair and authentication secret.
    public static func generate() -> WebPushKeys {
        var rng = SystemRandomNumberGenerator()
        let auth = Data((0..<authCount).map { _ in UInt8.random(in: 0...255, using: &rng) })
        return WebPushKeys(privateKey: P256.KeyAgreement.PrivateKey(), auth: auth)
    }

    /// The public key as an uncompressed point (65 bytes), base64url without padding.
    public var p256dh: String {
        Self.base64url(privateKey.publicKey.x963Representation)
    }

    /// The authentication secret, base64url without padding.
    public var authString: String {
        Self.base64url(auth)
    }

    /// Layout: the 32-byte raw private scalar followed by the 16-byte authentication secret (48 bytes).
    public var rawRepresentation: Data {
        privateKey.rawRepresentation + auth
    }

    /// Reads the layout `rawRepresentation` writes; anything else throws `.crypto`.
    public init(rawRepresentation: Data) throws(PushError) {
        let bytes = Data(rawRepresentation)
        guard bytes.count == Self.privateKeyCount + Self.authCount else {
            throw .crypto
        }
        guard let key = try? P256.KeyAgreement.PrivateKey(rawRepresentation: bytes.prefix(Self.privateKeyCount))
        else {
            throw .crypto
        }
        self.init(privateKey: key, auth: Data(bytes.suffix(Self.authCount)))
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
