// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import CryptoKit
import Foundation
import Testing

@testable import OutwrightSetup

@Suite struct NoiseTests {
    struct Message: Decodable {
        let plaintext: String
        let ciphertext: String
    }

    struct Vector: Decodable {
        let psk: String
        let prologue: String
        let initiatorEphemeral: String
        let responderEphemeral: String
        let message1: String
        let message2: String
        let initiatorToResponder: [Message]
        let responderToInitiator: [Message]
    }

    static func bytes(_ hex: String) throws -> [UInt8] {
        try #require(hex.count.isMultiple(of: 2))
        var out: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            out.append(try #require(UInt8(hex[index..<next], radix: 16)))
            index = next
        }
        return out
    }

    static func vector() throws -> Vector {
        let url = try #require(
            Bundle.module.url(forResource: "noise-nnpsk0", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Vector.self, from: Data(contentsOf: url))
    }

    static let psk = [UInt8](repeating: 7, count: 32)
    static let prologue = Array("outwright-pairing".utf8)

    static func pair(
        psk responderPSK: [UInt8] = psk, prologue responderPrologue: [UInt8] = prologue
    ) throws -> (NoiseHandshake, NoiseHandshake) {
        (
            try NoiseHandshake(initiator: true, psk: psk, prologue: prologue),
            try NoiseHandshake(initiator: false, psk: responderPSK, prologue: responderPrologue)
        )
    }

    struct Transports: ~Copyable {
        var first: NoiseTransport
        var second: NoiseTransport
    }

    static func connected() throws -> Transports {
        var (initiator, responder) = try pair()
        try responder.readMessage(try initiator.writeMessage())
        try initiator.readMessage(try responder.writeMessage())
        return Transports(first: try initiator.split(), second: try responder.split())
    }

    @Test func matchesFlynnNoiseVectors() throws {
        let vector = try Self.vector()
        let psk = try Self.bytes(vector.psk)
        let prologue = try Self.bytes(vector.prologue)
        let initiatorKey = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: try Self.bytes(vector.initiatorEphemeral))
        let responderKey = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: try Self.bytes(vector.responderEphemeral))
        var initiator = try NoiseHandshake(initiator: true, psk: psk, prologue: prologue, ephemeral: initiatorKey)
        var responder = try NoiseHandshake(initiator: false, psk: psk, prologue: prologue, ephemeral: responderKey)

        let expected1 = try Self.bytes(vector.message1)
        let expected2 = try Self.bytes(vector.message2)
        let first = try initiator.writeMessage()
        #expect(first == expected1)
        try responder.readMessage(first)
        let second = try responder.writeMessage()
        #expect(second == expected2)
        try initiator.readMessage(second)
        #expect(initiator.isComplete && responder.isComplete)

        var sender = try initiator.split()
        var receiver = try responder.split()
        for message in vector.initiatorToResponder {
            let plaintext = try Self.bytes(message.plaintext)
            let sealed = try sender.seal(plaintext)
            #expect(sealed == (try Self.bytes(message.ciphertext)))
            #expect(try receiver.open(sealed) == plaintext)
        }
        for message in vector.responderToInitiator {
            let plaintext = try Self.bytes(message.plaintext)
            let sealed = try receiver.seal(plaintext)
            #expect(sealed == (try Self.bytes(message.ciphertext)))
            #expect(try sender.open(sealed) == plaintext)
        }
    }

    @Test func roundTripsWithFreshKeys() throws {
        var pair = try Self.connected()
        let payload = (0..<5_000).map { UInt8(truncatingIfNeeded: $0) }
        #expect(try pair.second.open(try pair.first.seal(payload)) == payload)
        #expect(try pair.first.open(try pair.second.seal([])) == [])
        #expect(try pair.second.open(try pair.first.seal([1, 2, 3])) == [1, 2, 3])
    }

    @Test func wrongPSKFailsHandshake() throws {
        var (initiator, responder) = try Self.pair(psk: [UInt8](repeating: 8, count: 32))
        let first = try initiator.writeMessage()
        #expect(throws: SetupError.handshakeFailed) { try responder.readMessage(first) }
    }

    @Test func wrongPSKOnTheResponderSideIsRefusedByTheInitiator() throws {
        // The responder took message 1; an initiator with another code cannot open its reply.
        let key = Curve25519.KeyAgreement.PrivateKey()
        var initiator = try NoiseHandshake(initiator: true, psk: Self.psk, prologue: Self.prologue, ephemeral: key)
        var responder = try NoiseHandshake(initiator: false, psk: Self.psk, prologue: Self.prologue)
        try responder.readMessage(try initiator.writeMessage())
        var wrong = try NoiseHandshake(
            initiator: true, psk: [UInt8](repeating: 9, count: 32), prologue: Self.prologue, ephemeral: key)
        _ = try wrong.writeMessage()
        let second = try responder.writeMessage()
        #expect(throws: SetupError.handshakeFailed) { try wrong.readMessage(second) }
    }

    @Test func differentPrologueFailsHandshake() throws {
        var (initiator, responder) = try Self.pair(prologue: Array("other".utf8))
        let first = try initiator.writeMessage()
        #expect(throws: SetupError.handshakeFailed) { try responder.readMessage(first) }
    }

    @Test func pskOfTheWrongLengthIsMalformed() {
        #expect(throws: SetupError.malformed) { try NoiseHandshake(initiator: true, psk: [1, 2], prologue: []) }
    }

    @Test func splitBeforeCompletionIsRefused() throws {
        var (initiator, _) = try Self.pair()
        #expect(throws: SetupError.malformed) { _ = try initiator.split() }
    }

    @Test func splitSpendsTheHandshake() throws {
        var (initiator, responder) = try Self.pair()
        try responder.readMessage(try initiator.writeMessage())
        try initiator.readMessage(try responder.writeMessage())
        _ = try initiator.split()
        #expect(throws: SetupError.malformed) { _ = try initiator.split() }
    }

    @Test func alteredTransportMessageIsRefused() throws {
        var pair = try Self.connected()
        var altered = try pair.first.seal(Array("secret".utf8))
        altered[0] ^= 1
        #expect(throws: SetupError.handshakeFailed) { try pair.second.open(altered) }
        let valid = try pair.first.seal(Array("next".utf8))
        #expect(throws: SetupError.handshakeFailed) { try pair.second.open(valid) }
        #expect(throws: SetupError.handshakeFailed) { try pair.second.seal([1]) }
    }

    @Test func aMessageAboveTheLimitIsRefused() throws {
        var pair = try Self.connected()
        let tooBig = [UInt8](repeating: 0, count: NoiseTransport.maxMessage)
        #expect(throws: SetupError.tooLarge) { try pair.first.seal(tooBig) }
        let largest = try pair.first.seal([UInt8](repeating: 0, count: NoiseTransport.maxMessage - 16))
        #expect(largest.count == NoiseTransport.maxMessage)
    }

    @Test func readsArbitraryBytesWithoutCrashing() throws {
        var generator = SystemRandomNumberGenerator()
        for round in 0..<2_000 {
            // Half the inputs have the exact handshake length (so the key is parsed and the tag checked) or a valid
            // transport length (so the AEAD runs); the others are any length.
            let exact = round.isMultiple(of: 2)
            let handshakeCount = exact ? 48 : Int.random(in: 0...200, using: &generator)
            let transportCount = Int.random(in: exact ? 16...200 : 0...200, using: &generator)
            let handshakeBytes = (0..<handshakeCount).map { _ in UInt8.random(in: 0...255, using: &generator) }
            let transportBytes = (0..<transportCount).map { _ in UInt8.random(in: 0...255, using: &generator) }
            var responder = try NoiseHandshake(initiator: false, psk: Self.psk, prologue: Self.prologue)
            _ = try? responder.readMessage(handshakeBytes)
            var pair = try Self.connected()
            _ = try? pair.second.open(transportBytes)
        }
    }
}
