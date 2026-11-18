// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Testing

@testable import OutwrightSetup

@Suite struct PacketsTests {
    static let seipdType: UInt8 = 18
    static let literalType: UInt8 = 11

    @Test func readsWhatItWrites() throws {
        for count in [0, 191, 192, 8383, 8384, 70_000] {
            let body = (0..<count).map { UInt8(truncatingIfNeeded: $0) }
            let packets = try Packets.read(Packets.write(type: Self.literalType, body: body), maxPackets: 1)
            #expect(packets == [Packet(type: Self.literalType, body: body[...])])
        }
    }

    @Test func joinsPartialLengthBodies() throws {
        let body = (0..<1_500).map { UInt8(truncatingIfNeeded: $0 &* 7) }
        for type in [Self.seipdType, Self.literalType] {
            let packets = try Packets.read(partiallyEncoded(type: type, body: body), maxPackets: 1)
            #expect(packets.count == 1)
            #expect(packets.first?.type == type)
            #expect(packets.first.map { Array($0.body) } == body)
        }
    }

    @Test func refusesAFirstPartialUnder512Octets() {
        // A 256-octet partial (0xE8), then a final 1-octet length.
        let bytes = [0xC0 | Self.literalType, 0xE8] + [UInt8](repeating: 1, count: 256) + [0x01, 0x02]
        #expect(throws: SetupError.malformed) { try Packets.read(bytes, maxPackets: 1) }
    }

    @Test func refusesPartialLengthsOnPacketsThatAreNotData() {
        for type: UInt8 in [3, 21] {  // SKESK, padding
            let bytes = [0xC0 | type, 0xE9] + [UInt8](repeating: 1, count: 512) + [0x00]
            #expect(throws: SetupError.malformed) { try Packets.read(bytes, maxPackets: 1) }
        }
    }

    @Test func refusesMorePacketsThanAsked() throws {
        let bytes = try Packets.write(type: 21, body: []) + Packets.write(type: 21, body: [])
        #expect(throws: SetupError.unsupported) { try Packets.read(bytes, maxPackets: 1) }
    }

    @Test func readsArbitraryBytesWithoutCrashing() {
        var random = SplitMix64(seed: 0xbad_5eed)
        for round in 0..<4_000 {
            let count = Int(random.next() % 2_049)
            var bytes = (0..<count).map { _ in UInt8(truncatingIfNeeded: random.next()) }
            // Half of them start like an OpenPGP-format header, so the length paths are reached.
            if round.isMultiple(of: 2), !bytes.isEmpty { bytes[0] |= 0xC0 }
            if let packets = try? Packets.read(bytes, maxPackets: 8) {
                #expect(packets.reduce(0) { $0 + $1.body.count } <= bytes.count)
            }
        }
    }
}

/// `body` as one packet in partial lengths: a 512-octet part, 256-octet parts while more than 256 are left, and a
/// final definite length.
func partiallyEncoded(type: UInt8, body: [UInt8]) throws -> [UInt8] {
    var out: [UInt8] = [0xC0 | type, 0xE9] + body.prefix(512)
    var rest = Array(body.dropFirst(512))
    while rest.count > 256 {
        out += [0xE8] + rest.prefix(256)
        rest.removeFirst(256)
    }
    return try out + Packets.write(type: type, body: rest).dropFirst()
}
