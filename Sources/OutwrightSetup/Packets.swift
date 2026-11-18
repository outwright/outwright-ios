// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/// One OpenPGP packet: its Packet Type ID and its body (RFC 9580 §4). A body with a definite length is a slice of
/// the bytes read, not a copy; only a body in partial lengths is put together in an array of its own.
struct Packet: Equatable, Sendable {
    var type: UInt8
    var body: ArraySlice<UInt8>
}

/// OpenPGP packet framing (RFC 9580 §4.2): OpenPGP-format headers, 1-, 2- and 5-octet lengths, and partial body
/// lengths, which are read but never written. Legacy-format headers are not taken.
enum Packets {
    /// The packet types that may use partial body lengths (§4.2.1.4): compressed, symmetrically encrypted, literal,
    /// and the two encrypted and integrity protected data packets.
    private static let partialTypes: Set<UInt8> = [8, 9, 11, 18, 20]
    private static let minimumFirstPartial = 512

    /// Splits `bytes` into packets. More than `maxPackets` is a shape no reader here takes, `.unsupported`. Every
    /// length is checked against what is left before anything is taken, so a hostile length never allocates.
    static func read(_ bytes: [UInt8], maxPackets: Int) throws(SetupError) -> [Packet] {
        var reader = ByteReader(bytes[...])
        var packets: [Packet] = []
        while reader.remaining > 0 {
            guard packets.count < maxPackets else { throw .unsupported }
            let first = try reader.byte()
            guard first & 0x80 != 0 else { throw .malformed }
            guard first & 0x40 != 0 else { throw .unsupported }
            let type = first & 0x3F
            guard type != 0 else { throw .malformed }
            packets.append(Packet(type: type, body: try body(of: type, from: &reader)))
        }
        return packets
    }

    /// One packet with an OpenPGP-format header and the shortest definite length that holds the body.
    static func write(type: UInt8, body: [UInt8]) throws(SetupError) -> [UInt8] {
        guard type > 0, type < 64 else { throw .malformed }
        guard let length = UInt32(exactly: body.count) else { throw .tooLarge }
        var out: [UInt8] = [0xC0 | type]
        switch length {
        case 0..<192:
            out.append(UInt8(truncatingIfNeeded: length))
        case 192..<8384:
            let rest = length - 192
            out += [UInt8(truncatingIfNeeded: rest >> 8) + 192, UInt8(truncatingIfNeeded: rest)]
        default:
            out += [0xFF] + bigEndian(UInt64(length), octets: 4)
        }
        out += body
        return out
    }

    private enum Length {
        case final(Int)
        case partial(Int)
    }

    private static func body(of type: UInt8, from reader: inout ByteReader) throws(SetupError) -> ArraySlice<UInt8> {
        switch try length(from: &reader) {
        case .final(let count):
            return try reader.take(count)
        case .partial(let firstCount):
            guard partialTypes.contains(type), firstCount >= minimumFirstPartial else { throw .malformed }
            var body = Array(try reader.take(firstCount))
            // Every round takes at least one octet, so the input's size bounds the loop.
            for _ in 0...reader.remaining {
                switch try length(from: &reader) {
                case .final(let count):
                    body += try reader.take(count)
                    return body[...]
                case .partial(let count):
                    body += try reader.take(count)
                }
            }
            throw .malformed
        }
    }

    private static func length(from reader: inout ByteReader) throws(SetupError) -> Length {
        let first = try reader.byte()
        switch first {
        case 0..<192:
            return .final(Int(first))
        case 192..<224:
            let second = try reader.byte()
            return .final((Int(first) - 192) << 8 + Int(second) + 192)
        case 255:
            let octets = try reader.take(4)
            return .final(octets.reduce(0) { $0 << 8 | Int($1) })
        default:
            return .partial(1 << Int(first & 0x1F))
        }
    }
}

/// `value` as `octets` big-endian octets (the low ones).
func bigEndian(_ value: UInt64, octets: Int) -> [UInt8] {
    (0..<max(0, min(octets, 8))).reversed().map { UInt8(truncatingIfNeeded: value >> (UInt64($0) * 8)) }
}

/// A cursor over bytes that refuses to read past their end. What it hands out are slices of the same storage.
struct ByteReader {
    private let bytes: ArraySlice<UInt8>
    private var offset: Int

    init(_ bytes: ArraySlice<UInt8>) {
        self.bytes = bytes
        offset = bytes.startIndex
    }

    var remaining: Int { bytes.endIndex - offset }

    mutating func byte() throws(SetupError) -> UInt8 {
        guard offset < bytes.endIndex else { throw .malformed }
        let value = bytes[offset]
        offset += 1
        return value
    }

    mutating func take(_ count: Int) throws(SetupError) -> ArraySlice<UInt8> {
        guard count >= 0, count <= remaining else { throw .malformed }
        let slice = bytes[offset..<(offset + count)]
        offset += count
        return slice
    }

    /// Everything not read yet.
    mutating func rest() -> ArraySlice<UInt8> {
        let slice = bytes[offset...]
        offset = bytes.endIndex
        return slice
    }
}
