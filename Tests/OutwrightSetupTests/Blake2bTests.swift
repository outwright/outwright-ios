// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Testing

@testable import OutwrightSetup

func hexBytes(_ s: String) -> [UInt8] {
    var out: [UInt8] = []
    var high: UInt8?
    for c in s.utf8 {
        let v: UInt8
        switch c {
        case 48...57: v = c - 48
        case 97...102: v = c - 87
        default: continue
        }
        if let h = high { out.append(h << 4 | v); high = nil } else { high = v }
    }
    return out
}

@Suite struct Blake2bTests {
    @Test func blake2bMatchesRFC7693() throws {
        let digest = try Blake2b.hash(Array("abc".utf8), outputLength: 64)
        #expect(digest == hexBytes(
            "ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d1"
            + "7d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923"))
    }

    @Test func blake2bRefusesBadLengths() {
        #expect(throws: SetupError.malformed) { try Blake2b.hash([], outputLength: 0) }
        #expect(throws: SetupError.malformed) { try Blake2b.hash([], outputLength: 65) }
    }

    @Test func blake2bHandlesBlockBoundaries() throws {
        // Lengths around the 128-byte block must all work and differ.
        var seen = Set<[UInt8]>()
        for n in [0, 1, 127, 128, 129, 255, 256, 257] {
            seen.insert(try Blake2b.hash([UInt8](repeating: 7, count: n), outputLength: 32))
        }
        #expect(seen.count == 8)
    }
}
