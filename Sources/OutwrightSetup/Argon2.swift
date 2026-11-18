// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

// The names and the shape of the code follow the RFC, which is easier to check against it that way.
// swiftlint:disable identifier_name line_length cyclomatic_complexity function_body_length

/// The cost of an Argon2id derivation, as the setup file stores it (RFC 9106).
public struct Argon2Parameters: Sendable, Equatable {
    /// Number of passes over the memory (t).
    public var passes: UInt8
    /// Degree of parallelism (p).
    public var lanes: UInt8
    /// Memory is 2 to the power of this many KiB.
    public var memoryExponent: UInt8

    public init(passes: UInt8, lanes: UInt8, memoryExponent: UInt8) {
        self.passes = passes
        self.lanes = lanes
        self.memoryExponent = memoryExponent
    }

    /// What the app writes: 3 passes, 4 lanes, 64 MiB (RFC 9106 section 4, second recommended option).
    public static let writer = Argon2Parameters(passes: 3, lanes: 4, memoryExponent: 16)

    static let maxPasses: UInt8 = 10
    static let maxLanes: UInt8 = 8
    static let maxMemoryExponent: UInt8 = 18

    /// These parameters if they are valid and within what a reader accepts (at most 256 MiB, 10 passes, 8 lanes).
    public func validated() throws(SetupError) -> Argon2Parameters {
        guard passes <= Self.maxPasses, lanes <= Self.maxLanes, memoryExponent <= Self.maxMemoryExponent else { throw .tooLarge }
        guard passes >= 1, lanes >= 1, (1 << Int(memoryExponent)) >= 8 * Int(lanes) else { throw .malformed }
        return self
    }
}

/// Argon2id version 0x13 (RFC 9106), written fresh from the RFC. Lanes are computed in order, which gives the
/// same result as the parallel computation.
public enum Argon2id {
    private static let maxInput = 1 << 20

    /// The `length`-byte tag for `password` and `salt` (salt at least 8 bytes). `secret` and `associatedData`
    /// are the RFC's optional inputs.
    public static func derive(
        password: [UInt8], salt: [UInt8], parameters: Argon2Parameters, length: Int,
        secret: [UInt8] = [], associatedData: [UInt8] = []
    ) throws(SetupError) -> [UInt8] {
        let valid = try parameters.validated()
        guard (4...1024).contains(length), salt.count >= 8 else { throw .malformed }
        guard password.count <= maxInput, salt.count <= maxInput, secret.count <= maxInput, associatedData.count <= maxInput else {
            throw .tooLarge
        }
        let p = Int(valid.lanes)
        let t = Int(valid.passes)
        let m = 1 << Int(valid.memoryExponent)
        let q = (m / (4 * p)) * 4  // columns per lane
        let segment = q / 4

        var seed = le32(p) + le32(length) + le32(m) + le32(t) + le32(0x13) + le32(2)
        seed += le32(password.count) + password + le32(salt.count) + salt
        seed += le32(secret.count) + secret + le32(associatedData.count) + associatedData
        let h0 = try Blake2b.hash(seed, outputLength: 64)

        var memory = [UInt64](repeating: 0, count: p * q * 128)
        func base(_ lane: Int, _ column: Int) -> Int { (lane * q + column) * 128 }

        for lane in 0..<p {
            for column in 0..<2 {
                let bytes = try variableHash(1024, h0 + le32(column) + le32(lane))
                let b = base(lane, column)
                for i in 0..<128 {
                    var word: UInt64 = 0
                    for k in 0..<8 { word |= UInt64(bytes[i * 8 + k]) << UInt64(8 * k) }
                    memory[b + i] = word
                }
            }
        }

        let zero = [UInt64](repeating: 0, count: 128)
        var previousBlock = zero
        var referenceBlock = zero
        var result = zero
        var work = Workspace()
        for pass in 0..<t {
            for slice in 0..<4 {
                for lane in 0..<p {
                    let independent = pass == 0 && slice < 2
                    var input = zero
                    input[0] = UInt64(pass)
                    input[1] = UInt64(lane)
                    input[2] = UInt64(slice)
                    input[3] = UInt64(p * q)
                    input[4] = UInt64(t)
                    input[5] = 2
                    var addresses = zero
                    func nextAddresses() {
                        input[6] += 1
                        var first = zero
                        compress(zero, input, into: &first, &work)
                        compress(zero, first, into: &addresses, &work)
                    }
                    let start = (pass == 0 && slice == 0) ? 2 : 0
                    if independent && start == 2 { nextAddresses() }

                    for i in start..<segment {
                        let column = slice * segment + i
                        let previous = (column + q - 1) % q
                        let random: UInt64
                        if independent {
                            if i % 128 == 0 { nextAddresses() }
                            random = addresses[i % 128]
                        } else {
                            random = memory[base(lane, previous)]
                        }
                        let j1 = random & 0xFFFF_FFFF
                        let j2 = random >> 32
                        let refLane = (pass == 0 && slice == 0) ? lane : Int(j2 % UInt64(p))
                        let sameLane = refLane == lane
                        let area: Int
                        if pass == 0 {
                            area = sameLane ? slice * segment + i - 1 : slice * segment - (i == 0 ? 1 : 0)
                        } else {
                            area = sameLane ? q - segment + i - 1 : q - segment - (i == 0 ? 1 : 0)
                        }
                        let x = (j1 &* j1) >> 32
                        let y = (UInt64(area) &* x) >> 32
                        let z = area - 1 - Int(y)
                        let startPosition = pass == 0 ? 0 : (slice == 3 ? 0 : (slice + 1) * segment)
                        let refColumn = (startPosition + z) % q

                        let from = base(lane, previous)
                        let refFrom = base(refLane, refColumn)
                        var k = 0
                        while k < 128 {
                            previousBlock[k] = memory[from + k]
                            referenceBlock[k] = memory[refFrom + k]
                            k += 1
                        }
                        compress(previousBlock, referenceBlock, into: &result, &work)
                        let b = base(lane, column)
                        k = 0
                        while k < 128 {
                            memory[b + k] = pass > 0 ? memory[b + k] ^ result[k] : result[k]
                            k += 1
                        }
                    }
                }
            }
        }

        var final = [UInt64](repeating: 0, count: 128)
        for lane in 0..<p {
            let b = base(lane, q - 1)
            for k in 0..<128 { final[k] ^= memory[b + k] }
        }
        var bytes = [UInt8]()
        bytes.reserveCapacity(1024)
        for word in final {
            for shift in stride(from: 0, to: 64, by: 8) { bytes.append(UInt8(truncatingIfNeeded: word >> UInt64(shift))) }
        }
        return try variableHash(length, bytes)
    }

    private static func le32(_ value: Int) -> [UInt8] {
        let v = UInt32(truncatingIfNeeded: value)
        return [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v >> 16), UInt8(truncatingIfNeeded: v >> 24)]
    }

    /// H' of RFC 9106 section 3.3: a hash of any length up to 2^32 - 1 bytes.
    private static func variableHash(_ length: Int, _ input: [UInt8]) throws(SetupError) -> [UInt8] {
        if length <= 64 { return try Blake2b.hash(le32(length) + input, outputLength: length) }
        let r = (length + 31) / 32 - 2
        var v = try Blake2b.hash(le32(length) + input, outputLength: 64)
        var out = Array(v.prefix(32))
        for _ in 1..<r {
            v = try Blake2b.hash(v, outputLength: 64)
            out += v.prefix(32)
        }
        out += try Blake2b.hash(v, outputLength: length - 32 * r)
        return out
    }

    /// Scratch space the compression function reuses, so a block step allocates nothing.
    private struct Workspace {
        var xored = [UInt64](repeating: 0, count: 128)
        var mixed = [UInt64](repeating: 0, count: 128)
        var round = [UInt64](repeating: 0, count: 16)
    }

    private static func compress(_ x: [UInt64], _ y: [UInt64], into out: inout [UInt64], _ w: inout Workspace) {
        // Plain while loops: a range loop is several times slower in debug builds, and this is the hot path.
        var i = 0
        while i < 128 {
            let value = x[i] ^ y[i]
            w.xored[i] = value
            w.mixed[i] = value
            i += 1
        }
        var row = 0
        while row < 8 {
            var k = 0
            while k < 16 { w.round[k] = w.mixed[row * 16 + k]; k += 1 }
            permute(&w.round)
            k = 0
            while k < 16 { w.mixed[row * 16 + k] = w.round[k]; k += 1 }
            row += 1
        }
        var column = 0
        while column < 8 {
            var k = 0
            while k < 8 {
                w.round[2 * k] = w.mixed[column * 2 + 16 * k]
                w.round[2 * k + 1] = w.mixed[column * 2 + 16 * k + 1]
                k += 1
            }
            permute(&w.round)
            k = 0
            while k < 8 {
                w.mixed[column * 2 + 16 * k] = w.round[2 * k]
                w.mixed[column * 2 + 16 * k + 1] = w.round[2 * k + 1]
                k += 1
            }
            column += 1
        }
        i = 0
        while i < 128 { out[i] = w.mixed[i] ^ w.xored[i]; i += 1 }
    }

    /// One BLAKE2b-style round over 16 words. The words live in locals while it runs, which keeps the
    /// array traffic (and so the cost in debug builds) low.
    private static func permute(_ v: inout [UInt64]) {
        var v0 = v[0]
        var v1 = v[1]
        var v2 = v[2]
        var v3 = v[3]
        var v4 = v[4]
        var v5 = v[5]
        var v6 = v[6]
        var v7 = v[7]
        var v8 = v[8]
        var v9 = v[9]
        var v10 = v[10]
        var v11 = v[11]
        var v12 = v[12]
        var v13 = v[13]
        var v14 = v[14]
        var v15 = v[15]
        gb(&v0, &v4, &v8, &v12)
        gb(&v1, &v5, &v9, &v13)
        gb(&v2, &v6, &v10, &v14)
        gb(&v3, &v7, &v11, &v15)
        gb(&v0, &v5, &v10, &v15)
        gb(&v1, &v6, &v11, &v12)
        gb(&v2, &v7, &v8, &v13)
        gb(&v3, &v4, &v9, &v14)
        v[0] = v0
        v[1] = v1
        v[2] = v2
        v[3] = v3
        v[4] = v4
        v[5] = v5
        v[6] = v6
        v[7] = v7
        v[8] = v8
        v[9] = v9
        v[10] = v10
        v[11] = v11
        v[12] = v12
        v[13] = v13
        v[14] = v14
        v[15] = v15
    }

    @inline(__always) private static func gb(_ a: inout UInt64, _ b: inout UInt64, _ c: inout UInt64, _ d: inout UInt64) {
        a = a &+ b &+ 2 &* (a & 0xFFFF_FFFF) &* (b & 0xFFFF_FFFF)
        d = rotr(d ^ a, 32)
        c = c &+ d &+ 2 &* (c & 0xFFFF_FFFF) &* (d & 0xFFFF_FFFF)
        b = rotr(b ^ c, 24)
        a = a &+ b &+ 2 &* (a & 0xFFFF_FFFF) &* (b & 0xFFFF_FFFF)
        d = rotr(d ^ a, 16)
        c = c &+ d &+ 2 &* (c & 0xFFFF_FFFF) &* (d & 0xFFFF_FFFF)
        b = rotr(b ^ c, 63)
    }

    @inline(__always) private static func rotr(_ x: UInt64, _ n: UInt64) -> UInt64 {
        (x >> n) | (x << (64 - n))
    }
}

// swiftlint:enable identifier_name line_length cyclomatic_complexity function_body_length
