// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Testing

@testable import OutwrightSetup

@Suite struct SymmetricMessageTests {
    /// Small Argon2 parameters, so a test does not spend seconds deriving a key.
    static let fast = Argon2Parameters(passes: 1, lanes: 1, memoryExponent: 10)
    /// The smallest valid parameters, for tests that open thousands of messages.
    static let tiny = Argon2Parameters(passes: 1, lanes: 1, memoryExponent: 3)
    static let passphrase = Array("correct horse battery staple".utf8)

    @Test func sealThenOpenRoundTrips() throws {
        for plaintext in [[], Array("{\"accounts\":[]}".utf8)] {
            let sealed = try SymmetricMessage.seal(plaintext, passphrase: Self.passphrase, parameters: Self.fast)
            #expect(try SymmetricMessage.open(sealed, passphrase: Self.passphrase) == plaintext)
        }
    }

    @Test func sealThenOpenRoundTripsAcrossChunks() throws {
        // 4 MiB chunks: a literal packet of exactly one chunk (1 + 5 header octets, 6 octets of format, name and
        // date), and one that spills a few octets into a second chunk.
        for count in [4_194_292, 4_194_400] {
            let plaintext = (0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 9) }
            let sealed = try SymmetricMessage.seal(plaintext, passphrase: Self.passphrase, parameters: Self.tiny)
            #expect(try SymmetricMessage.open(sealed, passphrase: Self.passphrase) == plaintext)
        }
    }

    @Test func sealingTwiceGivesDifferentMessages() throws {
        let plaintext = Array("same".utf8)
        let first = try SymmetricMessage.seal(plaintext, passphrase: Self.passphrase, parameters: Self.tiny)
        let second = try SymmetricMessage.seal(plaintext, passphrase: Self.passphrase, parameters: Self.tiny)
        #expect(first != second)
    }

    @Test func wrongPassphraseIsRefused() throws {
        let sealed = try SymmetricMessage.seal(Array("secret".utf8), passphrase: Self.passphrase, parameters: Self.fast)
        #expect(throws: SetupError.wrongPassphrase) {
            try SymmetricMessage.open(sealed, passphrase: Array("correct horse battery stapler".utf8))
        }
    }

    @Test func flippedCiphertextByteIsRefused() throws {
        let sealed = try SymmetricMessage.seal(
            Array(repeating: 0x41, count: 300), passphrase: Self.passphrase, parameters: Self.tiny)
        // The SKESK's encrypted session key, the SEIPD's chunk (start and middle), its chunk tag and its final tag.
        let skeskLength = 2 + 85
        for position in [skeskLength - 20, skeskLength + 50, sealed.count - 200, sealed.count - 20, sealed.count - 1] {
            var damaged = sealed
            damaged[position] ^= 0x01
            let error = #expect(throws: SetupError.self) {
                try SymmetricMessage.open(damaged, passphrase: Self.passphrase)
            }
            #expect(error == .malformed || error == .wrongPassphrase)
        }
    }

    @Test func truncatedMessageIsRefused() throws {
        let sealed = try SymmetricMessage.seal(Array("secret".utf8), passphrase: Self.passphrase, parameters: Self.tiny)
        for count in [0, 1, 10, sealed.count - 16, sealed.count - 1] {
            #expect(throws: SetupError.self) {
                try SymmetricMessage.open(Array(sealed.prefix(count)), passphrase: Self.passphrase)
            }
        }
    }

    /// RFC 9580 Appendix A.11: "Hello, world!" encrypted with the passphrase "password", AES-128, AEAD-GCM and the
    /// iterated and salted S2K, followed by a padding packet inside the encrypted data.
    @Test func opensRFC9580GCMSample() throws {
        let skesk = hexBytes("""
            c3 3c 06 1a 07 03 0b 03 08 e9 d3 97 85 b2 07 00 08 ff b4 2e 7c 48 3e f4 88 44 57 cb 37 26 b9 b3
            db 9f f7 76 e5 f4 d9 a4 09 52 e2 44 72 98 85 1a bf ff 75 26 df 2d d5 54 41 75 79 a7 79 9f
            """)
        let seipd = hexBytes("""
            d2 69 02 07 03 06 fc b9 44 90 bc b9 8b bd c9 d1 06 c6 09 02 66 94 0f 72 e8 9e dc 21 b5 59 6b 15
            76 b1 01 ed 0f 9f fc 6f c6 d6 5b bf d2 4d cd 07 90 96 6e 6d 1e 85 a3 00 53 78 4c b1 d8 b6 a0 69
            9e f1 21 55 a7 b2 ad 62 58 53 1b 57 65 1f d7 77 79 12 fa 95 e3 5d 9b 40 21 6f 69 a4 c2 48 db 28
            ff 43 31 f1 63 29 07 39 9e 6f f9
            """)
        let opened = try SymmetricMessage.open(skesk + seipd, passphrase: Array("password".utf8))
        #expect(opened == Array("Hello, world!".utf8))
        #expect(throws: SetupError.wrongPassphrase) {
            try SymmetricMessage.open(skesk + seipd, passphrase: Array("pass".utf8))
        }
    }

    /// RFC 9580 Appendix A.12.1: a v4 SKESK and a v1 SEIPD, which this reader does not take.
    @Test func refusesVersion4SKESK() throws {
        let armored = """
            wycEBwScUvg8J/leUNU1RA7N/zE2AQQVnlL8rSLPP5VlQsunlO+ECxHSPgGYGKY+\
            YJz4u6F+DDlDBOr5NRQXt/KJIf4m4mOlKyC/uqLbpnLJZMnTq3o79GxBTdIdOzhH\
            XfA3pqV4mTzF
            """
        let message = try #require(Data(base64Encoded: armored))
        #expect(throws: SetupError.unsupported) {
            try SymmetricMessage.open(Array(message), passphrase: Array("password".utf8))
        }
    }

    @Test func refusesCostlyArgon2Parameters() throws {
        let sealed = try SymmetricMessage.seal(Array("secret".utf8), passphrase: Self.passphrase, parameters: Self.tiny)
        // Packet header (2), version, count, cipher, AEAD, S2K length, S2K type and 16 octets of salt: then t, p, m.
        var costly = sealed
        costly[26] = 30
        #expect(throws: SetupError.tooLarge) { try SymmetricMessage.open(costly, passphrase: Self.passphrase) }
    }

    @Test func refusesWellFormedShapesItDoesNotTakeAsUnsupported() throws {
        let sealed = try SymmetricMessage.seal(Array("secret".utf8), passphrase: Self.passphrase, parameters: Self.tiny)
        let skesk = try #require(try Packets.read(sealed, maxPackets: 2).first)
        let skeskPacket = try Packets.write(type: skesk.type, body: Array(skesk.body))
        let marker = try Packets.write(type: 10, body: Array("PGP".utf8))
        let padding = try Packets.write(type: 21, body: [1, 2, 3])
        let outer = [
            skeskPacket + sealed,  // two SKESKs
            marker + sealed,
            Array(sealed.dropFirst(skeskPacket.count)),  // a SEIPD alone
            sealed + padding + skeskPacket,  // padding that does not trail
            Array(repeating: padding, count: SymmetricMessage.maxPackets).joined() + sealed
        ]
        for message in outer {
            #expect(throws: SetupError.unsupported) { try SymmetricMessage.open(message, passphrase: Self.passphrase) }
        }

        let literal = try Packets.write(type: 11, body: [0x62, 0, 0, 0, 0, 0] + Array("data".utf8))
        let inner = [
            literal + literal,
            try Packets.write(type: 8, body: [0]),  // compressed data
            try Packets.write(type: 11, body: [0x6d, 0, 0, 0, 0, 0] + Array("mime".utf8))  // format m
        ]
        for packets in inner {
            let message = try SymmetricMessage.seal(
                packets: packets, passphrase: Self.passphrase, parameters: Self.tiny)
            #expect(throws: SetupError.unsupported) { try SymmetricMessage.open(message, passphrase: Self.passphrase) }
        }
        #expect(throws: SetupError.malformed) { try SymmetricMessage.open([], passphrase: Self.passphrase) }
        let empty = try SymmetricMessage.seal(packets: [], passphrase: Self.passphrase, parameters: Self.tiny)
        #expect(throws: SetupError.malformed) { try SymmetricMessage.open(empty, passphrase: Self.passphrase) }
    }

    @Test func ignoresTrailingPaddingPackets() throws {
        let padding = try Packets.write(type: 21, body: [9, 9, 9])
        let literal = try Packets.write(type: 11, body: [0x62, 0, 0, 0, 0, 0] + Array("data".utf8))
        let message = try SymmetricMessage.seal(
            packets: literal + padding + padding, passphrase: Self.passphrase, parameters: Self.tiny)
        let opened = try SymmetricMessage.open(message + padding + padding, passphrase: Self.passphrase)
        #expect(opened == Array("data".utf8))
    }

    @Test func opensASEIPDInPartialLengths() throws {
        let plaintext = (0..<3_000).map { UInt8(truncatingIfNeeded: $0) }
        let literal = try partiallyEncoded(type: 11, body: [0x62, 0, 0, 0, 0, 0] + plaintext)
        let sealed = try SymmetricMessage.seal(packets: literal, passphrase: Self.passphrase, parameters: Self.tiny)
        let packets = try Packets.read(sealed, maxPackets: 2)
        let skesk = try #require(packets.first)
        let seipd = try #require(packets.last)
        let message = try Packets.write(type: skesk.type, body: Array(skesk.body))
            + partiallyEncoded(type: seipd.type, body: Array(seipd.body))
        #expect(try SymmetricMessage.open(message, passphrase: Self.passphrase) == plaintext)
    }

    @Test func refusesOversizeInput() {
        let huge = [UInt8](repeating: 0xc3, count: SymmetricMessage.maximumSize + 1)
        #expect(throws: SetupError.tooLarge) { try SymmetricMessage.open(huge, passphrase: Self.passphrase) }
    }

    @Test func opensArbitraryBytesWithoutCrashing() throws {
        var random = SplitMix64(seed: 0x5e7_0f11e)
        for _ in 0..<2_000 {
            let count = Int(random.next() % 4_097)
            let bytes = (0..<count).map { _ in UInt8(truncatingIfNeeded: random.next()) }
            _ = try? SymmetricMessage.open(bytes, passphrase: Self.passphrase)
        }
        let sealed = try SymmetricMessage.seal(
            Array("mutate me".utf8), passphrase: Self.passphrase, parameters: Self.tiny)
        // The Argon2 cost octets (24...26) are left alone: changing them only makes a valid, slower key derivation,
        // which refusesCostlyArgon2Parameters covers.
        let positions = (0..<sealed.count).filter { !(24...26).contains($0) }
        for round in 0..<2_000 {
            var mutated = sealed
            let position = positions[Int(random.next() % UInt64(positions.count))]
            switch round % 4 {
            case 0: mutated = Array(mutated.prefix(position))
            case 1: mutated.insert(UInt8(truncatingIfNeeded: random.next()), at: position)
            default: mutated[position] ^= UInt8(truncatingIfNeeded: random.next() | 1)
            }
            _ = try? SymmetricMessage.open(mutated, passphrase: Self.passphrase)
        }
    }
}

/// A small seeded generator, so a failing property test can be run again.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xbf58_476d_1ce4_e5b9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94d0_49bb_1331_11eb
        return mixed ^ (mixed >> 31)
    }
}
