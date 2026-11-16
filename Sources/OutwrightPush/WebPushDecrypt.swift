// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import CryptoKit
public import Foundation

/// The largest push body accepted, matching the relay's cap.
let webPushMaxBody = 8 * 1024

/// Decrypts an `aes128gcm` Web Push body (RFC 8291, RFC 8188) holding a single record.
/// A body that does not parse throws `.malformed`; one that does not decrypt throws `.crypto`.
public func decryptWebPush(_ body: Data, keys: WebPushKeys) throws(PushError) -> Data {
    let bytes = Data(body)  // zero-based indices
    guard bytes.count <= webPushMaxBody else {
        throw .malformed
    }
    let header = try WebPushHeader(bytes)
    let ciphertext = Data(bytes.dropFirst(header.count))
    // One record: a tag (16) and at least the delimiter octet, no longer than the record size.
    guard ciphertext.count >= 17, ciphertext.count <= header.recordSize else {
        throw .malformed
    }
    guard let sender = try? P256.KeyAgreement.PublicKey(x963Representation: header.keyID),
          let shared = try? keys.privateKey.sharedSecretFromKeyAgreement(with: sender)
    else {
        throw .crypto
    }
    let receiver = keys.privateKey.publicKey.x963Representation

    // RFC 8291 §3.4: combine the ECDH secret with the authentication secret.
    let keyInfo = Data("WebPush: info".utf8) + [0] + receiver + header.keyID
    let ikm = shared.hkdfDerivedSymmetricKey(
        using: SHA256.self, salt: keys.auth, sharedInfo: keyInfo, outputByteCount: 32)
    // RFC 8188 §2.2 and §2.3: content encryption key and nonce.
    let prk = Data(HKDF<SHA256>.extract(inputKeyMaterial: ikm, salt: header.salt))
    let cek = expand(prk: prk, info: Data("Content-Encoding: aes128gcm".utf8) + [0], count: 16)
    let nonce = expand(prk: prk, info: Data("Content-Encoding: nonce".utf8) + [0], count: 12)

    guard let gcmNonce = try? AES.GCM.Nonce(data: nonce),
          let box = try? AES.GCM.SealedBox(
              nonce: gcmNonce, ciphertext: ciphertext.dropLast(16), tag: ciphertext.suffix(16)),
          let padded = try? AES.GCM.open(box, using: SymmetricKey(data: cek))
    else {
        throw .crypto
    }
    return try unpad(padded)
}

/// RFC 8188 §2: zero padding after a delimiter octet; `0x02` marks the last (here, only) record.
private func unpad(_ padded: Data) throws(PushError) -> Data {
    let bytes = Data(padded)
    guard let end = bytes.lastIndex(where: { $0 != 0 }), bytes[end] == 2 else {
        throw .malformed
    }
    return Data(bytes.prefix(end))
}

/// The RFC 8188 §2.1 header: salt (16), record size (UInt32), idlen (1), keyid (idlen).
/// RFC 8291 §4 makes the keyid the sender's uncompressed public key, so idlen is 65.
private struct WebPushHeader {
    static let fixedCount = 21
    static let keyIDCount = 65

    let salt: Data
    let recordSize: Int
    let keyID: Data
    var count: Int { Self.fixedCount + keyID.count }

    init(_ bytes: Data) throws(PushError) {
        guard bytes.count >= Self.fixedCount else {
            throw .malformed
        }
        let fixed = [UInt8](bytes.prefix(Self.fixedCount))
        salt = Data(fixed.prefix(16))
        recordSize = fixed.dropFirst(16).prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        let idlen = Int(fixed.last ?? 0)
        guard recordSize >= 18, idlen == Self.keyIDCount, bytes.count >= Self.fixedCount + idlen else {
            throw .malformed
        }
        keyID = Data(bytes.dropFirst(Self.fixedCount).prefix(idlen))
    }
}

private func hmac(key: Data, data: Data) -> Data {
    Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
}

/// HKDF-Expand for at most one block (32 bytes), which is all Web Push needs.
private func expand(prk: Data, info: Data, count: Int) -> Data {
    Data(hmac(key: prk, data: info + [1]).prefix(count))
}
