// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/// Mailbox names in modified UTF-7 (RFC 3501 §5.1.3): printable ASCII stands for itself, `&-`
/// is `&`, and anything else is UTF-16BE in base64 with `,` for `/`, between `&` and `-`.
public enum ModifiedUTF7 {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+,".utf8)

    private static func sextet(_ byte: UInt8) -> UInt32? {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"): UInt32(byte - UInt8(ascii: "A"))
        case UInt8(ascii: "a")...UInt8(ascii: "z"): UInt32(byte - UInt8(ascii: "a")) + 26
        case UInt8(ascii: "0")...UInt8(ascii: "9"): UInt32(byte - UInt8(ascii: "0")) + 52
        case UInt8(ascii: "+"): 62
        case UInt8(ascii: ","): 63
        default: nil
        }
    }

    /// The name, or nil when `encoded` is not modified UTF-7.
    public static func decode(_ encoded: String) -> String? {
        let bytes = Array(encoded.utf8)
        var out = ""
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            guard byte < 0x80 else {
                return nil
            }
            guard byte == UInt8(ascii: "&") else {
                out.unicodeScalars.append(Unicode.Scalar(byte))
                index += 1
                continue
            }
            guard let end = bytes[(index + 1)...].firstIndex(of: UInt8(ascii: "-")) else {
                return nil
            }
            if end == index + 1 {
                out.append("&")
            } else {
                guard let text = decodeRun(bytes[(index + 1)..<end]) else {
                    return nil
                }
                out.append(text)
            }
            index = end + 1
        }
        return out
    }

    private static func decodeRun(_ run: ArraySlice<UInt8>) -> String? {
        var units: [UInt16] = []
        var bits: UInt32 = 0
        var count = 0
        for byte in run {
            guard let value = sextet(byte) else {
                return nil
            }
            bits = (bits << 6) | value
            count += 6
            if count >= 16 {
                count -= 16
                units.append(UInt16(truncatingIfNeeded: bits >> UInt32(count)))
                bits &= (1 << UInt32(count)) - 1
            }
        }
        guard count < 6, bits == 0, !units.isEmpty else {
            return nil
        }
        return String(validating: units, as: UTF16.self)
    }

    public static func encode(_ name: String) -> String {
        var out = ""
        var pending: [UInt16] = []
        for scalar in name.unicodeScalars {
            if scalar.value >= 0x20, scalar.value <= 0x7E {
                flush(&pending, into: &out)
                out.append(scalar == "&" ? "&-" : String(scalar))
            } else {
                pending.append(contentsOf: String(scalar).utf16)
            }
        }
        flush(&pending, into: &out)
        return out
    }

    private static func flush(_ units: inout [UInt16], into out: inout String) {
        guard !units.isEmpty else {
            return
        }
        var bytes: [UInt8] = []
        var bits: UInt32 = 0
        var count = 0
        for unit in units {
            bits = (bits << 16) | UInt32(unit)
            count += 16
            while count >= 6 {
                count -= 6
                bytes.append(alphabet[Int((bits >> UInt32(count)) & 0x3F)])
            }
            bits &= (1 << UInt32(count)) - 1
        }
        if count > 0 {
            bytes.append(alphabet[Int((bits << UInt32(6 - count)) & 0x3F)])
        }
        out.append("&")
        out.append(lossyText(bytes))
        out.append("-")
        units.removeAll()
    }
}
