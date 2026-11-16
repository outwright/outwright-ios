// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation

/// Images made in tests, byte by byte.
public enum SyntheticImage {
    /// A valid black 8-bit greyscale PNG of `width` × `height` pixels, uncompressed (stored deflate
    /// blocks), so a long thin one is a few kilobytes yet has a side past any cap.
    public static func png(width: Int, height: Int) -> Data {
        let rowBytes = 1 + max(1, width)
        var raw: [UInt8] = []
        raw.reserveCapacity(rowBytes * max(1, height))
        for _ in 0..<max(1, height) {
            raw += [UInt8](repeating: 0, count: rowBytes)
        }
        var header: [UInt8] = []
        header += bigEndian(UInt32(clamping: width)) + bigEndian(UInt32(clamping: height)) + [8, 0, 0, 0, 0]
        var data: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        data += chunk("IHDR", header) + chunk("IDAT", zlibStored(raw)) + chunk("IEND", [])
        return Data(data)
    }

    private static func zlibStored(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0x78, 0x01]
        var start = 0
        repeat {
            let end = min(start + 65_535, bytes.count)
            let length = UInt16(clamping: end - start)
            out.append(end == bytes.count ? 1 : 0)
            out += [UInt8(length & 0xFF), UInt8(length >> 8), UInt8(~length & 0xFF), UInt8(~length >> 8)]
            out += bytes[start..<end]
            start = end
        } while start < bytes.count
        var low: UInt32 = 1
        var high: UInt32 = 0
        for byte in bytes {
            low = (low + UInt32(byte)) % 65_521
            high = (high + low) % 65_521
        }
        return out + bigEndian((high << 16) | low)
    }

    private static func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
        let typed = Array(type.utf8) + body
        return bigEndian(UInt32(clamping: body.count)) + typed + bigEndian(crc(typed))
    }

    private static func crc(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static func bigEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
         UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
    }
}
