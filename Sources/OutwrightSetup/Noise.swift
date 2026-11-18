// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import CryptoKit
import Foundation

/// The handshake of `Noise_NNpsk0_25519_ChaChaPoly_SHA256` (Noise specification revision 34): two messages, `psk, e`
/// and `e, ee`, with empty payloads. Both sides prove they hold the 32-byte pre-shared key, and the prologue binds the
/// session to what the two sides agreed outside it. Once both messages are through, `split()` gives the transport.
///
/// Any failure leaves the handshake unusable: every later call throws.
public struct NoiseHandshake {
    static let protocolName = Array("Noise_NNpsk0_25519_ChaChaPoly_SHA256".utf8)
    static let keySize = 32
    static let tagSize = 16

    private var state: NoiseSymmetricState
    private let initiator: Bool
    private let psk: [UInt8]
    private let ephemeral: Curve25519.KeyAgreement.PrivateKey
    private var remoteEphemeral: Curve25519.KeyAgreement.PublicKey?
    /// 0: the initiator's message is next, 1: the responder's, 2: complete.
    private var step = 0
    private var failed = false
    private var spent = false

    public init(
        initiator: Bool, psk: [UInt8], prologue: [UInt8],
        ephemeral: Curve25519.KeyAgreement.PrivateKey = .init()
    ) throws(SetupError) {
        guard psk.count == Self.keySize else { throw .malformed }
        self.initiator = initiator
        self.psk = psk
        self.ephemeral = ephemeral
        state = NoiseSymmetricState(protocolName: Self.protocolName)
        state.mixHash(prologue)
    }

    public var isComplete: Bool { step == 2 && !failed }

    /// The next message to send: the initiator's first or the responder's reply.
    public mutating func writeMessage() throws(SetupError) -> [UInt8] {
        guard !failed, step == (initiator ? 0 : 1) else { throw .malformed }
        var message: [UInt8] = []
        if initiator { state.mixKeyAndHash(psk) }
        let publicKey = Array(ephemeral.publicKey.rawRepresentation)
        message += publicKey
        state.mixHash(publicKey)
        state.mixKey(publicKey)
        if !initiator {
            do {
                try state.mixKey(Self.agree(ephemeral, remoteEphemeral))
            } catch {
                failed = true
                throw error
            }
        }
        do {
            message += try state.encryptAndHash([])
        } catch {
            failed = true
            throw error
        }
        step += 1
        return message
    }

    /// Takes the other side's message. Throws `.handshakeFailed` when it does not come from a holder of the key and
    /// the prologue. A call out of turn throws `.malformed`.
    public mutating func readMessage(_ message: [UInt8]) throws(SetupError) {
        guard !failed, step == (initiator ? 1 : 0) else { throw .malformed }
        do {
            try read(message)
        } catch {
            failed = true
            throw error
        }
        step += 1
    }

    private mutating func read(_ message: [UInt8]) throws(SetupError) {
        guard message.count == Self.keySize + Self.tagSize else { throw .handshakeFailed }
        let publicBytes = Array(message[..<Self.keySize])
        let remote: Curve25519.KeyAgreement.PublicKey
        do {
            remote = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicBytes)
        } catch {
            throw .handshakeFailed
        }
        if !initiator { state.mixKeyAndHash(psk) }
        state.mixHash(publicBytes)
        state.mixKey(publicBytes)
        if initiator {
            try state.mixKey(Self.agree(ephemeral, remote))
        }
        remoteEphemeral = remote
        _ = try state.decryptAndHash(Array(message[Self.keySize...]))
    }

    private static func agree(
        _ key: Curve25519.KeyAgreement.PrivateKey, _ remote: Curve25519.KeyAgreement.PublicKey?
    ) throws(SetupError) -> [UInt8] {
        guard let remote else { throw .handshakeFailed }
        do {
            return try key.sharedSecretFromKeyAgreement(with: remote).withUnsafeBytes { Array($0) }
        } catch {
            throw .handshakeFailed
        }
    }

    /// The transport keys, once both messages are through. This spends the handshake: a second call throws
    /// `.malformed`, so one set of keys never starts two counters.
    public mutating func split() throws(SetupError) -> NoiseTransport {
        guard isComplete, !spent else { throw .malformed }
        spent = true
        let (first, second) = state.split()
        return initiator
            ? NoiseTransport(sendKey: first, receiveKey: second)
            : NoiseTransport(sendKey: second, receiveKey: first)
    }
}

/// The two directions of an established Noise session. Each message is a ChaCha20-Poly1305 ciphertext with its tag,
/// no associated data, under a counter nonce, so messages must be opened in the order they were sealed. A message that
/// does not open ends the session: every later `seal` and `open` throws.
public struct NoiseTransport: ~Copyable {
    /// The largest message the Noise specification allows, tag included.
    public static let maxMessage = 65_535

    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private var sendCounter: UInt64 = 0
    private var receiveCounter: UInt64 = 0
    private var poisoned = false

    init(sendKey: [UInt8], receiveKey: [UInt8]) {
        self.sendKey = SymmetricKey(data: sendKey)
        self.receiveKey = SymmetricKey(data: receiveKey)
    }

    public mutating func seal(_ plaintext: [UInt8]) throws(SetupError) -> [UInt8] {
        guard !poisoned else { throw .handshakeFailed }
        guard plaintext.count <= Self.maxMessage - NoiseHandshake.tagSize else { throw .tooLarge }
        guard sendCounter < UInt64.max else { throw .tooLarge }
        let sealed = try NoiseCipher.seal(plaintext, key: sendKey, counter: sendCounter, associatedData: [])
        sendCounter += 1
        return sealed
    }

    public mutating func open(_ ciphertext: [UInt8]) throws(SetupError) -> [UInt8] {
        guard !poisoned else { throw .handshakeFailed }
        guard receiveCounter < UInt64.max, ciphertext.count <= Self.maxMessage else {
            poisoned = true
            throw .handshakeFailed
        }
        do {
            let plaintext = try NoiseCipher.open(
                ciphertext, key: receiveKey, counter: receiveCounter, associatedData: [])
            receiveCounter += 1
            return plaintext
        } catch {
            poisoned = true
            throw error
        }
    }
}

/// ChaCha20-Poly1305 as Noise uses it: the nonce is four zero octets and the counter, 64 bits little-endian.
enum NoiseCipher {
    static func nonce(_ counter: UInt64) throws(SetupError) -> ChaChaPoly.Nonce {
        var octets = [UInt8](repeating: 0, count: 12)
        for index in 0..<8 { octets[4 + index] = UInt8(truncatingIfNeeded: counter >> (8 * UInt64(index))) }
        do {
            return try ChaChaPoly.Nonce(data: octets)
        } catch {
            throw .malformed
        }
    }

    static func seal(
        _ plaintext: [UInt8], key: SymmetricKey, counter: UInt64, associatedData: [UInt8]
    ) throws(SetupError) -> [UInt8] {
        let nonce = try nonce(counter)
        do {
            let box = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce, authenticating: associatedData)
            return Array(box.ciphertext) + Array(box.tag)
        } catch {
            throw .malformed
        }
    }

    static func open(
        _ sealed: [UInt8], key: SymmetricKey, counter: UInt64, associatedData: [UInt8]
    ) throws(SetupError) -> [UInt8] {
        guard sealed.count >= NoiseHandshake.tagSize else { throw .handshakeFailed }
        let nonce = try nonce(counter)
        let split = sealed.count - NoiseHandshake.tagSize
        do {
            let box = try ChaChaPoly.SealedBox(
                nonce: nonce, ciphertext: Array(sealed[..<split]), tag: Array(sealed[split...]))
            return Array(try ChaChaPoly.open(box, using: key, authenticating: associatedData))
        } catch {
            throw .handshakeFailed
        }
    }
}

/// The SymmetricState of Noise §5.2 for SHA-256 and ChaCha20-Poly1305.
struct NoiseSymmetricState {
    private var chainingKey: [UInt8]
    private var hash: [UInt8]
    private var key: SymmetricKey?
    private var counter: UInt64 = 0

    /// The protocol name is longer than 32 octets, so it is hashed (§5.2 InitializeSymmetric).
    init(protocolName: [UInt8]) {
        hash = Array(SHA256.hash(data: protocolName))
        chainingKey = hash
    }

    mutating func mixHash(_ data: [UInt8]) {
        hash = Array(SHA256.hash(data: hash + data))
    }

    mutating func mixKey(_ input: [UInt8]) {
        let out = Self.hkdf(chainingKey, input, outputs: 2)
        chainingKey = out[0]
        key = SymmetricKey(data: out[1])
        counter = 0
    }

    mutating func mixKeyAndHash(_ input: [UInt8]) {
        let out = Self.hkdf(chainingKey, input, outputs: 3)
        chainingKey = out[0]
        mixHash(out[1])
        key = SymmetricKey(data: out[2])
        counter = 0
    }

    mutating func encryptAndHash(_ plaintext: [UInt8]) throws(SetupError) -> [UInt8] {
        guard let key else {
            mixHash(plaintext)
            return plaintext
        }
        guard counter < UInt64.max else { throw .handshakeFailed }
        let sealed = try NoiseCipher.seal(plaintext, key: key, counter: counter, associatedData: hash)
        counter += 1
        mixHash(sealed)
        return sealed
    }

    mutating func decryptAndHash(_ ciphertext: [UInt8]) throws(SetupError) -> [UInt8] {
        guard let key else {
            mixHash(ciphertext)
            return ciphertext
        }
        guard counter < UInt64.max else { throw .handshakeFailed }
        let plaintext = try NoiseCipher.open(ciphertext, key: key, counter: counter, associatedData: hash)
        counter += 1
        mixHash(ciphertext)
        return plaintext
    }

    /// The two transport keys, the initiator's sending key first.
    func split() -> ([UInt8], [UInt8]) {
        let out = Self.hkdf(chainingKey, [], outputs: 2)
        return (out[0], out[1])
    }

    /// HKDF of §4.3 with HMAC-SHA256: `outputs` chained 32-octet blocks.
    static func hkdf(_ chainingKey: [UInt8], _ input: [UInt8], outputs: Int) -> [[UInt8]] {
        let extracted = HMAC<SHA256>.authenticationCode(for: input, using: SymmetricKey(data: chainingKey))
        let temp = SymmetricKey(data: Array(extracted))
        var blocks: [[UInt8]] = []
        var previous: [UInt8] = []
        for index in 1...outputs {
            previous = Array(HMAC<SHA256>.authenticationCode(for: previous + [UInt8(index)], using: temp))
            blocks.append(previous)
        }
        return blocks
    }
}
