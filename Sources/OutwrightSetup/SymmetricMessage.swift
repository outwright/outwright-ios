// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import CryptoKit
import Foundation

/// An OpenPGP message encrypted with a passphrase (RFC 9580): a version 6 Symmetric Key Encrypted Session Key packet
/// (§5.3.2) followed by a version 2 Symmetrically Encrypted and Integrity Protected Data packet (§5.13.2) holding a
/// Literal Data packet (§5.9). Binary packets, no armor.
///
/// The writer writes Argon2, AES-256 and GCM. The reader also takes AES-128 and AES-192, and the iterated and salted
/// S2K. Anything well formed that it does not take (other AEAD modes, v4 SKESK, v1 SEIPD, more than one SKESK,
/// compressed data, public-key packets, other literal formats) is `.unsupported`.
public enum SymmetricMessage {
    /// The largest message `open` reads, and the largest `seal` writes.
    public static let maximumSize = 16 * 1024 * 1024
    /// More packets than this at one level is a shape the reader does not take.
    static let maxPackets = 8

    /// Encrypts `plaintext` with `passphrase`. The session key and every salt and nonce are fresh random values.
    public static func seal(
        _ plaintext: [UInt8], passphrase: [UInt8], parameters: Argon2Parameters = .writer
    ) throws(SetupError) -> [UInt8] {
        guard plaintext.count <= maximumSize else { throw .tooLarge }
        let literal = try Packets.write(type: Tag.literal, body: [0x62, 0, 0, 0, 0, 0] + plaintext)
        return try seal(packets: literal, passphrase: passphrase, parameters: parameters)
    }

    /// Encrypts `inner`, the packets the SEIPD holds, in an SKESK and a SEIPD.
    static func seal(
        packets inner: [UInt8], passphrase: [UInt8], parameters: Argon2Parameters
    ) throws(SetupError) -> [UInt8] {
        guard inner.count <= maximumSize else { throw .tooLarge }
        let parameters = try parameters.validated()
        let cipher = Cipher.aes256
        let sessionKey = randomBytes(cipher.keySize)

        let s2kSalt = randomBytes(16)
        let s2kKey = try Argon2id.derive(
            password: passphrase, salt: s2kSalt, parameters: parameters, length: cipher.keySize)
        let s2k = [S2K.argon2] + s2kSalt + [parameters.passes, parameters.lanes, parameters.memoryExponent]
        let skeskHeader: [UInt8] = [Tag.skesk | 0xC0, 6, cipher.rawValue, AEAD.gcm]
        let kek = hkdf(ikm: s2kKey, salt: [], info: skeskHeader, length: cipher.keySize)
        let nonce = randomBytes(AEAD.nonceSize)
        let wrapped = try gcmSeal(sessionKey[...], key: kek, nonce: nonce, aad: skeskHeader)
        guard let fieldsCount = UInt8(exactly: 3 + s2k.count + nonce.count), let s2kCount = UInt8(exactly: s2k.count)
        else { throw .malformed }
        let skesk = [6, fieldsCount, cipher.rawValue, AEAD.gcm, s2kCount] + s2k + nonce + wrapped

        let seipd = try encryptData(inner, sessionKey: sessionKey, cipher: cipher)
        let message = try Packets.write(type: Tag.skesk, body: skesk) + Packets.write(type: Tag.seipd, body: seipd)
        guard message.count <= maximumSize else { throw .tooLarge }
        return message
    }

    /// Decrypts a message `seal` wrote, or any message of the same shape within what the reader takes. A passphrase
    /// that does not open the session key is `.wrongPassphrase`; damage after that is `.malformed`.
    public static func open(_ message: [UInt8], passphrase: [UInt8]) throws(SetupError) -> [UInt8] {
        guard message.count <= maximumSize else { throw .tooLarge }
        // Every field of both packets is checked before the passphrase costs any work.
        let (keyPacket, dataPacket) = try outerPackets(message)
        let sessionKey = try keyPacket.sessionKey(passphrase: passphrase)
        guard sessionKey.count == dataPacket.cipher.keySize else { throw .malformed }
        return try literalData(in: dataPacket.decrypt(sessionKey: sessionKey))
    }

    // MARK: - Writing

    private static func encryptData(
        _ plaintext: [UInt8], sessionKey: [UInt8], cipher: Cipher
    ) throws(SetupError) -> [UInt8] {
        let salt = randomBytes(32)
        let header: [UInt8] = [2, cipher.rawValue, AEAD.gcm, DataPacket.writerChunkOctet]
        let keys = MessageKeys(sessionKey: sessionKey, salt: salt, header: header, cipher: cipher)
        let chunkSize = DataPacket.chunkSize(DataPacket.writerChunkOctet)
        var out = header + salt
        out.reserveCapacity(out.count + plaintext.count + (plaintext.count / chunkSize + 2) * AEAD.tagSize)
        var index: UInt64 = 0
        var start = 0
        while start < plaintext.count {
            let end = min(start + chunkSize, plaintext.count)
            out += try gcmSeal(plaintext[start..<end], key: keys.key, nonce: keys.nonce(index), aad: keys.aad)
            index += 1
            start = end
        }
        let total = bigEndian(UInt64(plaintext.count), octets: 8)
        out += try gcmSeal([], key: keys.key, nonce: keys.nonce(index), aad: keys.aad + total)
        return out
    }

    // MARK: - Reading

    /// The SKESK and the SEIPD, parsed; the packet list is gone once they are, and their bodies are slices of
    /// `message`.
    private static func outerPackets(_ message: [UInt8]) throws(SetupError) -> (SessionKeyPacket, DataPacket) {
        let packets = try content(of: Packets.read(message, maxPackets: maxPackets))
        guard let skesk = packets.first, let seipd = packets.last else { throw .malformed }
        guard packets.count == 2, skesk.type == Tag.skesk, seipd.type == Tag.seipd else { throw .unsupported }
        return (try SessionKeyPacket(skesk.body), try DataPacket(seipd.body))
    }

    /// The packets of an Optionally Padded Message (§10.3), without its trailing padding packets.
    private static func content(of packets: [Packet]) -> [Packet] {
        let padding = packets.reversed().prefix { $0.type == Tag.padding }.count
        return Array(packets.dropLast(padding))
    }

    /// The data of the one literal packet the decrypted `inner` holds.
    private static func literalData(in inner: [UInt8]) throws(SetupError) -> [UInt8] {
        let packets = try content(of: Packets.read(inner, maxPackets: maxPackets))
        guard let literal = packets.first else { throw .malformed }
        guard packets.count == 1, literal.type == Tag.literal else { throw .unsupported }
        var reader = ByteReader(literal.body)
        let format = try reader.byte()
        guard [0x62, 0x75, 0x74].contains(format) else { throw .unsupported }  // b, u, t
        let nameLength = try reader.byte()
        _ = try reader.take(Int(nameLength))
        _ = try reader.take(4)  // date
        return Array(reader.rest())
    }

    // MARK: - Primitives

    static func randomBytes(_ count: Int) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<max(0, count)).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    }

    /// HKDF with SHA-256 (RFC 5869): CryptoKit's extract, and the expand written out with its HMAC, so the output
    /// comes back as bytes. `length` is at most 255 blocks.
    static func hkdf(ikm: [UInt8], salt: [UInt8], info: [UInt8], length: Int) -> [UInt8] {
        let prk = SymmetricKey(data: Array(HKDF<SHA256>.extract(inputKeyMaterial: SymmetricKey(data: ikm), salt: salt)))
        var out: [UInt8] = []
        var block: [UInt8] = []
        var counter: UInt8 = 1
        while out.count < length, counter > 0 {
            block = Array(HMAC<SHA256>.authenticationCode(for: block + info + [counter], using: prk))
            out += block
            counter &+= 1
        }
        return Array(out.prefix(length))
    }

    /// AES-GCM: the ciphertext followed by its 16-octet tag.
    static func gcmSeal(
        _ plaintext: ArraySlice<UInt8>, key: [UInt8], nonce: [UInt8], aad: [UInt8]
    ) throws(SetupError) -> [UInt8] {
        do {
            let box = try AES.GCM.seal(
                plaintext, using: SymmetricKey(data: key), nonce: AES.GCM.Nonce(data: nonce), authenticating: aad)
            return Array(box.ciphertext) + Array(box.tag)
        } catch {
            throw .malformed
        }
    }

    /// AES-GCM opening of a ciphertext followed by its tag, read in place; nil when it does not authenticate.
    static func gcmOpen(_ sealed: ArraySlice<UInt8>, key: [UInt8], nonce: [UInt8], aad: [UInt8]) -> Data? {
        guard sealed.count >= AEAD.tagSize else { return nil }
        let split = sealed.endIndex - AEAD.tagSize
        do {
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: nonce), ciphertext: sealed[..<split], tag: sealed[split...])
            return try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: aad)
        } catch {
            return nil
        }
    }
}

/// Packet Type IDs (RFC 9580 §5).
enum Tag {
    static let skesk: UInt8 = 3
    static let literal: UInt8 = 11
    static let seipd: UInt8 = 18
    static let padding: UInt8 = 21
}

/// The symmetric ciphers the reader takes (RFC 9580 §9.3).
enum Cipher: UInt8 {
    case aes128 = 7
    case aes192 = 8
    case aes256 = 9

    var keySize: Int {
        switch self {
        case .aes128: 16
        case .aes192: 24
        case .aes256: 32
        }
    }

    init(id: UInt8) throws(SetupError) {
        guard let cipher = Cipher(rawValue: id) else { throw .unsupported }
        self = cipher
    }
}

/// AEAD mode GCM (RFC 9580 §5.13.5), the only one the reader takes.
enum AEAD {
    static let gcm: UInt8 = 3
    static let nonceSize = 12
    static let tagSize = 16

    static func require(_ id: UInt8) throws(SetupError) {
        guard id == gcm else { throw .unsupported }
    }
}

/// S2K specifier types (RFC 9580 §3.7.1).
enum S2K {
    static let iterated: UInt8 = 3
    static let argon2: UInt8 = 4

    case iteratedAndSalted(hash: UInt8, salt: [UInt8], count: Int)
    case argon(salt: [UInt8], parameters: Argon2Parameters)

    init(_ bytes: ArraySlice<UInt8>) throws(SetupError) {
        var reader = ByteReader(bytes)
        switch try reader.byte() {
        case Self.iterated:
            guard bytes.count == 11 else { throw .malformed }
            let hash = try reader.byte()
            guard [8, 9, 10].contains(hash) else { throw .unsupported }  // SHA2-256, SHA2-384, SHA2-512
            let salt = Array(try reader.take(8))
            let coded = Int(try reader.byte())
            self = .iteratedAndSalted(hash: hash, salt: salt, count: (16 + (coded & 15)) << ((coded >> 4) + 6))
        case Self.argon2:
            guard bytes.count == 20 else { throw .malformed }
            let salt = Array(try reader.take(16))
            let parameters = try Argon2Parameters(
                passes: reader.byte(), lanes: reader.byte(), memoryExponent: reader.byte())
            self = .argon(salt: salt, parameters: try parameters.validated())
        default:
            throw .unsupported
        }
    }

    func key(passphrase: [UInt8], length: Int) throws(SetupError) -> [UInt8] {
        switch self {
        case .argon(let salt, let parameters):
            return try Argon2id.derive(password: passphrase, salt: salt, parameters: parameters, length: length)
        case .iteratedAndSalted(let hash, let salt, let count):
            // Every hash here is at least as long as the largest key, so one hash context is enough (§3.7.1.1).
            let input = salt + passphrase
            let digest: [UInt8] = switch hash {
            case 9: Self.iteratedHash(SHA384.self, input, count: count)
            case 10: Self.iteratedHash(SHA512.self, input, count: count)
            default: Self.iteratedHash(SHA256.self, input, count: count)
            }
            guard digest.count >= length else { throw .unsupported }
            return Array(digest.prefix(length))
        }
    }

    /// Hashes `input` repeated until `count` octets (at least one whole copy), §3.7.1.3. `count` is at most
    /// 65 011 712, what the coded octet can say.
    private static func iteratedHash<H: HashFunction>(_: H.Type, _ input: [UInt8], count: Int) -> [UInt8] {
        var hasher = H()
        var remaining = max(count, input.count)
        guard !input.isEmpty else { return Array(hasher.finalize()) }
        let block = Array([[UInt8]](repeating: input, count: max(1, 65_536 / input.count)).joined())
        while remaining >= block.count {
            hasher.update(data: block)
            remaining -= block.count
        }
        hasher.update(data: block.prefix(remaining))
        return Array(hasher.finalize())
    }
}

/// A version 6 Symmetric Key Encrypted Session Key packet (RFC 9580 §5.3.2), checked field by field.
struct SessionKeyPacket {
    let cipher: Cipher
    let s2k: S2K
    let nonce: [UInt8]
    let wrapped: ArraySlice<UInt8>

    init(_ body: ArraySlice<UInt8>) throws(SetupError) {
        var reader = ByteReader(body)
        guard try reader.byte() == 6 else { throw .unsupported }
        let fieldsCount = Int(try reader.byte())
        cipher = try Cipher(id: reader.byte())
        try AEAD.require(reader.byte())
        let s2kCount = Int(try reader.byte())
        guard fieldsCount == 3 + s2kCount + AEAD.nonceSize else { throw .malformed }
        s2k = try S2K(reader.take(s2kCount))
        nonce = Array(try reader.take(AEAD.nonceSize))
        wrapped = reader.rest()
        // The wrapped session key is a key for the data packet's cipher (checked against it once open) and a tag.
        guard [Cipher.aes128, .aes192, .aes256].contains(where: { wrapped.count == $0.keySize + AEAD.tagSize })
        else { throw .malformed }
    }

    func sessionKey(passphrase: [UInt8]) throws(SetupError) -> [UInt8] {
        let s2kKey = try s2k.key(passphrase: passphrase, length: cipher.keySize)
        let aad: [UInt8] = [Tag.skesk | 0xC0, 6, cipher.rawValue, AEAD.gcm]
        let kek = SymmetricMessage.hkdf(ikm: s2kKey, salt: [], info: aad, length: cipher.keySize)
        guard let key = SymmetricMessage.gcmOpen(wrapped, key: kek, nonce: nonce, aad: aad) else {
            throw .wrongPassphrase
        }
        return Array(key)
    }
}

/// A version 2 Symmetrically Encrypted and Integrity Protected Data packet (RFC 9580 §5.13.2). The ciphertext is
/// a slice of the message, not a copy.
struct DataPacket {
    static let writerChunkOctet: UInt8 = 16
    /// What a message of `SymmetricMessage.maximumSize` holds at the smallest chunk size, 64 octets plus a tag.
    static let maxChunks = SymmetricMessage.maximumSize / (64 + AEAD.tagSize) + 1

    let cipher: Cipher
    let header: [UInt8]
    let salt: [UInt8]
    let encrypted: ArraySlice<UInt8>
    let finalTag: ArraySlice<UInt8>

    init(_ body: ArraySlice<UInt8>) throws(SetupError) {
        var reader = ByteReader(body)
        let version = try reader.byte()
        guard version == 2 else { throw .unsupported }
        let cipherID = try reader.byte()
        cipher = try Cipher(id: cipherID)
        try AEAD.require(reader.byte())
        let chunkOctet = try reader.byte()
        guard chunkOctet <= 16 else { throw .unsupported }
        header = [version, cipherID, AEAD.gcm, chunkOctet]
        salt = Array(try reader.take(32))
        let rest = reader.rest()
        guard rest.count >= AEAD.tagSize else { throw .malformed }
        encrypted = rest.dropLast(AEAD.tagSize)
        finalTag = rest.suffix(AEAD.tagSize)
    }

    static func chunkSize(_ octet: UInt8) -> Int { 1 << (Int(min(octet, 16)) + 6) }

    /// The plaintext, once every chunk and the final tag over the total length authenticate.
    func decrypt(sessionKey: [UInt8]) throws(SetupError) -> [UInt8] {
        guard let chunkOctet = header.last else { throw .malformed }
        let keys = MessageKeys(sessionKey: sessionKey, salt: salt, header: header, cipher: cipher)
        let stride = Self.chunkSize(chunkOctet) + AEAD.tagSize
        let chunkCount = (encrypted.count + stride - 1) / stride
        guard chunkCount <= Self.maxChunks else { throw .tooLarge }
        var plaintext: [UInt8] = []
        plaintext.reserveCapacity(encrypted.count)
        var index: UInt64 = 0
        var start = encrypted.startIndex
        while start < encrypted.endIndex {
            let end = min(start + stride, encrypted.endIndex)
            // A chunk holds at least one octet: an empty chunk is never written.
            guard end - start > AEAD.tagSize,
                  let chunk = SymmetricMessage.gcmOpen(
                    encrypted[start..<end], key: keys.key, nonce: keys.nonce(index), aad: keys.aad)
            else { throw .malformed }
            plaintext.append(contentsOf: chunk)
            index += 1
            start = end
        }
        let total = bigEndian(UInt64(plaintext.count), octets: 8)
        guard SymmetricMessage.gcmOpen(finalTag, key: keys.key, nonce: keys.nonce(index), aad: keys.aad + total) != nil
        else { throw .malformed }
        return plaintext
    }
}

/// The message key, the IV and the additional data of a v2 SEIPD packet (RFC 9580 §5.13.2).
struct MessageKeys {
    let key: [UInt8]
    let ivPrefix: [UInt8]
    let aad: [UInt8]

    init(sessionKey: [UInt8], salt: [UInt8], header: [UInt8], cipher: Cipher) {
        aad = [Tag.seipd | 0xC0] + header
        let ivSize = AEAD.nonceSize - 8
        let derived = SymmetricMessage.hkdf(ikm: sessionKey, salt: salt, info: aad, length: cipher.keySize + ivSize)
        key = Array(derived.prefix(cipher.keySize))
        ivPrefix = Array(derived.suffix(ivSize))
    }

    /// The nonce of chunk `index`: the IV, then the index as 8 big-endian octets.
    func nonce(_ index: UInt64) -> [UInt8] { ivPrefix + bigEndian(index, octets: 8) }
}
