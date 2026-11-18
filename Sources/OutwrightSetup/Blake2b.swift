// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

// The names and the shape of the code follow the RFC, which is easier to check against it that way.
// swiftlint:disable identifier_name function_parameter_count

/// BLAKE2b (RFC 7693), unkeyed, written fresh from the RFC.
public enum Blake2b {
    private static let iv: [UInt64] = [
        0x6a09_e667_f3bc_c908, 0xbb67_ae85_84ca_a73b, 0x3c6e_f372_fe94_f82b, 0xa54f_f53a_5f1d_36f1,
        0x510e_527f_ade6_82d1, 0x9b05_688c_2b3e_6c1f, 0x1f83_d9ab_fb41_bd6b, 0x5be0_cd19_137e_2179
    ]

    private static let sigma: [[Int]] = [
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
        [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
        [11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4],
        [7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8],
        [9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13],
        [2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9],
        [12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11],
        [13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10],
        [6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5],
        [10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0]
    ]

    /// The hash of `data`, `outputLength` bytes long (1 through 64).
    public static func hash(_ data: [UInt8], outputLength: Int) throws(SetupError) -> [UInt8] {
        guard (1...64).contains(outputLength) else { throw .malformed }
        var h = iv
        h[0] ^= 0x0101_0000 | UInt64(outputLength)

        var offset = 0
        var counter: UInt64 = 0
        // Every block but the last is full; the last (possibly empty input) is padded and flagged.
        while data.count - offset > 128 {
            counter = counter &+ 128
            compress(&h, block: data, at: offset, count: 128, counter: counter, last: false)
            offset += 128
        }
        let rest = data.count - offset
        counter = counter &+ UInt64(rest)
        compress(&h, block: data, at: offset, count: rest, counter: counter, last: true)

        var out = [UInt8]()
        out.reserveCapacity(64)
        for word in h {
            for shift in stride(from: 0, to: 64, by: 8) { out.append(UInt8(truncatingIfNeeded: word >> UInt64(shift))) }
        }
        return Array(out.prefix(outputLength))
    }

    private static func compress(
        _ h: inout [UInt64], block: [UInt8], at offset: Int, count: Int, counter: UInt64, last: Bool
    ) {
        var m = [UInt64](repeating: 0, count: 16)
        for i in 0..<count {
            m[i / 8] |= UInt64(block[offset + i]) << UInt64((i % 8) * 8)
        }
        var v = h + iv
        v[12] ^= counter
        if last { v[14] = ~v[14] }

        func mix(_ a: Int, _ b: Int, _ c: Int, _ d: Int, _ x: UInt64, _ y: UInt64) {
            v[a] = v[a] &+ v[b] &+ x
            v[d] = rotr(v[d] ^ v[a], 32)
            v[c] = v[c] &+ v[d]
            v[b] = rotr(v[b] ^ v[c], 24)
            v[a] = v[a] &+ v[b] &+ y
            v[d] = rotr(v[d] ^ v[a], 16)
            v[c] = v[c] &+ v[d]
            v[b] = rotr(v[b] ^ v[c], 63)
        }
        for round in 0..<12 {
            let s = sigma[round % 10]
            mix(0, 4, 8, 12, m[s[0]], m[s[1]])
            mix(1, 5, 9, 13, m[s[2]], m[s[3]])
            mix(2, 6, 10, 14, m[s[4]], m[s[5]])
            mix(3, 7, 11, 15, m[s[6]], m[s[7]])
            mix(0, 5, 10, 15, m[s[8]], m[s[9]])
            mix(1, 6, 11, 12, m[s[10]], m[s[11]])
            mix(2, 7, 8, 13, m[s[12]], m[s[13]])
            mix(3, 4, 9, 14, m[s[14]], m[s[15]])
        }
        for i in 0..<8 { h[i] ^= v[i] ^ v[i + 8] }
    }

    @inline(__always) private static func rotr(_ x: UInt64, _ n: UInt64) -> UInt64 {
        (x >> n) | (x << (64 - n))
    }
}

// swiftlint:enable identifier_name function_parameter_count
